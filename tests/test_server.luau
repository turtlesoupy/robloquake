--!strict
-- End-to-end headless server test: spawns e1m1 with the real shareware
-- progs.dat, connects a fake client through the signon sequence, and runs
-- the game for several seconds of simulated time.

local t = require("./testutil")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local svlib = require("../src/shared/engine/server/sv")
local msg = require("../src/shared/engine/common/msg")
local proto = require("../src/shared/engine/protocol")
local qd = require("../src/shared/engine/quakedef")

local ent = defs.ent
local glob = defs.glob

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(s: string)
	print("  [sv] " .. s)
end

host.spawnServer(svr, "e1m1")
t.check(svr.active, "server active")

local vm = svr.vm

-- entity census after spawn
local classCounts: { [string]: number } = {}
for i = 0, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if e.free then
		continue
	end
	local cn = vmlib.edString(vm, e, ent.classname)
	if cn ~= "" then
		classCounts[cn] = (classCounts[cn] or 0) + 1
	end
end

t.eq(classCounts["worldspawn"], 1, "one worldspawn")
t.eq(classCounts["monster_army"], 18, "grunts spawned")
t.eq(classCounts["monster_dog"], 5, "dogs spawned")
t.eq(classCounts["door"], 21, "doors spawned (func_door renames to door)")
t.check((classCounts["item_health"] or 0) >= 5, "health spawned")
t.check((classCounts["info_player_start"] or 0) == 1, "player start")
t.check((classCounts["trigger_changelevel"] or 0) >= 1, "changelevel trigger")
t.check(vmlib.globalFloat(vm, glob.total_monsters) > 20, "total_monsters counted")
t.check(vmlib.globalFloat(vm, glob.total_secrets) >= 5, "total_secrets counted")

-- precaches
t.check(#svr.model_precache > 30, "models precached")
t.check(#svr.sound_precache > 30, "sounds precached")
t.check(svlib.modelIndex(svr, "progs/player.mdl") > 0, "player.mdl precached")
t.check(svr.signon.cursize > 1000, "signon buffer populated (baselines/ambients)")

-- lightstyles registered by worldspawn
t.eq(svr.lightstyles[0], "m", "lightstyle 0")
t.eq(svr.lightstyles[63], "a", "lightstyle 63")
t.check(#(svr.lightstyles[10] :: string) > 10, "lightstyle 10 (animated)")

-- connect a fake client
local unreliable: { buffer } = {}
local reliable: { buffer } = {}
local clientnum = host.findFreeClient(svr) :: number
t.eq(clientnum, 1, "first client slot")
local client = svr.clients[clientnum]
client.sendUnreliable = function(data: buffer)
	table.insert(unreliable, data)
	return true
end
client.sendReliable = function(data: buffer)
	table.insert(reliable, data)
	return true
end
host.connectClient(svr, clientnum)
t.check(client.active, "client active")

local function clientSend(build: (out: msg.SizeBuf) -> ())
	local out = msg.newBuf(1024)
	build(out)
	table.insert(client.inbox, msg.snapshot(out))
end
local function sendCmd(s: string)
	clientSend(function(out)
		msg.writeByte(out, proto.clc_stringcmd)
		msg.writeString(out, s)
	end)
end

-- signon sequence
sendCmd("prespawn")
host.frame(svr, 0.05)
sendCmd("name Ranger")
sendCmd("color 4 4")
sendCmd("spawn")
host.frame(svr, 0.05)
sendCmd("begin")
host.frame(svr, 0.05)
t.check(client.spawned, "client spawned")

local player = client.edict
t.eq(vmlib.edString(vm, player, ent.classname), "player", "player classname set by PutClientInServer")
t.check(vmlib.edFloat(player, ent.health) == 100, "player health 100")
local porg = vmlib.edVector(player, ent.origin)
t.check(vector.magnitude(porg - vector.create(480, -352, 88)) < 60, `player near start ({porg})`)
t.check(vmlib.edFloat(player, ent.movetype) == qd.MOVETYPE_WALK, "player walks")

-- run 5 seconds of game time; the player should settle on the ground and
-- stay alive; monsters should think (frames change)
local grunt: vmlib.Edict? = nil
for i = 0, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "monster_army" then
		grunt = e
		break
	end
end
assert(grunt, "found a grunt")
local gruntFrames: { [number]: boolean } = {}

for _ = 1, 100 do
	-- client sends a move packet each frame (standing still)
	clientSend(function(out)
		msg.writeByte(out, proto.clc_move)
		msg.writeFloat(out, svr.time) -- ping time
		msg.writeAngle(out, 0)
		msg.writeAngle(out, 0)
		msg.writeAngle(out, 0)
		msg.writeShort(out, 0) -- forward
		msg.writeShort(out, 0) -- side
		msg.writeShort(out, 0) -- up
		msg.writeByte(out, 0) -- buttons
		msg.writeByte(out, 0) -- impulse
	end)
	host.frame(svr, 0.05)
	gruntFrames[vmlib.edFloat(grunt, ent.frame)] = true
end

t.check(svr.time > 5.5, "time advanced")
t.check(vmlib.edFloat(player, ent.health) == 100, "player still alive")
t.check(bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_ONGROUND) ~= 0, "player on ground")
local n = 0
for _ in gruntFrames do
	n += 1
end
t.check(n >= 2, `grunt animates ({n} frames seen)`)

-- datagrams flowed to the client with svc_time + clientdata
t.check(#unreliable > 50, "unreliable datagrams sent")
local r = msg.reader(unreliable[#unreliable])
t.eq(msg.readByte(r), proto.svc_time, "datagram starts with svc_time")
local msgTime = msg.readFloat(r)
t.check(math.abs(msgTime - (svr.time - 0.05)) < 0.11, "svc_time plausible")

-- player movement: run forward for 2 seconds, should move north (angle 90)
local startOrg = vmlib.edVector(player, ent.origin)
for _ = 1, 40 do
	clientSend(function(out)
		msg.writeByte(out, proto.clc_move)
		msg.writeFloat(out, svr.time)
		msg.writeAngle(out, 0)
		msg.writeAngle(out, 90)
		msg.writeAngle(out, 0)
		msg.writeShort(out, 400) -- forward
		msg.writeShort(out, 0)
		msg.writeShort(out, 0)
		msg.writeByte(out, 0)
		msg.writeByte(out, 0)
	end)
	host.frame(svr, 0.05)
end
local endOrg = vmlib.edVector(player, ent.origin)
t.check(endOrg.y - startOrg.y > 100, `player ran forward ({startOrg} -> {endOrg})`)
t.check(vmlib.edFloat(player, ent.health) > 0, "player alive after running")

-- fire the shotgun (button0) — ammo should decrease
local shells0 = vmlib.edFloat(player, ent.ammo_shells)
for _ = 1, 4 do
	clientSend(function(out)
		msg.writeByte(out, proto.clc_move)
		msg.writeFloat(out, svr.time)
		msg.writeAngle(out, 0)
		msg.writeAngle(out, 90)
		msg.writeAngle(out, 0)
		msg.writeShort(out, 0)
		msg.writeShort(out, 0)
		msg.writeShort(out, 0)
		msg.writeByte(out, 1) -- +attack
		msg.writeByte(out, 0)
	end)
	host.frame(svr, 0.05)
end
local shells1 = vmlib.edFloat(player, ent.ammo_shells)
t.check(shells1 < shells0, `firing consumed shells ({shells0} -> {shells1})`)

--------------------------------------------------------------------------
-- NQ areanode battery (world.c link lists, the NQ twin of test_qwtrace):
-- SV_Move attribution on a linked door, unlink/relink toggling the clip
-- (RemoveLink/InsertLinkBefore), and PF_setmodel's brush bounds
local worldlib = require("../src/shared/engine/server/world")
local doorHit: vmlib.Edict? = nil
local dFrom, dTo = vector.zero, vector.zero
local dFraction = 1
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if e.free or vmlib.edString(vm, e, ent.classname) ~= "door" then
		continue
	end
	local dmin = vmlib.edVector(e, ent.absmin)
	local dmax = vmlib.edVector(e, ent.absmax)
	local dctr = (dmin + dmax) / 2
	local span = dmax - dmin
	local axis = if span.x < span.y then vector.create(1, 0, 0) else vector.create(0, 1, 0)
	local halfThin = (if span.x < span.y then span.x else span.y) / 2
	dFrom = dctr - axis * (halfThin + 48)
	dTo = dctr + axis * (halfThin + 48)
	local probe = worldlib.move(svr.world, dFrom, vector.zero, vector.zero, dTo, 0, vm.edicts[1])
	if probe.fraction < 1 and probe.ent == e then
		doorHit = e
		dFraction = probe.fraction
		break
	end
end
assert(doorHit, "found a door the NQ trace attributes cleanly")
t.check(vmlib.edFloat(doorHit, ent.modelindex) > 0 and vmlib.edVector(doorHit, ent.size).x > 0, "NQ PF_setmodel gave the door its brush model index and bounds")
worldlib.unlinkEdict(doorHit)
local tr2 = worldlib.move(svr.world, dFrom, vector.zero, vector.zero, dTo, 0, vm.edicts[1])
t.check(tr2.ent ~= doorHit, "unlinked door no longer clips (RemoveLink)")
worldlib.linkEdict(svr.world, doorHit, false)
local tr3 = worldlib.move(svr.world, dFrom, vector.zero, vector.zero, dTo, 0, vm.edicts[1])
t.check(tr3.ent == doorHit and math.abs(tr3.fraction - dFraction) < 1e-6, "relinked door clips identically (InsertLinkBefore)")

-- SV_CheckStuck: a client teleported into solid is restored to oldorigin
local sv_phys = require("../src/shared/engine/server/sv_phys")
local goodOrg = vmlib.edVector(player, ent.origin)
vmlib.edSetVector(player, ent.oldorigin, goodOrg)
local dmin2 = vmlib.edVector(doorHit, ent.absmin)
local dmax2 = vmlib.edVector(doorHit, ent.absmax)
vmlib.edSetVector(player, ent.origin, (dmin2 + dmax2) / 2)
sv_phys.checkStuck(svr, player)
t.check(vector.magnitude(vmlib.edVector(player, ent.origin) - goodOrg) < 1e-6, "SV_CheckStuck restored oldorigin from inside the door")

-- precache_*2 builtins are table aliases of the base ones, as C
t.check(
	vm.builtins[75] == vm.builtins[20] and vm.builtins[76] == vm.builtins[19] and vm.builtins[77] == vm.builtins[68],
	"precache_*2 builtins alias the base implementations"
)

--------------------------------------------------------------------------
-- SOLID_SLIDEBOX box-hull clip: trace down onto a live grunt with the
-- player as passedict (SV_InitBoxHull / SV_HullForBox path)
local grunt2: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "monster_army" and vmlib.edFloat(e, ent.health) > 0 then
		grunt2 = e
		break
	end
end
assert(grunt2, "live grunt present")
local gorg = vmlib.edVector(grunt2, ent.origin)
local gtr = worldlib.move(svr.world, gorg + vector.create(0, 0, 60), vector.zero, vector.zero, gorg, 0, player)
t.check(gtr.ent == grunt2, "point trace clips on the grunt's SOLID_SLIDEBOX box hull")

--------------------------------------------------------------------------
-- SV_Physics_Pusher / SV_PushMove: exec a door's use function and watch
-- the bmodel travel and return (the doortest snippet, checked in)
local moveDoor: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "door" and vmlib.edInt(e, ent.use) ~= 0 then
		moveDoor = e
		break
	end
end
assert(moveDoor, "door with a use function")
local doorStart = vmlib.edVector(moveDoor, ent.origin)
buffer.writef32(vm.globals, glob.time * 4, svr.time)
buffer.writei32(vm.globals, glob.self * 4, moveDoor.num)
buffer.writei32(vm.globals, glob.other * 4, player.num)
vmlib.exec(vm, vmlib.edInt(moveDoor, ent.use))
local maxTravel = 0
for _ = 1, 40 do
	host.frame(svr, 0.05)
	maxTravel = math.max(maxTravel, vector.magnitude(vmlib.edVector(moveDoor, ent.origin) - doorStart))
end
t.check(maxTravel > 30, `door traveled through SV_PushMove ({math.floor(maxTravel)} units)`)
for _ = 1, 140 do
	host.frame(svr, 0.05)
end
t.check(vector.magnitude(vmlib.edVector(moveDoor, ent.origin) - doorStart) < 1, "door returned home after its wait")

--------------------------------------------------------------------------
-- SV_Physics_Toss: a lobbed SOLID_BBOX edict arcs up, falls, and comes
-- to rest on the floor (SV_PushEntity + SV_CheckWaterTransition dry path)
local tossEd = vmlib.alloc(vm)
vmlib.edSetFloat(tossEd, ent.movetype, qd.MOVETYPE_TOSS)
vmlib.edSetFloat(tossEd, ent.solid, qd.SOLID_BBOX)
vmlib.edSetVector(tossEd, ent.mins, vector.zero)
vmlib.edSetVector(tossEd, ent.maxs, vector.zero)
local tossStart = vmlib.edVector(player, ent.origin) + vector.create(0, 0, 30)
vmlib.edSetVector(tossEd, ent.origin, tossStart)
vmlib.edSetVector(tossEd, ent.velocity, vector.create(0, 60, 160))
worldlib.linkEdict(svr.world, tossEd, false)
local apex = tossStart.z
for _ = 1, 80 do
	host.frame(svr, 0.05)
	apex = math.max(apex, vmlib.edVector(tossEd, ent.origin).z)
end
local tossEnd = vmlib.edVector(tossEd, ent.origin)
t.check(apex > tossStart.z + 10, `toss arced upward (apex +{math.floor(apex - tossStart.z)})`)
t.check(bit32.band(vmlib.edFloat(tossEd, ent.flags), qd.FL_ONGROUND) ~= 0 and vmlib.edVector(tossEd, ent.velocity) == vector.zero, "toss came to rest with FL_ONGROUND and zero velocity")

--------------------------------------------------------------------------
-- DropPunchAngle (sv_user.c): firing sets punchangle_x = -2 in QC and
-- the server decays it back to zero. God+notarget keep the grunts from
-- killing the player mid-battery (an earlier run died here).
if bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_GODMODE) == 0 then
	host.clientCommand(svr, client, "god")
end
if bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_NOTARGET) == 0 then
	host.clientCommand(svr, client, "notarget")
end
if vmlib.edFloat(player, ent.health) <= 0 then
	error("player died before the punchangle battery")
end
if vmlib.edFloat(player, ent.ammo_shells) < 1 then
	host.clientCommand(svr, client, "give s 20")
end
-- wait out attack_finished (W_WeaponFrame returns early until then,
-- swallowing impulses too)
local afdef = vm.progs.fielddefsByName["attack_finished"]
for _ = 1, 200 do
	if not afdef or vmlib.edFloat(player, afdef.ofs) <= svr.time then
		break
	end
	host.frame(svr, 0.05)
end
local function moveCmd(fwd: number, buttons: number, impulse: number?)
	clientSend(function(out)
		msg.writeByte(out, proto.clc_move)
		msg.writeFloat(out, svr.time)
		msg.writeAngle(out, 0)
		msg.writeAngle(out, 90)
		msg.writeAngle(out, 0)
		msg.writeShort(out, fwd)
		msg.writeShort(out, 0)
		msg.writeShort(out, 0)
		msg.writeByte(out, buttons)
		msg.writeByte(out, impulse or 0)
	end)
end
-- the earlier batteries may have drained shells and auto-switched to
-- the axe; impulse 2 re-selects the shotgun
moveCmd(0, 0, 2)
host.frame(svr, 0.05)
moveCmd(0, 1)
host.frame(svr, 0.05)
t.eq(vmlib.edVector(player, ent.punchangle).x, -2, "shotgun set punchangle_x = -2 (QC)")
for _ = 1, 10 do
	moveCmd(0, 0)
	host.frame(svr, 0.05)
end
t.eq(vmlib.edVector(player, ent.punchangle).x, 0, "DropPunchAngle decayed punchangle to zero")

-- SV_CleanupEnts: EF_MUZZLEFLASH cleared after the frame that set it
t.check(bit32.band(vmlib.edFloat(player, ent.effects), 2) == 0, "SV_CleanupEnts cleared EF_MUZZLEFLASH after the frame")

--------------------------------------------------------------------------
-- NQ SV_Physics_None / SV_Physics_Noclip (twins of the QW checks)
local noneEd = vmlib.alloc(vm)
vmlib.edSetFloat(noneEd, ent.movetype, qd.MOVETYPE_NONE)
vmlib.edSetVector(noneEd, ent.origin, vector.create(480, -352, 120))
vmlib.edSetVector(noneEd, ent.velocity, vector.create(0, 0, -100))
worldlib.linkEdict(svr.world, noneEd, false)
local clipEd = vmlib.alloc(vm)
vmlib.edSetFloat(clipEd, ent.movetype, qd.MOVETYPE_NOCLIP)
vmlib.edSetVector(clipEd, ent.origin, vector.create(480, -352, 100))
vmlib.edSetVector(clipEd, ent.velocity, vector.create(0, 0, 400))
worldlib.linkEdict(svr.world, clipEd, false)
for _ = 1, 20 do
	host.frame(svr, 0.05)
end
t.check(vmlib.edVector(noneEd, ent.origin).z == 120, "NQ MOVETYPE_NONE never moves (SV_Physics_None)")
t.check(vmlib.edVector(clipEd, ent.origin).z > 400, "NQ MOVETYPE_NOCLIP flies through the ceiling (SV_Physics_Noclip)")

--------------------------------------------------------------------------
-- Host_Say_Team_f / SV_SetIdealPitch / SV_DropClient
local relB = client.message.cursize
host.clientCommand(svr, client, "say_team roger")
t.check(client.message.cursize > relB and buffer.readu8(client.message.data, relB) == proto.svc_print, "say_team broadcasts svc_print (Host_Say_Team_f)")

-- walk the entrance ramp from a known start (the prior battery leaves
-- the player position arbitrary)
vmlib.edSetVector(player, ent.origin, vector.create(480, -300, 80))
vmlib.edSetVector(player, ent.oldorigin, vector.create(480, -300, 80))
vmlib.edSetVector(player, ent.velocity, vector.zero)
worldlib.linkEdict(svr.world, player, false)
local sawPitch = false
for _ = 1, 80 do
	moveCmd(200, 0)
	host.frame(svr, 0.05)
	if vmlib.edFloat(player, ent.idealpitch) ~= 0 then
		sawPitch = true
	end
end
t.check(sawPitch, "SV_SetIdealPitch drove ideal_pitch on the entrance ramp")

-- SV_Impact: a nailgun spike flies and its touch removes it on the wall
host.clientCommand(svr, client, "give 4")
host.clientCommand(svr, client, "give n 40")
local afd = vm.progs.fielddefsByName["attack_finished"]
for _ = 1, 200 do
	if not afd or vmlib.edFloat(player, afd.ofs) <= svr.time then
		break
	end
	host.frame(svr, 0.05)
end
moveCmd(0, 0, 4)
host.frame(svr, 0.05)
moveCmd(0, 1)
host.frame(svr, 0.05)
local spike: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "spike" then
		spike = e
	end
end
assert(spike, "nailgun spawned a spike")
local impacted = false
for _ = 1, 80 do
	host.frame(svr, 0.05)
	if (spike :: vmlib.Edict).free then
		impacted = true
		break
	end
end
t.check(impacted, "spike hit a wall and spike_touch removed it (SV_Impact)")

-- SV_SendNop: a connected-but-unspawned client idle >5s gets a
-- keepalive svc_nop on its channel
local nopGot: buffer? = nil
local c2 = svr.clients[2]
c2.sendUnreliable = function(d: buffer)
	nopGot = d
	return true
end
c2.sendReliable = function()
	return true
end
host.connectClient(svr, 2)
host.frame(svr, 0.05) -- signon burst goes out (sendsignon clears)
nopGot = nil
c2.last_message = svr.realtime - 6
host.frame(svr, 0.05)
t.check(nopGot ~= nil and buffer.len(nopGot :: buffer) == 1 and buffer.readi8(nopGot :: buffer, 0) == proto.svc_nop, "idle pre-spawn client received a 1-byte svc_nop keepalive")
svlib.dropClient(svr, c2, false)

-- RadiusFromBounds: model radius = |per-axis max(|mins|,|maxs|)| as C
local wmodel = svr.worldmodel
local corner = vector.create(
	math.max(math.abs(wmodel.mins.x), math.abs(wmodel.maxs.x)),
	math.max(math.abs(wmodel.mins.y), math.abs(wmodel.maxs.y)),
	math.max(math.abs(wmodel.mins.z), math.abs(wmodel.maxs.z))
)
t.check(math.abs(wmodel.radius - vector.magnitude(corner)) < 0.01, "RadiusFromBounds matches the C corner formula")

svlib.dropClient(svr, client, false)
t.check(not client.active, "SV_DropClient deactivated the client")

t.finish("test_server")
