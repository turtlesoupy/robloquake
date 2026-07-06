--!strict
-- QW .qwd demo pipeline (cl_demo.c): record a live loopback session
-- (the port's CL_Record_f re-handshakes so the fresh signon is captured
-- over the wire), serialize to the C block format, parse back, and
-- replay through a brand-new client.
local t = require("./testutil")
local fs = require("@lune/fs")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwp = require("../src/shared/engine/qw/qwprotocol")

local gamefs = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(gamefs, qwprogs)
svr.print = function(_s: string) end
qwsv.spawnServer(svr, "e1m1")

local cl = qwcl.new(gamefs)
local queue: { buffer } = {}
local sc = qwsv.wireConnect(svr, 1, { name = "director" }, function(packet: buffer)
	table.insert(queue, packet)
end)
qwcl.connect(cl, function(packet: buffer)
	qwsv.executeClientMessage(svr, sc, packet)
end)

local function pump()
	while #queue > 0 do
		qwcl.processPacket(cl, table.remove(queue, 1) :: buffer)
	end
end
for _ = 1, 40 do
	qwsv.sendClientMessages(svr)
	pump()
	if sc.spawned then
		break
	end
end
t.check(sc.spawned, "client spawned")
local yaw = cl.viewangles.y -- svc_setangle spawn yaw (face open space)

-- one tick of server->client latency keeps outgoing ahead of incoming so
-- predictMove replays unacked cmds (the test_qw_loopback pattern)
local pending: { buffer } = {}
local function tick(forwardmove: number)
	cl.realtime += 0.05
	for _, packet in pending do
		qwcl.processPacket(cl, packet)
	end
	pending = {}
	qwcl.sendCmd(cl, {
		angles = vector.create(0, yaw, 0),
		forwardmove = forwardmove,
		sidemove = 0,
		upmove = 0,
		buttons = 0,
		impulse = 0,
		msec = 50,
	})
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, p2 in queue do
		table.insert(pending, p2)
	end
	table.clear(queue)
	qwcl.predictMove(cl)
end
for _ = 1, 10 do
	tick(0)
end
t.eq(cl.state, "active", "client active before recording")

--------------------------------------------------------------------------
-- CL_Record_f: the re-handshake signon lands in the demo
qwcl.recordStart(cl)
for _ = 1, 15 do
	tick(0) -- re-handshake completes over the wire while recording
end
t.eq(cl.state, "active", "client re-handshaked to active while recording")
local startOrg = cl.simorg
for _ = 1, 40 do
	tick(400) -- run forward: the demo captures real motion
end
local runDist = vector.magnitude(cl.simorg - startOrg)
t.check(runDist > 100, "recorded run covered real distance")

local blocks = qwcl.recordStop(cl)
t.check(blocks ~= nil and #blocks :: any > 50, "CL_Stop_f: block stream captured")
do
	local setAt = 0
	for i, b in blocks :: { any } do
		if b.type == 2 then
			setAt = i
			break
		end
	end
		t.check((blocks :: any)[1].type == 1 and setAt == 6, "CL_WriteSetDemoMessage: dem_set closes the 5-block synthesized signon")
end
local sawCmd, sawRead = false, false
for _, b in blocks :: { any } do
	if b.type == 0 then
		sawCmd = true
	elseif b.type == 1 then
		sawRead = true
	end
end
t.check(sawCmd and sawRead, "demo carries dem_cmd and dem_read blocks")

--------------------------------------------------------------------------
-- .qwd byte round-trip (CL_WriteDemoCmd/WriteDemoMessage layouts)
local qwd = qwcl.demoSerialize(blocks :: { any })
t.check(buffer.len(qwd) > 1000, "serialized .qwd has real size")
local parsed = qwcl.demoParse(qwd)
t.eq(#parsed, #(blocks :: any), ".qwd parse recovers every block")
do
	local a, b
	for i, blk in blocks :: { any } do
		if blk.type == 0 then
			a, b = blk, parsed[i]
			break
		end
	end
	t.check(a.cmd.forwardmove == b.cmd.forwardmove and a.cmd.msec == b.cmd.msec, "dem_cmd usercmd round-trips")
	t.check(a.angles == b.angles, "dem_cmd viewangles round-trip")
end

--------------------------------------------------------------------------
-- CL_PlayDemo_f / CL_GetDemoMessage: replay into a brand-new client
local pb = qwcl.new(gamefs)
qwcl.connect(pb, function(_packet: buffer) end) -- sends go nowhere
pb.dprint = function(_s: string) end

local idx = 1
local demotime = (parsed[1] :: any).time
local maxOrg = 0
local trackedNum: number? = nil
for _ = 1, 2000 do
	if idx > #parsed then
		break
	end
	demotime += 0.05
	pb.realtime = demotime
	idx = qwcl.demoStep(pb, parsed, idx, demotime)
	if pb.state ~= "disconnected" and pb.playernum then
		trackedNum = pb.playernum
		local ps = pb.frames[bit32.band(pb.parsecount, qwp.UPDATE_MASK)].playerstate[pb.playernum]
		if ps and ps.messagenum == pb.parsecount then
			maxOrg = math.max(maxOrg, vector.magnitude(ps.origin - startOrg))
		end
	end
end
t.eq(idx, #parsed + 1, "playback consumed the whole demo")
t.check(pb.worldmodel ~= nil, "playback client loaded the world from the recorded signon")
t.check(trackedNum ~= nil, "playback client took the recorded player slot")
t.check(maxOrg > 100, "the recorded run replays (view player moved >100 units)")

t.finish("test_qw_demo")
