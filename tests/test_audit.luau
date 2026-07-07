--!strict
-- Regression checks for the 2026-07-06 release-audit findings
-- (docs/coverage/audit-2026-07-06.md). Each block is labelled with its
-- manifest row id.

local t = require("./testutil")
local fs = require("@lune/fs")
local vfs = require("../src/shared/engine/common/vfs")
local progslib = require("../src/shared/engine/progs/progs")
local vmlib = require("../src/shared/engine/progs/vm")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwsv = require("../src/shared/engine/qw/qwsv")
local msg = require("../src/shared/engine/common/msg")
local sv_user = require("../src/shared/engine/server/sv_user")

local gamefs = t.gameFs()

-- A1: cl_pushlatency prediction horizon -----------------------------------
do
	local cl = qwcl.new(gamefs)
	cl.realtime = 10
	cl.latency = 0.2
	-- default pushlatency -999: cl.time = realtime - latency + 0.999,
	-- clamped to realtime — prediction runs through all outstanding cmds
	qwcl.predictMove(cl)
	t.eq(cl.time, 10, "A1 default pushlatency predicts to realtime")
	-- pushlatency 0 reproduces the old (laggy) horizon
	cl.pushlatency = 0
	qwcl.predictMove(cl)
	t.check(math.abs(cl.time - 9.8) < 1e-9, "A1 pushlatency 0 stops one RTT early")
	-- C clamps positive values to 0 at the top of CL_PredictMove
	cl.pushlatency = 500
	qwcl.predictMove(cl)
	t.eq(cl.pushlatency, 0, "A1 positive pushlatency clamped to 0")
	t.check(math.abs(cl.time - 9.8) < 1e-9, "A1 clamped horizon equals pushlatency 0")
end

-- A2: MakeChar truncation toward zero -------------------------------------
do
	local cl = qwcl.new(gamefs)
	cl.state = "active"
	cl.movemessages = 5
	cl.send = function(_p: buffer) end
	local function sent(fwd: number): number
		local seq = cl.netchan.outgoing_sequence
		qwcl.sendCmd(cl, {
			msec = 16,
			angles = vector.zero,
			forwardmove = fwd,
			sidemove = 0,
			upmove = 0,
			buttons = 0,
			impulse = 0,
		})
		return cl.frames[bit32.band(seq, 15)].cmd.forwardmove
	end
	-- C: (int)(-12.5) = -12; -12 & ~3 = -12. Floor would give -16.
	t.eq(sent(-12.5), -12, "A2 makeChar truncates -12.5 toward zero")
	-- C: (int)(-200.5) = -200. Floor would give -204.
	t.eq(sent(-200.5), -200, "A2 makeChar truncates -200.5 toward zero")
	t.eq(sent(200.5), 200, "A2 makeChar positive unchanged")
	t.eq(sent(-1000), -508, "A2 makeChar clamps at -127*4")
end

-- A3: SV_SetIdealPitch int step/dir ---------------------------------------
do
	-- fractional risers: C truncates each delta to int, so 0.6-unit
	-- steps read as 0 (no step) — the float port counted them
	local dir, steps = sv_user.idealPitchSteps({ 0, 0.6, 1.2, 1.8, 2.4, 3.0 })
	t.eq(dir, 0, "A3 sub-unit deltas truncate to no direction")
	t.eq(steps, 0, "A3 sub-unit deltas count zero steps")
	-- 16.7-unit risers: C dir = 16 (not 16.7)
	dir, steps = sv_user.idealPitchSteps({ 0, 16.7, 33.4, 50.1, 66.8, 83.5 })
	t.eq(dir, 16, "A3 fractional riser dir truncates toward zero")
	t.eq(steps, 5, "A3 riser count intact")
	-- descending fractional: trunc(-16.7) = -16 (floor would say -17)
	dir, steps = sv_user.idealPitchSteps({ 83.5, 66.8, 50.1, 33.4, 16.7, 0 })
	t.eq(dir, -16, "A3 negative dir truncates toward zero")
	-- mixed changes still bail out
	local _, s2 = sv_user.idealPitchSteps({ 0, 16, 0, 16, 0, 16 })
	t.eq(s2, -1, "A3 mixed changes bail out")
end

-- B1: VM stack state restored after a QC runtime error ---------------------
do
	local buf = vfs.loadFile(gamefs, "progs.dat")
	assert(buf)
	local pr = progslib.load(buf)
	local vm = vmlib.new(pr, 600, 0)
	-- no builtins registered: the first builtin call inside main()
	-- raises PR_RunError ("bad builtin call number") mid-execution
	local fnum = pr.functionsByName["main"]
	assert(fnum, "progs.dat main")
	local ok = pcall(vmlib.exec, vm, fnum)
	t.eq(ok, false, "B1 QC error propagates")
	t.eq(vm.depth, 0, "B1 depth dumped like PR_RunError")
	t.eq(vm.localstack_used, 0, "B1 locals stack dumped")
	-- the VM keeps working: a pure-assignment function runs clean
	local ok2 = pcall(vmlib.exec, vm, pr.functionsByName["SetNewParms"])
	t.eq(ok2, true, "B1 next exec runs on a clean stack")
	t.eq(vm.depth, 0, "B1 depth balanced after clean exec")
end

-- B2: reliable overflow flags + drops instead of erroring; timeouts --------
do
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")

	local c1 = qwsv.wireConnect(svr, 1, { name = "spammed" }, function(_p: buffer) end)
	-- 30 x ~300B into the 8192 reliable stream: C's allowoverflow path
	-- must flag + clear, never error
	local okWrite = pcall(function()
		for _ = 1, 30 do
			msg.writeByte(c1.netchan.message, 8) -- svc_print
			msg.writeByte(c1.netchan.message, 2)
			msg.writeString(c1.netchan.message, string.rep("x", 300))
		end
	end)
	t.eq(okWrite, true, "B2 overflowing reliable write does not error")
	t.eq(c1.netchan.message.overflowed, true, "B2 overflow flagged")
	qwsv.frame(svr, 0.05)
	t.eq(c1.active, false, "B2 overflowed client dropped at the frame sweep")

	-- timeout: a client that stops sending packets gets dropped after
	-- timeout (65s) of realtime; a talking client survives
	local c2 = qwsv.wireConnect(svr, 2, { name = "zombie" }, function(_p: buffer) end)
	local c3 = qwsv.wireConnect(svr, 3, { name = "alive" }, function(_p: buffer) end)
	c2.last_message = svr.realtime
	svr.realtime += 100
	c3.last_message = svr.realtime
	qwsv.checkTimeouts(svr)
	t.eq(c2.active, false, "B2 silent client timed out")
	t.eq(c3.active, true, "B2 talking client survives the sweep")
end

-- C1-C4: QW CL_ClearState memset parity across changelevel ----------------
do
	local qwp = require("../src/shared/engine/qw/qwprotocol")
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")

	local queue: { buffer } = {}
	local sc = qwsv.wireConnect(svr, 1, { name = "carrier" }, function(packet: buffer)
		table.insert(queue, packet)
	end)
	local cl = qwcl.new(gamefs)
	qwcl.connect(cl, function(packet: buffer)
		qwsv.executeClientMessage(svr, sc, packet)
	end)
	for _ = 1, 40 do
		qwsv.sendClientMessages(svr)
		while #queue > 0 do
			qwcl.processPacket(cl, table.remove(queue, 1) :: buffer)
		end
		if sc.spawned then
			break
		end
	end
	t.check(sc.spawned, "C handshake completed")

	-- give armor server-side; the stat delta rides the next reply
	local ent = svr.qdefs.ent
	vmlib.edSetFloat(sc.edict, ent.armorvalue, 100)
	sc.send_message = true
	qwsv.replyToClient(svr, sc)
	while #queue > 0 do
		qwcl.processPacket(cl, table.remove(queue, 1) :: buffer)
	end
	t.eq(cl.stats[qwp.STAT_ARMOR], 100, "C armor stat arrived over the wire")

	-- stale-state markers that CL_ClearState must wipe (this harness
	-- never sends moves, so simulate a played level's counter)
	cl.flagindex = 33
	cl.movemessages = 10

	-- changelevel: fresh serverdata must memset the cl fields
	qwsv.saveSpawnparms(svr)
	qwsv.spawnServer(svr, "e1m2")
	queue = {}
	sc.spawned = false
	qwsv.newF(svr, sc)
	sc.send_message = true
	qwsv.replyToClient(svr, sc)
	while #queue > 0 do
		qwcl.processPacket(cl, table.remove(queue, 1) :: buffer)
	end
	t.eq(cl.state, "connected", "C new serverdata parsed")
	t.eq(cl.stats[qwp.STAT_ARMOR], 0, "C1 stats zeroed by clearState (no armor ghost)")
	t.eq(cl.movemessages, 0, "C2 movemessages reset per level")
	t.eq(cl.flagindex, nil, "C3 flagindex reset per level")
	t.eq(next(cl.players), nil, "C4 players table cleared until fresh updates")
end

-- D: QW server fidelity ----------------------------------------------------
do
	local qwp = require("../src/shared/engine/qw/qwprotocol")
	local qwphys = require("../src/shared/engine/qw/qwphys")
	local qwworld = require("../src/shared/engine/qw/qwworld")
	local qd = require("../src/shared/engine/quakedef")
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")
	local vm = svr.vm
	local ent = svr.qdefs.ent
	local glob = svr.qdefs.glob

	-- D4: the signon chunks into <=1450-byte buffers (e1m1 needs several)
	t.check(#svr.signon_buffers > 1, "D4 signon split into multiple buffers")
	for _, sg in svr.signon_buffers do
		t.check(sg.cursize <= 1450, "D4 signon buffer within MAX_DATAGRAM")
	end

	-- D1: a newmis missile runs ONCE per frame (0.05 newmis move only),
	-- not again when the main scan reaches its slot
	local mis = vmlib.alloc(vm)
	vmlib.edSetFloat(mis, ent.movetype, qd.MOVETYPE_TOSS)
	vmlib.edSetFloat(mis, ent.solid, qd.SOLID_NOT)
	vmlib.edSetVector(mis, ent.origin, vector.create(480, -352, 200))
	vmlib.edSetVector(mis, ent.velocity, vector.zero)
	buffer.writei32(vm.globals, glob.newmis * 4, mis.num)
	qwsv.frame(svr, 0.1)
	local vz = vmlib.edVector(mis, ent.velocity).z
	t.check(math.abs(vz + 40) < 0.01, `D1 newmis got exactly one 0.05s gravity tick (vz {vz}, want -40)`)
	-- and the NEXT frame moves it normally
	qwsv.frame(svr, 0.1)
	local vz2 = vmlib.edVector(mis, ent.velocity).z
	t.check(math.abs(vz2 + 120) < 0.01, `D1 next frame runs the missile again (vz {vz2}, want -120)`)
	vmlib.free(vm, mis)

	-- D3: SV_RunThink loops — a [+0.1] QC anim chain advances several
	-- frames inside one long server frame (NQ single-shot ran one)
	local anim = vmlib.alloc(vm)
	local standFn = svr.progs.functionsByName["player_stand1"]
	assert(standFn, "player_stand1 in qwprogs")
	vmlib.edSetInt(anim, ent.think, standFn)
	vmlib.edSetFloat(anim, ent.nextthink, svr.time + 0.01)
	local savedFt = svr.frametime
	svr.frametime = 0.35
	qwphys.runThink(svr, anim)
	svr.frametime = savedFt
	t.check(
		vmlib.edFloat(anim, ent.nextthink) > svr.time + 0.3,
		"D3 runThink looped the +0.1 anim chain past the frame window"
	)
	vmlib.free(vm, anim)

	-- D2: QW SV_Push pre-skips entities already stuck in something else
	-- (NQ counted them as blockers — the door would never travel)
	local useDoor: vmlib.Edict? = nil
	for i = 1, vm.num_edicts - 1 do
		local e = vm.edicts[i + 1]
		if not e.free and vmlib.edString(vm, e, ent.classname) == "door" and vmlib.edInt(e, ent.use) ~= 0 then
			useDoor = e
			break
		end
	end
	assert(useDoor, "door with a use function")
	local doorStart = vmlib.edVector(useDoor, ent.origin)
	-- junk entity buried in solid near the door, bbox wide enough to
	-- overlap the door's swept volume
	local junk = vmlib.alloc(vm)
	-- STEP + FL_ONGROUND: own physics is a no-op, but push() considers it
	vmlib.edSetFloat(junk, ent.movetype, qd.MOVETYPE_STEP)
	vmlib.edSetFloat(junk, ent.flags, qd.FL_ONGROUND)
	vmlib.edSetFloat(junk, ent.solid, qd.SOLID_BBOX)
	vmlib.edSetVector(junk, ent.mins, vector.create(-256, -256, -256))
	vmlib.edSetVector(junk, ent.maxs, vector.create(256, 256, 256))
	local stuckAt: vector? = nil
	for dz = 0, 512, 16 do
		vmlib.edSetVector(junk, ent.origin, doorStart - vector.create(0, 0, dz))
		qwworld.linkEdict(svr.world, junk, false)
		if qwworld.testEntityPosition(svr.world, junk) then
			stuckAt = doorStart - vector.create(0, 0, dz)
			break
		end
	end
	assert(stuckAt, "found a solid spot for the stuck junk entity")
	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	buffer.writei32(vm.globals, glob.self * 4, useDoor.num)
	buffer.writei32(vm.globals, glob.other * 4, 1)
	vmlib.exec(vm, vmlib.edInt(useDoor, ent.use))
	local maxTravel = 0
	for _ = 1, 40 do
		qwsv.frame(svr, 0.05)
		maxTravel = math.max(maxTravel, vector.magnitude(vmlib.edVector(useDoor, ent.origin) - doorStart))
	end
	t.check(maxTravel > 30, `D2 door travels despite a wall-stuck overlapper (QW pre-skip; moved {math.floor(maxTravel)})`)
	t.check(vmlib.edVector(junk, ent.origin) == stuckAt :: vector, "D2 stuck entity left alone")
	vmlib.free(vm, junk)

	-- D9: QW addGravity ignores the per-entity gravity field
	local toss = vmlib.alloc(vm)
	vmlib.edSetFloat(toss, ent.movetype, qd.MOVETYPE_TOSS)
	vmlib.edSetFloat(toss, ent.solid, qd.SOLID_NOT)
	vmlib.edSetVector(toss, ent.origin, vector.create(480, -352, 200))
	local gravdef = svr.progs.fielddefsByName["gravity"]
	if gravdef then
		vmlib.edSetFloat(toss, gravdef.ofs, 0.25) -- NQ would fall at quarter g
	end
	qwphys.runEntity(svr, toss)
	local tvz = vmlib.edVector(toss, ent.velocity).z
	t.check(math.abs(tvz + 800 * svr.frametime) < 0.01, "D9 non-player gravity scale is always 1.0 in QW")
	vmlib.free(vm, toss)

	-- D6: infokey — static-string reuse (no dynstring growth), ping/ip
	local B = vm.builtins
	local keyId = vmlib.newString(vm, "ping")
	local c1 = qwsv.wireConnect(svr, 1, { name = "ik" }, function(_p: buffer) end)
	c1.address = "12345"
	local before = #vm.dynstrings
	for _ = 1, 50 do
		buffer.writei32(vm.globals, 4 * 4, 1) -- OFS_PARM0 = edict 1
		buffer.writei32(vm.globals, 7 * 4, keyId) -- OFS_PARM1
		B[80](vm)
	end
	t.eq(#vm.dynstrings, before, "D6 infokey reuses one static slot (no leak)")
	t.eq(vmlib.globalString(vm, 1), "9999", "D6 infokey ping (no acked frames = 9999)")
	buffer.writei32(vm.globals, 4 * 4, 1)
	buffer.writei32(vm.globals, 7 * 4, vmlib.newString(vm, "ip"))
	B[80](vm)
	t.eq(vmlib.globalString(vm, 1), "12345", "D6 infokey ip = transport identity")

	-- D7: setmodel sizes only inline '*' models in QW
	local sm = vmlib.alloc(vm)
	vmlib.edSetVector(sm, ent.mins, vector.create(-4, -4, -4))
	vmlib.edSetVector(sm, ent.maxs, vector.create(4, 4, 4))
	buffer.writei32(vm.globals, 4 * 4, sm.num)
	buffer.writei32(vm.globals, 7 * 4, vmlib.newString(vm, "progs/spike.mdl"))
	B[3](vm)
	t.check(vmlib.edVector(sm, ent.maxs) == vector.create(4, 4, 4), "D7 alias setmodel leaves bbox alone")
	buffer.writei32(vm.globals, 7 * 4, vmlib.newString(vm, "*1"))
	B[3](vm)
	t.check(vmlib.edVector(sm, ent.maxs) ~= vector.create(4, 4, 4), "D7 inline setmodel takes the brush bounds")
	vmlib.free(vm, sm)

	-- D8: stuffcmd("disconnect\n") sets the server-side drop flag
	buffer.writei32(vm.globals, 4 * 4, 1)
	buffer.writei32(vm.globals, 7 * 4, vmlib.newString(vm, "disconnect\n"))
	B[21](vm)
	t.eq((c1 :: any).drop, true, "D8 stuffcmd disconnect flags the drop")
	local pkt = buffer.create(8)
	buffer.writeu32(pkt, 0, 1)
	qwsv.executeClientMessage(svr, c1, pkt)
	t.eq(c1.active, false, "D8 client dropped at end of message processing")

	-- D5: near-full reliable stream backbufs instead of silently dropping
	local c2 = qwsv.wireConnect(svr, 2, { name = "bb" }, function(_p: buffer) end)
	local out = c2.netchan.message
	out.cursize = out.maxsize - 10 -- almost full
	local blob = msg.newBuf(64)
	msg.writeByte(blob, 8) -- svc_print
	msg.writeByte(blob, 2)
	msg.writeString(blob, "queued hello")
	qwsv.reliableCopy(c2, blob.data, blob.cursize)
	t.eq((c2 :: any).backbufBytes, blob.cursize, "D5 overfull reliable write queued to backbuf")
	t.eq(out.overflowed, false, "D5 no overflow, nothing lost")
	-- transmit flushes the stream; the next reply drains the queue
	c2.send_message = true
	qwsv.replyToClient(svr, c2) -- sends the near-full stream
	c2.send_message = true
	qwsv.replyToClient(svr, c2) -- drains the backbuf into this packet
	t.eq((c2 :: any).backbufBytes, 0, "D5 backbuf drained once space freed")

	-- D10: spawn seeds the QC gravity/maxspeed fields when the mod has
	-- them (vanilla qwprogs: gravity absent is fine; Threewave defines it)
	t.check(svr.qdefs.optfield ~= nil, "D10 optfield table present")
end

-- E: client protocol --------------------------------------------------------
do
	local qwents = require("../src/shared/engine/qw/qwents")
	local qwnetchan = require("../src/shared/engine/qw/qwnetchan")

	-- E1: no clc_delta request while recording
	local cl = qwcl.new(gamefs)
	cl.state = "active"
	cl.movemessages = 5
	cl.send = function(_p: buffer) end
	local function sendOne(): number
		local seq = cl.netchan.outgoing_sequence
		qwcl.sendCmd(cl, {
			msec = 16,
			angles = vector.zero,
			forwardmove = 0,
			sidemove = 0,
			upmove = 0,
			buttons = 0,
			impulse = 0,
		})
		return cl.frames[bit32.band(seq, 15)].delta_sequence
	end
	cl.validsequence = 1
	cl.recording = true
	cl.demoBlocks = {}
	t.eq(sendOne(), -1, "E1 recording suppresses the clc_delta request")
	cl.recording = false
	cl.validsequence = cl.netchan.outgoing_sequence
	t.eq(sendOne(), cl.validsequence, "E1 delta requested again once not recording")

	-- E2: demo captures only ACCEPTED packets (post-Netchan_Process)
	cl.recording = true
	cl.demoBlocks = {}
	local pkt = buffer.create(8)
	buffer.writeu32(pkt, 0, cl.netchan.incoming_sequence + 1)
	qwcl.processPacket(cl, pkt)
	t.eq(#cl.demoBlocks, 1, "E2 accepted packet recorded")
	local stale = buffer.create(8)
	buffer.writeu32(stale, 0, cl.netchan.incoming_sequence) -- duplicate
	qwcl.processPacket(cl, stale)
	t.eq(#cl.demoBlocks, 1, "E2 stale packet NOT recorded")
	cl.recording = false

	-- E5: the first two moves are dumped but still transmitted
	local cl2 = qwcl.new(gamefs)
	cl2.state = "active"
	local sends = 0
	cl2.send = function(_p: buffer)
		sends += 1
	end
	local function move(fwd: number): number
		local seq = cl2.netchan.outgoing_sequence
		qwcl.sendCmd(cl2, {
			msec = 16,
			angles = vector.zero,
			forwardmove = fwd,
			sidemove = 0,
			upmove = 0,
			buttons = 1,
			impulse = 3,
		})
		return cl2.frames[bit32.band(seq, 15)].cmd.forwardmove
	end
	t.eq(move(100), 0, "E5 first move dumped (stale input flushed)")
	t.eq(move(100), 0, "E5 second move dumped")
	t.eq(sends, 2, "E5 dumped moves still transmit (netchan lockstep)")
	t.eq(move(100), 100, "E5 third move goes through")

	-- E4: packet-entities cap refuses before writing slot 64
	local function copyPacket(n: number): boolean
		local from = {}
		for i = 1, n do
			from[i] = qwents.nullState(i)
		end
		local b = msg.newBuf(4)
		msg.writeShort(b, 0) -- "copy the rest" terminator
		return (pcall(qwents.parsePacketEntities, msg.reader(b.data), from, function(num: number)
			return qwents.nullState(num)
		end))
	end
	t.eq(copyPacket(64), true, "E4 64 entities accepted")
	t.eq(copyPacket(65), false, "E4 65th entity refused like C")

	-- E6: spectator-cam vectoangles truncates toward zero
	local rad = -30.7 * math.pi / 180
	local ang = qwcl.camVectoangles(vector.create(math.cos(rad), math.sin(rad), 0))
	t.eq(ang.y, 330, "E6 negative yaw truncates then wraps (floor said 329)")

	-- E7: first-packet net_drop clamped to 0 (was -1)
	local chan = qwnetchan.new()
	local first = buffer.create(8)
	buffer.writeu32(first, 0, 0)
	qwnetchan.process(chan, first)
	t.eq(chan.drop_count, 0, "E7 first packet drop_count 0")
end

-- F: VM/builtin odds --------------------------------------------------------
do
	local com = require("../src/shared/engine/common/com")
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")
	local vm = svr.vm
	local B = vm.builtins

	-- F1: ftos on huge integral floats prints INT_MIN like x86 C
	-- instead of erroring (which, pre-B1, corrupted the VM for good)
	local function ftos(v: number): string
		buffer.writef32(vm.globals, 4 * 4, v)
		B[26](vm)
		return vmlib.globalString(vm, 1)
	end
	t.eq(ftos(5), "5", "F1 ftos integral")
	t.eq(ftos(5.5), "  5.5", "F1 ftos fractional %5.1f")
	t.eq(ftos(1e20), "-2147483648", "F1 ftos overflow saturates like x86 (int) cast")

	-- F5: stof is libc atof — no hex (Q_atof keeps hex elsewhere)
	buffer.writei32(vm.globals, 4 * 4, vmlib.newString(vm, "0x1A"))
	B[81](vm)
	t.eq(buffer.readf32(vm.globals, 1 * 4), 0, "F5 stof(0x1A) = 0 like libc atof")
	t.eq(com.atof("0x10"), 16, "F5 Q_atof (com.atof) keeps hex")

	-- F3: ED_ParseEpair vector splits on SINGLE spaces like C
	local def = svr.progs.fielddefsByName["origin"]
	assert(def, "origin fielddef")
	local target = buffer.create((def.ofs + 3) * 4)
	local function parseVec(s: string): (number, number, number)
		buffer.fill(target, 0, 0)
		vmlib.parseEpair(vm, target, def, s)
		return buffer.readf32(target, def.ofs * 4),
			buffer.readf32(target, def.ofs * 4 + 4),
			buffer.readf32(target, def.ofs * 4 + 8)
	end
	local x, y, z = parseVec("1 2 3")
	t.check(x == 1 and y == 2 and z == 3, "F3 normal vector parse")
	x, y, z = parseVec("1  2 3")
	t.check(x == 1 and y == 0 and z == 2, "F3 double space reads as C: (1, 0, 2)")
	x, y, z = parseVec("4 5")
	t.check(x == 4 and y == 5 and z == 0, "F3 short vector zero-fills")
end

-- G10: framegroup subframe cache can never freeze the animation --------------
do
	-- entrender re-poses only when mdl.selectFrame returns a DIFFERENT
	-- subframe object; prove subframes change over time (so cached
	-- torches/flames still animate) and repeat within one interval (so
	-- the cache actually skips work)
	local modelslib = require("../src/shared/engine/models/models")
	local mdl = require("../src/shared/engine/models/mdl")
	local reg = modelslib.newRegistry(gamefs)
	local m = modelslib.forName(reg, "progs/flame2.mdl", false)
	assert(m and m.kind == "alias", "flame2.mdl loads as alias")
	local am = (m :: any).alias
	t.check(am.frames[1].group ~= nil, "G10 flame2 frame 0 is a framegroup")
	local f0 = mdl.selectFrame(am, 0, 0, 0.0)
	local f0b = mdl.selectFrame(am, 0, 0, 0.01)
	local f1 = mdl.selectFrame(am, 0, 0, 0.15)
	t.check(f0 == f0b, "G10 same interval resolves the same subframe (pose skipped)")
	t.check(f0 ~= f1, "G10 later interval resolves a new subframe (pose runs)")
end

t.finish("test_audit")
