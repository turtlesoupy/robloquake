--!strict
-- Spectator autocam (cl_cam.c) over the real loopback wire: a spectator
-- client and two players; Cam_CheckHighTarget picks the frag leader,
-- ptrack reaches the server (spec_track), BUTTON_JUMP cycles targets
-- with the edge gate, a vanished target retargets, clc_tmove rides the
-- tracked player, and Cam_Unlock clears the server track.
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

type Link = { cl: any, sc: any, queue: { buffer } }
local function link(slot: number, name: string, extra: { [string]: string }?): Link
	local L = { cl = qwcl.new(gamefs), sc = nil :: any, queue = {} :: { buffer } }
	local info: { [string]: string } = { name = name }
	if extra then
		for k, v in extra do
			info[k] = v
		end
	end
	L.sc = qwsv.wireConnect(svr, slot, info, function(packet: buffer)
		table.insert(L.queue, packet)
	end)
	qwcl.connect(L.cl, function(packet: buffer)
		qwsv.executeClientMessage(svr, L.sc, packet)
	end)
	return L
end

local S = link(1, "spec", { spectator = "1" })
local A = link(2, "alpha")
local B = link(3, "bravo")

for _ = 1, 40 do
	qwsv.sendClientMessages(svr)
	for _, L in { S, A, B } do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
	end
	if S.sc.spawned and A.sc.spawned and B.sc.spawned then
		break
	end
end
t.check(S.sc.spawned and A.sc.spawned and B.sc.spawned, "all three clients spawned")
t.check(S.cl.spectator == true, "spectator bit reached the spectator client")
t.check(S.sc.spectator == true, "server knows the spectator")

local function tick()
	for _, L in { S, A, B } do
		L.cl.realtime += 0.05
	end
	local cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, impulse = 0, msec = 50 }
	qwcl.sendCmd(A.cl, cmd)
	qwcl.sendCmd(B.cl, cmd)
	qwcl.sendCmd(S.cl, cmd)
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, L in { S, A, B } do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
		qwcl.predictMove(L.cl) -- flips onserver -> active on the first update
	end
end
for _ = 1, 5 do
	tick()
end

-- give bravo the frag lead server-side, then let the scoreboards sync
local ent = svr.qdefs.ent
vmlib.edSetFloat(B.sc.edict, ent.frags, 5)
for _ = 1, 6 do
	tick()
end
t.eq(S.cl.players[2] and S.cl.players[2].frags, 5, "spectator sees bravo's frags")

-- Cam_CheckHighTarget via camTrack: picks the frag leader (bravo, slot 2)
qwcl.camTrack(S.cl, 0)
t.eq(S.cl.cam.spec_track, 2, "hightrack locked the frag leader")
t.check(S.cl.cam.locked and S.cl.cam.autocam == 1, "cam locked in CAM_TRACK")
qwcl.flush(S.cl)
tick()
t.eq(S.sc.spec_track, 3, "ptrack reached the server (1-based tracked player)")

-- BUTTON_JUMP edge cycles to the next player (alpha, slot 1)
qwcl.camTrack(S.cl, 2)
t.eq(S.cl.cam.spec_track, 1, "jump edge cycled to the next player")
qwcl.camTrack(S.cl, 2)
t.eq(S.cl.cam.spec_track, 1, "held jump does not pogo-cycle")
qwcl.camTrack(S.cl, 0) -- release
qwcl.camTrack(S.cl, 2)
t.eq(S.cl.cam.spec_track, 2, "release + press cycles again")

-- tracked player vanishes: retarget to the survivor
t.check(qwsv.kick(svr, B.sc.userid), "kicked bravo")
for _ = 1, 4 do
	tick()
end
qwcl.camTrack(S.cl, 0)
t.eq(S.cl.cam.spec_track, 1, "dead/vanished target retargeted to the survivor")

-- clc_tmove rides the tracked player when >16 units off: refresh the
-- frame, then force the sim far away (predictMove would re-derive simorg,
-- so set it right before the cam pass like the pre-cmd hook does)
tick()
S.cl.simorg = vector.create(2000, 2000, 200)
local beforeLen = S.cl.netchan.message.cursize
qwcl.camTrack(S.cl, 0)
t.check(S.cl.netchan.message.cursize > beforeLen, "clc_tmove written when >16 units from the target")

-- Cam_Unlock clears both sides
qwcl.camUnlock(S.cl)
t.check(S.cl.cam.autocam == 0 and not S.cl.cam.locked, "camUnlock cleared client state")
qwcl.flush(S.cl)
tick()
t.eq(S.sc.spec_track, 0, "bare ptrack cleared the server track")

-- svc_intermission (V_CalcIntermissionRefdef inputs): fixed origin +
-- angles land in simorg/simangles with velocity zeroed
do
	local msg = require("../src/shared/engine/common/msg")
	local sb = msg.newBuf(64)
	msg.writeByte(sb, qwp.svc_intermission)
	msg.writeCoord(sb, 512)
	msg.writeCoord(sb, -128)
	msg.writeCoord(sb, 64)
	msg.writeAngle(sb, 0)
	msg.writeAngle(sb, 90)
	msg.writeAngle(sb, 0)
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	qwcl.parseServerMessage(S.cl, msg.reader(pkt))
	t.eq(S.cl.intermission, 1, "svc_intermission sets intermission 1")
	t.check(vector.magnitude(S.cl.simorg - vector.create(512, -128, 64)) < 0.5, "intermission pins simorg")
	t.check(S.cl.simvel == vector.zero, "intermission zeroes simvel")
	t.check(math.abs(S.cl.simangles.y - 90) < 1.5, "intermission pins simangles")
end

-- svc_finale: intermission 2 (Sbar_FinaleOverlay's gate) + the finale
-- text riding the centerprint sink
do
	local msg = require("../src/shared/engine/common/msg")
	local sb = msg.newBuf(64)
	msg.writeByte(sb, qwp.svc_finale)
	msg.writeString(sb, "the end")
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	qwcl.parseServerMessage(S.cl, msg.reader(pkt))
	t.eq(S.cl.intermission, 2, "svc_finale sets intermission 2")
	t.eq(S.cl.centerprints[#S.cl.centerprints], "the end", "finale text rides centerprints")
end

--------------------------------------------------------------------------
-- the flyby search (vectoangles/vlen statics, Cam_DoTrace/Cam_TryFlyby/
-- Cam_IsVisible/InitFlyby): find a camera spot around the tracked player
do
	-- vectoangles: the C int truncation + wraps
	local va = qwcl.camVectoangles(vector.create(0, 0, 5))
	t.check(va.x == 90 and va.y == 0, "cam vectoangles: straight up -> pitch 90")
	va = qwcl.camVectoangles(vector.create(0, 0, -5))
	t.eq(va.x, 270, "cam vectoangles: straight down -> pitch 270")
	va = qwcl.camVectoangles(vector.create(1, 1, 0))
	t.eq(va.y, 45, "cam vectoangles: yaw 45 (int-truncated)")
	va = qwcl.camVectoangles(vector.create(-1, -1, 0))
	t.eq(va.y, 225, "cam vectoangles: negative yaw wraps +360")
	t.check(math.abs(qwcl.camVlen(vector.create(3, 4, 0)) - 5) < 1e-6, "cam vlen")

	-- InitFlyby around the live tracked player on dm3
	local tracked = S.cl.frames[bit32.band(S.cl.parsecount, 63)].playerstate[S.cl.cam.spec_track]
	t.check(tracked ~= nil, "flyby fixture: tracked playerstate present")
	local playerOrg = tracked.origin
	local selfOrg = S.cl.simorg
	local ok = qwcl.initFlyby(S.cl, selfOrg, playerOrg, tracked.viewangles, false)
	t.check(ok, "InitFlyby: found a camera spot (checkvis false)")
	local spot = S.cl.cam.desired_position
	local dist = qwcl.camVlen(spot - playerOrg)
	t.check(dist >= 32 and dist <= 800, "InitFlyby: spot within the 32..800 band")
	t.check(qwcl.camIsVisible(S.cl, playerOrg, spot), "Cam_IsVisible: the found spot sees the player")
	t.check(S.cl.cam.locked, "InitFlyby: locks the camera")
end

t.finish("test_qw_cam")
