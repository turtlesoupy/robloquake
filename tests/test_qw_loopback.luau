--!strict
-- End-to-end QuakeWorld loopback: qwcl connects to qwsv through the
-- real wire protocol (netchan-lite packets), completes the handshake
-- (new → serverdata → soundlist → modellist → prespawn/baselines →
-- spawn → begin), then plays: clc_move packets with one tick of
-- simulated latency so prediction actually predicts, delta-compressed
-- entity frames, and convergence of predicted vs server position.
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
t.check(svr.active, "server spawned e1m1")

local cl = qwcl.new(gamefs)

-- transports: client→server is synchronous; server→client queues so the
-- test controls delivery timing (one tick of latency during play)
local toClient: { buffer } = {}
local sclient = qwsv.wireConnect(svr, 1, { name = "looper" }, function(packet: buffer)
	table.insert(toClient, packet)
end)
t.check(sclient.active and not sclient.spawned, "wire client connected, not yet spawned")

qwcl.connect(cl, function(packet: buffer)
	qwsv.executeClientMessage(svr, sclient, packet)
end)

-- handshake pump: server replies, client processes + responds, repeat
for _ = 1, 20 do
	qwsv.sendClientMessages(svr)
	while #toClient > 0 do
		local packet = table.remove(toClient, 1) :: buffer
		qwcl.processPacket(cl, packet)
	end
	if sclient.spawned then
		break
	end
end
t.check(sclient.spawned, "handshake completed: server spawned the client")
t.eq(cl.state, "onserver", "client onserver awaiting first frame")
t.eq(cl.servercount, svr.spawncount, "spawncount agreed")
t.check(cl.worldmodel ~= nil, "client loaded the world model")
t.check(#cl.model_name > 1 and #cl.sound_name > 1, "precache lists received")
t.check(cl.movevars and cl.movevars.gravity == 800, "movevars received (gravity 800)")
local baselineCount = 0
for _ in cl.baselines do
	baselineCount += 1
end
t.check(baselineCount > 20, `baselines received ({baselineCount})`)
t.check(cl.playernum == 0, "assigned player slot 0")

-- the begin exchange owes the client its first entity frame
qwsv.sendClientMessages(svr)
while #toClient > 0 do
	local packet = table.remove(toClient, 1) :: buffer
	qwcl.processPacket(cl, packet)
end
t.check(cl.validsequence > 0, "first packetentities frame received")

local ent = svr.qdefs.ent
local player = sclient.edict
local spawnAngles = vmlib.edVector(player, ent.angles)
local yaw = spawnAngles.y
-- the PutClientInServer fixangle reached the client as svc_setangle
t.check(math.abs(((cl.viewangles.y - yaw) + 180) % 360 - 180) < 1.5, "svc_setangle applied spawn yaw")

-- play: run forward for 60 ticks, then stop for 20. one tick of
-- server→client latency keeps outgoing ahead of incoming so
-- predictMove replays unacked cmds through pmove.
local pending: { buffer } = {}
local function tick(forwardmove: number)
	cl.realtime += 0.05
	-- deliver last tick's server packet first (1-tick latency)
	for _, packet in pending do
		qwcl.processPacket(cl, packet)
	end
	pending = {}

	local cmd = {
		angles = vector.create(0, yaw, 0),
		forwardmove = forwardmove,
		sidemove = 0,
		upmove = 0,
		buttons = 0,
		impulse = 0,
		msec = 50,
	}
	qwcl.sendCmd(cl, cmd) -- synchronously runs the cmd server-side
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, packet in toClient do
		table.insert(pending, packet)
	end
	toClient = {}

	qwcl.predictMove(cl)
end

local spawnOrg = vmlib.edVector(player, ent.origin)

for _ = 1, 20 do
	tick(400)
end
t.eq(cl.state, "active", "client active after first predicted frame")
t.check(vector.magnitude(cl.simorg) > 0, "prediction produced a position")
t.check(vector.magnitude(vmlib.edVector(player, ent.origin) - spawnOrg) > 150, "player ran a real distance")

for _ = 1, 25 do
	tick(0)
end

-- convergence: predicted position vs authoritative server origin.
-- coords cross the wire at 1/8 precision, so allow that plus float
-- drift over the one-tick replay window.
local serverOrg = vmlib.edVector(player, ent.origin)
local err = vector.magnitude(cl.simorg - serverOrg)
t.check(err < 1.0, `prediction converged (|simorg - server| = {string.format("%.4f", err)})`)
local beforeStop = vmlib.edVector(player, ent.origin)
tick(0)
t.check(vector.magnitude(vmlib.edVector(player, ent.origin) - beforeStop) < 1, "player settled")

-- delta compression engaged
t.check(cl.deltaPacketCount > 20, `delta frames dominated ({cl.deltaPacketCount} delta packets)`)
t.check(cl.validsequence > 30, "validsequence tracking")

-- stats flowed over the reliable path
local svHealth = vmlib.edFloat(player, ent.health)
t.check(cl.stats[qwp.STAT_HEALTH] == svHealth // 1 and svHealth > 0, `health stat mirrors server ({cl.stats[qwp.STAT_HEALTH]})`)
t.check(cl.stats[qwp.STAT_SHELLS] >= 25, "shells stat present")

-- lightstyles and other players' info
t.check(cl.lightstyles[0] ~= nil, "lightstyles received")
t.check(cl.players[0] ~= nil and cl.players[0].name == "looper", "own player info received")

-- fire the shotgun: svc_sound must reach the client through the PHS
local cmd = {
	angles = vector.create(0, yaw, 0),
	forwardmove = 0,
	sidemove = 0,
	upmove = 0,
	buttons = 1,
	impulse = 0,
	msec = 50,
}
cl.realtime += 0.05
for _, packet in pending do
	qwcl.processPacket(cl, packet)
end
pending = {}
qwcl.sendCmd(cl, cmd)
qwsv.frame(svr, 0.05)
qwsv.sendClientMessages(svr)
for _, packet in toClient do
	qwcl.processPacket(cl, packet)
end
toClient = {}
local heardFire = false
for _, snd in cl.sounds do
	if cl.sound_name[snd.num] == "weapons/guncock.wav" then
		heardFire = true
	end
end
t.check(heardFire, "svc_sound guncock arrived through the PHS multicast")
t.check(cl.stats[qwp.STAT_SHELLS] < 25 or cl.stats[qwp.STAT_AMMO] < 25, "ammo stat dropped after firing")

-- SV_UpdateToReliableMessages: a suicide must reach the client's
-- scoreboard through the per-frame frag rebroadcast
local fragsBefore = cl.players[0] and cl.players[0].frags or 0
qwcl.sendStringCmd(cl, "kill")
qwcl.flush(cl)
for _ = 1, 3 do
	tick(0)
end
t.check(cl.players[0].frags < fragsBefore, `frag change rebroadcast ({cl.players[0].frags})`)

-- packet entities carry the world items
local lastFrame = cl.frames[bit32.band(cl.netchan.incoming_sequence, qwp.UPDATE_MASK)]
t.check(#lastFrame.packet_entities > 0, `packet entities present ({#lastFrame.packet_entities})`)

--------------------------------------------------------------------------
-- runtime PF_centerprint and PF_lightstyle must reach the wire (the
-- former via the netchan reliable stream — ClientReliableWrite — and
-- the latter through the ss_active broadcast)
local dfs = require("../src/shared/engine/progs/defs")
local svm = svr.vm
vmlib.setGlobalInt(svm, dfs.OFS_PARM0, sclient.edict.num)
vmlib.setGlobalInt(svm, dfs.OFS_PARM0 + 3, vmlib.allocString(svm, "duel to the death"))
svm.argc = 2
svm.builtins[73](svm) -- centerprint
vmlib.setGlobalFloat(svm, dfs.OFS_PARM0, 11)
vmlib.setGlobalInt(svm, dfs.OFS_PARM0 + 3, vmlib.allocString(svm, "azazaza"))
svm.argc = 2
svm.builtins[35](svm) -- lightstyle
tick(0)
tick(0)
local sawCenter = false
for _, cp in cl.centerprints do
	if cp == "duel to the death" then
		sawCenter = true
	end
end
t.check(sawCenter, "PF_centerprint arrived over the netchan reliable stream")
t.eq(cl.lightstyles[11], "azazaza", "runtime PF_lightstyle broadcast reached the client")

--------------------------------------------------------------------------
-- changelevel: SV_SaveSpawnparms + full re-handshake over the wire
-- (mirrors qwserver.luau's changelevelTo consumer)
vmlib.edSetFloat(player, ent.ammo_nails, 142)
vmlib.edSetFloat(player, ent.items, bit32.bor(vmlib.edFloat(player, ent.items) // 1, 4)) -- IT_NAILGUN

qwsv.saveSpawnparms(svr)
qwsv.spawnServer(svr, "e1m2")
t.check(svr.active, "qw server respawned on e1m2")
sclient.spawned = false
qwsv.newF(svr, sclient)
sclient.send_message = true
qwsv.replyToClient(svr, sclient)

-- drain and re-run the handshake exactly like the first connect
pending = {}
for _ = 1, 20 do
	while #toClient > 0 do
		local packet = table.remove(toClient, 1) :: buffer
		qwcl.processPacket(cl, packet)
	end
	qwsv.sendClientMessages(svr)
	if sclient.spawned then
		break
	end
end
while #toClient > 0 do
	local packet = table.remove(toClient, 1) :: buffer
	qwcl.processPacket(cl, packet)
end
t.check(sclient.spawned, "re-handshake completed after changelevel")
t.eq(cl.servercount, svr.spawncount, "new spawncount agreed")
t.check(cl.worldmodel ~= nil and cl.model_name[1] == "maps/e1m2.bsp", "client cleared state and loaded e1m2")

-- DecodeLevelParms: the nailgun + nails carried through the parms
local player2 = sclient.edict
t.check(bit32.band(vmlib.edFloat(player2, svr.qdefs.ent.items) // 1, 4) ~= 0, "qw nailgun carried")
t.eq(vmlib.edFloat(player2, svr.qdefs.ent.ammo_nails), 142, "qw nail count carried")

--------------------------------------------------------------------------
-- host tools: SV_ConSay_f reaches the client; SV_Kick_f drops it
cl.prints = {}
qwsv.conSay(svr, "hello from the console")
tick(0)
tick(0)
local sawSay = false
for _, pr in cl.prints do
	if pr.text:find("console: hello from the console") then
		sawSay = true
	end
end
t.check(sawSay, "conSay reached the client (PRINT_CHAT)")

t.check(qwsv.kick(svr, sclient.userid), "kick found the userid")
t.check(not sclient.active, "kicked client dropped")

t.finish("test_qw_loopback")
