--!strict
-- QW netchan over a lossy transport. Part A unit-tests the netchan.c
-- reliable protocol (bit-31 flags, copy-out, retransmit-on-evidence,
-- ack clearing, stale/duplicate discard). Part B runs the full
-- qwsv+qwcl loopback game over a simulated Roblox dual-remote link —
-- an unreliable channel that drops/reorders/duplicates and a reliable
-- channel that delivers in order but can lag behind — and asserts the
-- handshake completes, reliable content arrives exactly once and in
-- order, prediction still converges, and the wire lossage byte reports
-- real loss.
local t = require("./testutil")
local fs = require("@lune/fs")
local qwnetchan = require("../src/shared/engine/qw/qwnetchan")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwp = require("../src/shared/engine/qw/qwprotocol")
local msg = require("../src/shared/engine/common/msg")
local vmlib = require("../src/shared/engine/progs/vm")

-- A: reliable protocol unit tests -------------------------------------------
do
	local a = qwnetchan.new()
	local b = qwnetchan.new()

	local function payloadString(r: msg.Reader?): string
		t.check(r ~= nil, "A packet accepted")
		return msg.readString(r :: msg.Reader)
	end

	-- A1: fresh reliable content rides the next transmit, flagged
	msg.writeString(a.message, "hello")
	local p1, rel1 = qwnetchan.transmit(a, nil)
	t.eq(rel1, true, "A1 fresh reliable content flags the packet")
	t.check(a.reliable_length > 0, "A1 reliable copy-out pending ack")
	t.eq(a.message.cursize, 0, "A1 message stream drained into reliable_buf")
	t.eq(payloadString(qwnetchan.process(b, p1)), "hello", "A1 reliable content delivered")
	t.eq(b.incoming_reliable_sequence, 1, "A1 receiver toggled its reliable-ack bit")

	-- A2: the receiver's next packet acks it; sender clears the buffer
	local b1 = qwnetchan.transmit(b, nil)
	t.check(qwnetchan.process(a, b1) ~= nil, "A2 ack packet accepted")
	t.eq(a.reliable_length, 0, "A2 acked reliable buffer cleared")

	-- A3: a dropped reliable packet retransmits once the peer provably
	-- missed it (acked a later sequence without toggling its bit), and
	-- the content is delivered exactly once overall
	msg.writeString(a.message, "resend-me")
	local _lost, relLost = qwnetchan.transmit(a, nil) -- dropped by the network
	t.eq(relLost, true, "A3 reliable packet sent (and lost)")
	local deliveries = 0
	for _ = 1, 4 do
		local p, rel = qwnetchan.transmit(a, nil)
		local r = qwnetchan.process(b, p)
		if rel and r then
			t.eq(msg.readString(r :: msg.Reader), "resend-me", "A3 retransmit carries the same content")
			deliveries += 1
		end
		local back = qwnetchan.transmit(b, nil)
		qwnetchan.process(a, back)
	end
	t.eq(deliveries, 1, "A3 reliable content delivered exactly once")
	t.eq(a.reliable_length, 0, "A3 retransmitted reliable acked and cleared")

	-- A4: duplicated and out-of-order packets are discarded
	local d1 = qwnetchan.transmit(a, nil)
	local d2 = qwnetchan.transmit(a, nil)
	t.check(qwnetchan.process(b, d2) ~= nil, "A4 newer packet accepted")
	t.eq(qwnetchan.process(b, d1), nil, "A4 older packet discarded as stale")
	t.eq(qwnetchan.process(b, d2), nil, "A4 duplicate discarded")

	-- A5: while a reliable is unacked, new message content waits its turn
	msg.writeString(a.message, "first")
	local q1 = qwnetchan.transmit(a, nil) -- copies out "first"
	msg.writeString(a.message, "second")
	local q2, rel2 = qwnetchan.transmit(a, nil)
	t.eq(rel2, false, "A5 pending unacked reliable holds back the next message")
	t.check(a.message.cursize > 0, "A5 'second' still queued in the stream")
	t.eq(payloadString(qwnetchan.process(b, q1)), "first", "A5 first reliable delivered")
	t.check(qwnetchan.process(b, q2) ~= nil, "A5 in-between packet accepted")
	local ack = qwnetchan.transmit(b, nil)
	qwnetchan.process(a, ack)
	t.eq(a.reliable_length, 0, "A5 first reliable acked")
	local q3, rel3 = qwnetchan.transmit(a, nil)
	t.eq(rel3, true, "A5 next message copies out after the ack")
	t.eq(payloadString(qwnetchan.process(b, q3)), "second", "A5 second reliable delivered")

	-- A6: net_drop counts the gap for the cmd-replay logic
	local g1 = qwnetchan.transmit(a, nil)
	local _g2 = qwnetchan.transmit(a, nil) -- lost
	local _g3 = qwnetchan.transmit(a, nil) -- lost
	local g4 = qwnetchan.transmit(a, nil)
	qwnetchan.process(b, g1)
	qwnetchan.process(b, g4)
	t.eq(b.drop_count, 2, "A6 drop_count reports the two lost packets")
end

-- B: full game over a lossy dual-channel link --------------------------------
do
	local gamefs = t.gameFs()
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))

	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")

	-- deterministic LCG so failures reproduce
	local seed = 0x2F6E2B1
	local function rand(): number -- [0, 1)
		seed = (seed * 1103515245 + 12345) % 0x80000000
		return seed / 0x80000000
	end

	-- one direction of the link, shaped like the production transport:
	-- packets that fit ride the unreliable channel (drops, reorders,
	-- duplicates); reliable-bearing or oversized packets ALSO ride the
	-- reliable channel (ordered, guaranteed, but lagging a step behind
	-- half the time — the second copy must be discarded as stale)
	type Link = {
		send: (packet: buffer, hasReliable: boolean?) -> (),
		step: () -> (),
		dropRate: number,
		drops: number,
		dups: number,
		unreliableSent: number,
		reliableSent: number,
	}
	local function makeLink(deliver: (packet: buffer) -> ()): Link
		local uq: { buffer } = {}
		local rq: { buffer } = {}
		local link: Link
		link = {
			dropRate = 0.15,
			drops = 0,
			dups = 0,
			unreliableSent = 0,
			reliableSent = 0,
			send = function(packet: buffer, hasReliable: boolean?)
				local fits = buffer.len(packet) <= 850
				if fits then
					table.insert(uq, packet)
					link.unreliableSent += 1
				end
				if hasReliable or not fits then
					table.insert(rq, packet)
					link.reliableSent += 1
				end
			end,
			step = function()
				-- unreliable channel: drop / adjacent-swap / duplicate
				local batch = uq
				uq = {}
				if #batch >= 2 and rand() < 0.2 then
					batch[1], batch[2] = batch[2], batch[1]
				end
				for _, packet in batch do
					if rand() < link.dropRate then
						link.drops += 1
					else
						deliver(packet)
						if rand() < 0.05 then
							link.dups += 1
							deliver(packet) -- duplicate delivery
						end
					end
				end
				-- reliable channel: always delivers, in order, but lags a
				-- step behind half the time (so its copies often arrive
				-- after newer unreliable packets → stale-discard dedupe)
				if #rq > 0 and rand() < 0.5 then
					return
				end
				local rbatch = rq
				rq = {}
				for _, packet in rbatch do
					deliver(packet)
				end
			end,
		}
		return link
	end

	local sclient: qwsv.Client
	local cl = qwcl.new(gamefs)
	local s2c = makeLink(function(packet: buffer)
		qwcl.processPacket(cl, packet)
	end)
	local c2s = makeLink(function(packet: buffer)
		qwsv.executeClientMessage(svr, sclient, packet)
	end)

	sclient = qwsv.wireConnect(svr, 1, { name = "lossy" }, s2c.send)
	qwcl.connect(cl, c2s.send)

	-- handshake: the content exchange is a lockstep with no retry clock;
	-- like C's CL_SendCmd (and the production Heartbeat loop), the client
	-- keeps sending cmd packets during it — that steady stream is the
	-- heartbeat that drives netchan retransmit convergence when the
	-- unreliable channel drops a step
	for _ = 1, 300 do
		cl.realtime += 0.05
		qwcl.sendCmd(cl, {
			angles = vector.zero,
			forwardmove = 0,
			sidemove = 0,
			upmove = 0,
			buttons = 0,
			impulse = 0,
			msec = 50,
		})
		c2s.step()
		qwsv.sendClientMessages(svr)
		s2c.step()
		if sclient.spawned and cl.validsequence > 0 then
			break
		end
	end
	t.check(sclient.spawned, "B handshake completed over the lossy link")
	t.check(cl.validsequence > 0, "B first entity frame received")
	assert(sclient.spawned and cl.validsequence > 0, "cannot play without a completed handshake")

	local ent = svr.qdefs.ent
	local player = sclient.edict
	local yaw = vmlib.edVector(player, ent.angles).y

	local marks = 0
	local function tick(forwardmove: number)
		cl.realtime += 0.05
		s2c.step()
		qwcl.sendCmd(cl, {
			angles = vector.create(0, yaw, 0),
			forwardmove = forwardmove,
			sidemove = 0,
			upmove = 0,
			buttons = 0,
			impulse = 0,
			msec = 50,
		})
		c2s.step()
		qwsv.frame(svr, 0.05)
		qwsv.sendClientMessages(svr)
		qwcl.predictMove(cl)
	end

	local spawnOrg = vmlib.edVector(player, ent.origin)
	for i = 1, 120 do
		if i % 10 == 0 then
			-- numbered reliable prints: must arrive exactly once, in order
			marks += 1
			svr.clientPrint(svr, sclient, 2, `mark {marks}\n`)
		end
		if i == 55 then
			-- client→server reliable under loss rides the same machinery
			qwcl.sendStringCmd(cl, "say netchan")
		end
		tick(400)
	end
	t.eq(cl.state, "active", "B client active through packet loss")
	t.check(vector.magnitude(vmlib.edVector(player, ent.origin) - spawnOrg) > 150, "B player ran a real distance")
	t.check(c2s.drops > 0 and s2c.drops > 0, `B loss exercised (c2s {c2s.drops}, s2c {s2c.drops} drops)`)
	t.check(c2s.dups > 0 or s2c.dups > 0, "B duplicate delivery exercised")
	t.check(s2c.unreliableSent > s2c.reliableSent, "B datagrams dominate the unreliable channel")
	t.check(sclient.lossage > 0, `B wire lossage byte reports real loss ({sclient.lossage}%)`)

	-- cooldown: stop moving, no loss — prediction must reconverge
	c2s.dropRate = 0
	s2c.dropRate = 0
	for _ = 1, 40 do
		tick(0)
	end
	local err = vector.magnitude(cl.simorg - vmlib.edVector(player, ent.origin))
	t.check(err < 1.0, `B prediction converged after loss (|simorg - server| = {string.format("%.4f", err)})`)

	-- reliable content: every mark arrived exactly once, in order
	local seen: { number } = {}
	local saySeen = 0
	for _, p in cl.prints do
		for m in (p.text :: string):gmatch("mark (%d+)") do
			table.insert(seen, tonumber(m) :: number)
		end
		if (p.text :: string):find("netchan", 1, true) then
			saySeen += 1
		end
	end
	t.eq(#seen, marks, `B all {marks} reliable prints arrived`)
	local ordered = true
	for i, m in seen do
		if m ~= i then
			ordered = false
		end
	end
	t.check(ordered, "B reliable prints arrived exactly once, in order")
	t.eq(saySeen, 1, "B client 'say' delivered exactly once through loss")
end

t.finish("test_qwnetchan")
