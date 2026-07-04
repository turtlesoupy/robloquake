--!strict
-- save/load round-trip: play, save, wreck the state, load, verify restore
local t = require("./testutil")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local savegame = require("../src/shared/engine/server/savegame")
local msg = require("../src/shared/engine/common/msg")
local proto = require("../src/shared/engine/protocol")

local ent = defs.ent

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(s: string)
	print("[sv] " .. s)
end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

-- connect a fake client and spawn in
local clientnum = host.findFreeClient(svr) :: number
local client = svr.clients[clientnum]
client.sendUnreliable = function()
	return true
end
client.sendReliable = function()
	return true
end
host.connectClient(svr, clientnum)
local function sendCmd(s: string)
	local out = msg.newBuf(1024)
	msg.writeByte(out, proto.clc_stringcmd)
	msg.writeString(out, s)
	table.insert(client.inbox, msg.snapshot(out))
end
sendCmd("prespawn")
host.frame(svr, 0.05)
sendCmd("spawn")
host.frame(svr, 0.05)
sendCmd("begin")
host.frame(svr, 0.05)
t.check(client.spawned, "client spawned")

-- run a couple seconds, grab a rocket launcher, note state
for _ = 1, 40 do
	host.frame(svr, 0.05)
end
host.clientCommand(svr, client, "give 7")
host.clientCommand(svr, client, "give r 55")
local player = client.edict
local savedHealth = vmlib.edFloat(player, ent.health)
local savedOrigin = vmlib.edVector(player, ent.origin)
local savedItems = vmlib.edFloat(player, ent.items)
local savedRockets = vmlib.edFloat(player, ent.ammo_rockets)
local savedTime = svr.time
local savedEdicts = vm.num_edicts

local sav = savegame.write(svr)
t.check(#sav > 10000, "savegame has content")
t.check(sav:sub(1, 2) == "5\n", "savegame version 5")

-- wreck the state: hurt the player, advance time
vmlib.edSetFloat(player, ent.health, 13)
for _ = 1, 60 do
	host.frame(svr, 0.05)
end

-- load
local ok = savegame.load(svr, sav, function(mapname: string)
	host.spawnServer(svr, mapname)
end)
t.check(ok, "load succeeded")
t.check(svr.paused, "loadgame pauses until clients connect")
svr.paused = false

-- reconnect the client (loadgame keeps edict state; client re-enters)
host.connectClient(svr, clientnum)
local p2 = svr.clients[clientnum].edict
t.eq(vmlib.edFloat(p2, ent.health), savedHealth, "health restored")
t.check(vmlib.edFloat(p2, ent.items) == savedItems, "items restored (rocket launcher)")
t.eq(vmlib.edFloat(p2, ent.ammo_rockets), savedRockets, "rockets restored")
local o2 = vmlib.edVector(p2, ent.origin)
t.check(vector.magnitude(o2 - savedOrigin) < 1, "origin restored")
t.check(math.abs(svr.time - savedTime) < 0.001, "time restored")
t.eq(vm.num_edicts, savedEdicts, "edict count restored")
t.check(vmlib.edString(vm, vm.edicts[1], ent.message) ~= "", "world message intact")

-- the loaded game still runs
for _ = 1, 40 do
	host.frame(svr, 0.05)
end
t.check(vmlib.edFloat(p2, ent.health) == savedHealth, "player alive after resume")

t.finish("test_savegame")
