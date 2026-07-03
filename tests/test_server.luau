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

t.finish("test_server")
