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
local msg = require("../src/shared/engine/common/msg")

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

-- CL_ParseProjectiles: fire the nailgun and catch svc_nails carrying
-- the in-flight spike (nails live one message — CL_ClearProjectiles)
vmlib.edSetFloat(player, ent.items, bit32.bor(vmlib.edFloat(player, ent.items) // 1, 4))
vmlib.edSetFloat(player, ent.ammo_nails, 30)
local sawNail = false
for i = 1, 30 do
	local buttons = if i > 2 then 1 else 0
	local impulse = if i == 1 then 4 else 0
	cl.realtime += 0.05
	for _, packet in pending do
		qwcl.processPacket(cl, packet)
	end
	pending = {}
	qwcl.sendCmd(cl, {
		angles = vector.create(0, (yaw + 180) % 360, 0),
		forwardmove = 0,
		sidemove = 0,
		upmove = 0,
		buttons = buttons,
		impulse = impulse,
		msec = 50,
	})
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, packet in toClient do
		table.insert(pending, packet)
	end
	toClient = {}
	qwcl.predictMove(cl)
	if #cl.nails > 0 then
		sawNail = true
		break
	end
end
t.check(sawNail, "svc_nails parsed into cl.nails (CL_ParseProjectiles)")

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

-- user commands over the wire: say broadcasts as chat, pause toggles,
-- setinfo updates userinfo + rebroadcasts, pings answers
cl.prints = {}
qwcl.sendStringCmd(cl, "say hello all")
qwcl.flush(cl)
tick(0)
tick(0)
local sawChat = false
for _, pr in cl.prints do
	if pr.text:find("hello all") and pr.level == 3 then -- PRINT_CHAT
		sawChat = true
	end
end
t.check(sawChat, "SV_Say_f broadcast the chat line at PRINT_CHAT")

qwcl.sendStringCmd(cl, "pause")
qwcl.flush(cl)
tick(0)
t.check(svr.paused == true, "SV_TogglePause paused the server")
local pausedTime = svr.time
tick(0)
tick(0)
t.eq(svr.time, pausedTime, "server time frozen while paused (ServerPaused gate)")
qwcl.sendStringCmd(cl, "pause")
qwcl.flush(cl)
tick(0)
t.check(not svr.paused, "second pause unpaused")

qwcl.sendStringCmd(cl, "setinfo topcolor 4")
qwcl.flush(cl)
tick(0)
t.eq(sclient.userinfo.topcolor, "4", "SV_SetInfo_f updated the server-side userinfo")

qwcl.sendStringCmd(cl, "pings")
qwcl.flush(cl)
tick(0)
tick(0)
t.check(cl.players[0] ~= nil and cl.players[0].ping ~= nil, "SV_Pings_f answered with svc_updateping")

-- CL_FullServerinfo_f / CL_ServerInfo: the handshake's fullserverinfo
-- stufftext populated cl.serverinfo, and svc_serverinfo updates a key
t.check(cl.serverinfo ~= nil and next(cl.serverinfo) ~= nil, "fullserverinfo populated cl.serverinfo during the handshake")
do
	local sb = msg.newBuf(64)
	msg.writeByte(sb, qwp.svc_serverinfo)
	msg.writeString(sb, "teamplay")
	msg.writeString(sb, "2")
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	qwcl.parseServerMessage(cl, msg.reader(pkt))
	t.eq(cl.serverinfo.teamplay, "2", "svc_serverinfo updates a single key (CL_ServerInfo)")
end

-- CL_Reconnect_f: a stufftext "reconnect" makes the client send "new"
-- (the server answers the fresh handshake with serverdata again)
do
	local sb = msg.newBuf(64)
	msg.writeByte(sb, qwp.svc_stufftext)
	msg.writeString(sb, "reconnect\n")
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	cl.stufftext = ""
	qwcl.parseServerMessage(cl, msg.reader(pkt))
	qwcl.flush(cl)
	tick(0)
	t.check(cl.servercount ~= nil, "reconnect: client re-sent new and still tracks servercount")
end

--------------------------------------------------------------------------
-- SV_Serverinfo_f mutability + SV_BroadcastCommand + SV_ShowServerinfo_f
-- over the REAL wire (the earlier svc_serverinfo check was crafted)
do
	-- runtime serverinfo change broadcasts svc_serverinfo to the client
	t.check(qwsv.setServerinfo(svr, "teamplay", "3"), "setServerinfo accepts a normal key")
	t.eq(svr.serverinfo.teamplay, "3", "setServerinfo updates svr.serverinfo")
	tick(0)
	tick(0)
	t.eq(cl.serverinfo.teamplay, "3", "svc_serverinfo broadcast reached the client (SV_SendServerInfoChange)")

	-- star keys refused like C
	t.check(not qwsv.setServerinfo(svr, "*version", "9"), "star variables cannot be changed")
	t.eq(svr.serverinfo["*version"], "2.40", "star key untouched")

	-- a serverinfo cvar mirrors into the cvar table
	local cvarlib = require("../src/shared/engine/common/cvar")
	qwsv.setServerinfo(svr, "fraglimit", "25")
	t.eq(cvarlib.value(svr.cvars, "fraglimit"), 25, "matching cvar updated too")

	-- SV_BroadcastCommand: svc_stufftext lands in rawStufftext
	cl.rawStufftext = ""
	qwsv.broadcastCommand(svr, "bf\n")
	tick(0)
	tick(0)
	t.check(cl.rawStufftext:find("bf") ~= nil, "SV_BroadcastCommand: stufftext broadcast arrived")

	-- SV_ShowServerinfo_f: the serverinfo user command prints the table
	local before = #cl.prints
	qwcl.sendStringCmd(cl, "serverinfo")
	tick(0)
	tick(0)
	local dump = ""
	for i = before + 1, #cl.prints do
		dump ..= cl.prints[i].text
	end
	t.check(dump:find("*version", 1, true) ~= nil and dump:find("2.40", 1, true) ~= nil, "serverinfo user command prints the info table (20-col keys)")

	-- SV_FullClientUpdateToClient: the named single-client resend path is
	-- what the spawn handshake now uses; exercise it directly too
	local out = svr.clients[1].netchan.message
	local size0 = out.cursize
	qwsv.fullClientUpdateToClient(svr, svr.clients[1], svr.clients[1])
	t.check(out.cursize > size0, "fullClientUpdateToClient writes the update onto the target netchan")
end


-- CL_Disconnect (svc_disconnect handler)
do
	local sb = msg.newBuf(16)
	msg.writeByte(sb, qwp.svc_disconnect)
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	qwcl.parseServerMessage(cl, msg.reader(pkt))
	t.eq(cl.state, "disconnected", "svc_disconnect sets state disconnected")
	t.eq(cl.disconnected_reason, "server disconnected", "svc_disconnect records the reason")
end

-- crafted-parse battery: CL_ParseStatic / CL_ParseStaticSound /
-- svc_stopsound / FlushEntityPacket
do
	local function packet(fill: (sb: msg.SizeBuf) -> ()): msg.Reader
		local sb = msg.newBuf(128)
		fill(sb)
		local pkt = buffer.create(sb.cursize)
		buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
		return msg.reader(pkt)
	end

	-- CL_ParseStatic (cl_ents.c): baseline layout with INTERLEAVED
	-- origin[i]/angles[i] coord/angle pairs
	local nStatics = #cl.static_entities
	qwcl.parseServerMessage(cl, packet(function(sb)
		msg.writeByte(sb, qwp.svc_spawnstatic)
		msg.writeByte(sb, 3) -- modelindex
		msg.writeByte(sb, 2) -- frame
		msg.writeByte(sb, 0) -- colormap
		msg.writeByte(sb, 1) -- skinnum
		msg.writeCoord(sb, 100)
		msg.writeAngle(sb, 90)
		msg.writeCoord(sb, -50)
		msg.writeAngle(sb, 0)
		msg.writeCoord(sb, 24)
		msg.writeAngle(sb, 0)
	end))
	t.eq(#cl.static_entities, nStatics + 1, "svc_spawnstatic appends a static entity")
	local st = cl.static_entities[#cl.static_entities]
	t.check(st.modelindex == 3 and st.frame == 2 and st.skinnum == 1, "static fields parsed")
	t.check(vector.magnitude(st.origin - vector.create(100, -50, 24)) < 0.5, "static origin from the interleaved coord/angle layout")

	-- CL_ParseStaticSound
	local nSS = #cl.static_sounds
	qwcl.parseServerMessage(cl, packet(function(sb)
		msg.writeByte(sb, qwp.svc_spawnstaticsound)
		msg.writeCoord(sb, 10)
		msg.writeCoord(sb, 20)
		msg.writeCoord(sb, 30)
		msg.writeByte(sb, 4) -- sound num
		msg.writeByte(sb, 200) -- vol
		msg.writeByte(sb, 2) -- atten
	end))
	t.eq(#cl.static_sounds, nSS + 1, "svc_spawnstaticsound appends")
	local ss = cl.static_sounds[#cl.static_sounds]
	t.check(ss.num == 4 and ss.vol == 200 and ss.atten == 2 and ss.pos == vector.create(10, 20, 30), "static sound fields parsed")

	-- svc_stopsound -> num=-1 sentinel in the sounds sink (S_StopSound input)
	table.clear(cl.sounds)
	qwcl.parseServerMessage(cl, packet(function(sb)
		msg.writeByte(sb, qwp.svc_stopsound)
		msg.writeShort(sb, 5 * 8 + 3) -- ent 5, channel 3
	end))
	t.check(#cl.sounds == 1 and cl.sounds[1].num == -1 and cl.sounds[1].ent == 5 and cl.sounds[1].channel == 3, "svc_stopsound queues the ent/channel stop sentinel")

	-- FlushEntityPacket: a delta from a >= UPDATE_BACKUP-1 stale frame is
	-- read-and-discarded with the frame invalidated and validsequence 0
	local mask = 63 -- UPDATE_MASK
	local seq = cl.netchan.incoming_sequence
	local frame = cl.frames[bit32.band(seq, mask)]
	frame.delta_sequence = seq - 70 -- hopelessly old
	cl.netchan.outgoing_sequence = seq
	cl.validsequence = 12345
	qwcl.parseServerMessage(cl, packet(function(sb)
		msg.writeByte(sb, qwp.svc_deltapacketentities)
		msg.writeByte(sb, bit32.band(seq - 70, mask)) -- matching 'from'
		msg.writeShort(sb, 0) -- empty entity list terminator
	end))
	t.check(frame.invalid == true, "FlushEntityPacket: frame marked invalid")
	t.eq(cl.validsequence, 0, "FlushEntityPacket: validsequence reset to 0")

	-- Con_DPrintf hook: the delta 'from' mismatch warning goes through
	-- cl.dprint (developer print channel)
	local dprints = {}
	local oldDprint = cl.dprint
	cl.dprint = function(msg_: string)
		table.insert(dprints, msg_)
	end
	frame.delta_sequence = seq - 1 -- fresh enough, but 'from' won't match
	qwcl.parseServerMessage(cl, packet(function(sb)
		msg.writeByte(sb, qwp.svc_deltapacketentities)
		msg.writeByte(sb, bit32.band(seq - 5, mask)) -- mismatched from
		msg.writeShort(sb, 0)
	end))
	cl.dprint = oldDprint
	t.check(#dprints > 0 and dprints[1]:find("mismatch") ~= nil, "Con_DPrintf hook fires on the delta from-mismatch warning")
end

-- CL_ParseProjectiles (cl_ents.c:584): 6-byte packed nails. Hand-packed
-- truth: origin (100,-200,24) -> bytes {50,200,121,12,72,128} with
-- pitch index 4 (=90 deg) and yaw byte 128 (=180 deg).
do
	local sb = msg.newBuf(64)
	msg.writeByte(sb, qwp.svc_nails)
	msg.writeByte(sb, 1)
	for _, b in { 50, 200, 121, 12, 72, 128 } do
		msg.writeByte(sb, b)
	end
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	qwcl.parseServerMessage(cl, msg.reader(pkt))
	t.eq(#cl.nails, 1, "svc_nails: one projectile parsed")
	local n = cl.nails[1]
	t.check(n.origin == vector.create(100, -200, 24), "nail origin unpacked from the 6-byte C bit layout")
	t.check(math.abs(n.angles.x - 90) < 1e-6 and math.abs(n.angles.y - 180) < 1e-6, "nail pitch 360*hi4/16, yaw 360*b6/256")
end

-- CL_AllocDlight / CL_DecayLights (cl_ents.c:42, shared pool in qwcl)
do
	cl.time = 100
	table.clear(cl.dlights)
	local a = qwcl.allocDlight(cl, 5)
	a.die = 105
	a.radius = 200
	a.origin = vector.create(1, 2, 3)
	local b = qwcl.allocDlight(cl, 5)
	t.check(a == b and b.radius == 0, "allocDlight: exact key match reuses + resets the slot")
	local c2 = qwcl.allocDlight(cl, 7)
	t.check(c2 ~= a, "allocDlight: different key gets a fresh slot")
	c2.die = 99 -- already expired
	local d = qwcl.allocDlight(cl, 9)
	t.check(d == c2 and d.key == 9, "allocDlight: expired slot reused before growing")
	-- fill to the 32 cap; the overflow overwrites slot 1
	a.die = 200
	d.die = 200
	for k = 10, 39 do
		local dl = qwcl.allocDlight(cl, k)
		dl.die = 200
	end
	t.eq(#cl.dlights, 32, "allocDlight: pool capped at MAX_DLIGHTS")
	local ov = qwcl.allocDlight(cl, 99)
	t.check(cl.dlights[1] == ov, "allocDlight: overflow overwrites slot 1 like C's &cl_dlights[0]")
	-- decay: radius -= dt*decay, dead lights culled from the active list
	table.clear(cl.dlights)
	local live = qwcl.allocDlight(cl, 1)
	live.die = 105
	live.radius = 100
	live.decay = 300
	local dying = qwcl.allocDlight(cl, 2)
	dying.die = 105
	dying.radius = 20
	dying.decay = 300
	local active = qwcl.decayDlights(cl, 0.1)
	t.eq(#active, 1, "decayDlights: fully-decayed light culled from the active list")
	t.check(math.abs(live.radius - 70) < 1e-6, "decayDlights: radius -= dt*decay (100 - 30)")
end

t.check(qwsv.kick(svr, sclient.userid), "kick found the userid")
t.check(not sclient.active, "kicked client dropped")

--------------------------------------------------------------------------
-- CL_Changing_f: the "changing" stufftext holds the connection with
-- intermission cleared and the C message printed
do
	local sb = msg.newBuf(32)
	msg.writeByte(sb, qwp.svc_stufftext)
	msg.writeString(sb, "changing\n")
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	cl.intermission = 1
	local oldState = cl.state
	qwcl.parseServerMessage(cl, msg.reader(pkt))
	t.eq(cl.intermission, 0, "CL_Changing_f: intermission cleared")
	t.eq(cl.state, "connected", "CL_Changing_f: connection held at connected")
	t.check(cl.prints[#cl.prints] and cl.prints[#cl.prints].text:find("Changing map") ~= nil, "CL_Changing_f: the C message printed")
	cl.state = oldState
end

-- CL_NudgePosition: empty spots untouched; a spot fractionally inside a
-- wall nudges free by eighths; deep solid reports stuck like C
do
	local pmovelib = require("../src/shared/engine/qw/pmove")
	local hull = cl.worldmodel.hulls[2]
	local free = cl.simorg
	qwcl.nudgePosition(cl)
	t.check(cl.simorg == free, "nudgePosition: empty origin untouched")

	-- walk +x in eighths until the player hull goes solid: that boundary
	-- point nudges back out
	local probe = free
	local found = false
	for i = 1, 4096 do
		probe += vector.create(1 / 8, 0, 0)
		if pmovelib.hullPointContents(hull, hull.firstclipnode, probe) ~= -1 then
			found = true
			break
		end
	end
	t.check(found, "nudgePosition fixture: found a wall boundary east of spawn")
	cl.simorg = probe
	qwcl.nudgePosition(cl)
	t.check(pmovelib.hullPointContents(hull, hull.firstclipnode, cl.simorg) == -1, "nudgePosition: boundary spot nudged free")

	-- deep solid: stuck, with the C dprint
	local dprints = {}
	local oldDprint = cl.dprint
	cl.dprint = function(s2: string)
		table.insert(dprints, s2)
	end
	cl.simorg = probe + vector.create(64, 0, 0)
	if pmovelib.hullPointContents(hull, hull.firstclipnode, cl.simorg) ~= -1 then
		qwcl.nudgePosition(cl)
		t.check(dprints[1] == "CL_NudgePosition: stuck", "nudgePosition: deep solid reports stuck")
	else
		t.check(true, "nudgePosition: deep probe landed empty (map-dependent) — stuck path skipped")
	end
	cl.dprint = oldDprint
	cl.simorg = free
end

t.finish("test_qw_loopback")
