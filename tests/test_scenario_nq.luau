--!strict
-- SCENARIO: NetQuake campaign loop through the loopback wire client.
-- Spawn on e1m1, pick up shells by really touching them (gravity drop
-- onto the item, SV_TouchLinks fires), take real monster damage
-- (a grunt shoots the player), carry inventory through the changelevel
-- intermission to e1m2, then save/load round-trip and keep playing.
-- Interaction coverage the per-function grid cannot express.
local t = require("./testutil")
local cllib = require("../src/shared/engine/client/cl")
local mathlib = require("../src/shared/engine/common/mathlib")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local savegame = require("../src/shared/engine/server/savegame")
local worldlib = require("../src/shared/engine/server/world")

local ent = defs.ent
local glob = defs.glob

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end

host.spawnServer(svr, "e1m1")
local vm = svr.vm

local c = cllib.new("Ranger", 0)
local prints: { string } = {}
c.print = function(s: string)
	table.insert(prints, s)
end
local sc = svr.clients[1]
sc.sendUnreliable = function(d: buffer)
	cllib.parseServerMessage(c, d)
	return true
end
sc.sendReliable = function(d: buffer)
	cllib.parseServerMessage(c, d)
	return true
end
host.connectClient(svr, 1)

local intermissionSeen = false
local function pump()
	local rel = cllib.takeReliable(c)
	if rel then
		table.insert(sc.inbox, rel)
	end
	host.frame(svr, 0.05)
	if c.intermission > 0 then
		intermissionSeen = true
	end
end

for _ = 1, 8 do
	pump()
end
t.eq(c.signon, cllib.SIGNONS, "signed on to e1m1")
t.eq(c.stats[cllib.STAT_HEALTH], 100, "spawned at 100 health (client stat)")
t.eq(c.stats[cllib.STAT_SHELLS], 25, "spawned with 25 shells (client stat)")

local player = svr.clients[1].edict

-- helper: teleport the player to a free spot near a target and relink
-- (staging only — the actual pickup/damage below happens through real
-- physics and QC). SV_CheckStuck rejects solid spots by restoring
-- oldorigin, so probe with the same world.testEntityPosition it uses.
local function stage(center: vector): boolean
	local prev = vmlib.edVector(player, ent.origin)
	for _, dz in { 1, 9, 17, 25, 33, 41 } do
		for _, dxy in { vector.zero, vector.create(-24, 0, 0), vector.create(24, 0, 0), vector.create(0, -24, 0), vector.create(0, 24, 0), vector.create(-48, 0, 0), vector.create(48, 0, 0), vector.create(0, -48, 0), vector.create(0, 48, 0) } do
			local cand = center + dxy + vector.create(0, 0, dz)
			vmlib.edSetVector(player, ent.origin, cand)
			if not worldlib.testEntityPosition(svr.world, player) then
				vmlib.edSetVector(player, ent.oldorigin, cand)
				vmlib.edSetVector(player, ent.velocity, vector.zero)
				worldlib.linkEdict(svr.world, player, false)
				return true
			end
		end
	end
	vmlib.edSetVector(player, ent.origin, prev)
	return false
end

-- helper: walk toward a point by sending real clc_move packets
local function walkToward(target: vector, ticks: number, stop: () -> boolean): boolean
	for _ = 1, ticks do
		local org = vmlib.edVector(player, ent.origin)
		local d = target - org
		local yaw = math.deg(math.atan2(d.y, d.x))
		c.viewangles = vector.create(0, yaw, 0)
		local move = cllib.buildMove(c, 200, 0, 0, false, false, 0)
		if move then
			table.insert(sc.inbox, move)
		end
		pump()
		if stop() then
			return true
		end
	end
	return stop()
end

-- REAL PICKUP: find the shells box near the start ledge and drop the
-- player onto it; item touch must fire through SV_TouchLinks
local shellsItem: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "item_shells" then
		local o = vmlib.edVector(e, ent.origin)
		if vector.magnitude(o - vector.create(672, -40, 48)) < 64 then
			shellsItem = e
			break
		end
	end
end
assert(shellsItem, "found the start-ledge item_shells")
local itemOrg = vmlib.edVector(shellsItem, ent.origin)
t.check(stage(itemOrg), "staged near the shells box")
local shellsPicked = walkToward(itemOrg, 60, function()
	return vmlib.edFloat(player, ent.ammo_shells) > 25
end)
t.check(shellsPicked, "walking over the shells box picked it up through touch")
t.eq(vmlib.edFloat(player, ent.ammo_shells), 45, "shells 25 -> 45 (box of 20)")
for _ = 1, 3 do
	pump()
end
t.eq(c.stats[cllib.STAT_SHELLS], 45, "shells stat reached the client")
-- QC prints arrive in pieces ("You got the " / "shells" / "\n")
t.check(table.concat(prints):find("You got the shells") ~= nil, "pickup print reached the client")

-- REAL DAMAGE: stand in front of a live grunt and let it shoot;
-- svc_damage must reach the client. Monsters are skill-filtered, so
-- pick from whoever actually spawned and try a few.
local grunts: { vmlib.Edict } = {}
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "monster_army" and vmlib.edFloat(e, ent.health) > 0 then
		table.insert(grunts, e)
	end
end
t.check(#grunts > 5, `grunts spawned ({#grunts})`)
local hurtTicks = 0
for _, grunt in grunts do
	local gorg = vmlib.edVector(grunt, ent.origin)
	local gyaw = vmlib.edVector(grunt, ent.angles).y
	local front = gorg + mathlib.angleVectors(vector.create(0, gyaw, 0)) * 100 + vector.create(0, 0, 8)
	if not stage(front) then
		continue
	end
	for _ = 1, 150 do
		pump()
		hurtTicks += 1
		if vmlib.edFloat(player, ent.health) < 100 then
			break
		end
	end
	if vmlib.edFloat(player, ent.health) < 100 then
		break
	end
end
local hurtHealth = vmlib.edFloat(player, ent.health)
t.check(hurtHealth < 100, `a grunt shot the player ({hurtHealth} hp after {hurtTicks} ticks)`)
t.check(hurtHealth >= 50, "still above the changelevel carry clamp")
for _ = 1, 3 do
	pump()
end
t.eq(c.stats[cllib.STAT_HEALTH], hurtHealth, "damaged health reached the client stat")
t.check(c.cshift_damage_percent > 0, "svc_damage drove the pain flash")

-- CHANGELEVEL: fire the exit trigger as the player, ride the
-- intermission, press attack to exit
local trig: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "trigger_changelevel" then
		trig = e
		break
	end
end
assert(trig, "found trigger_changelevel")
local healthAtExit = vmlib.edFloat(player, ent.health)
local shellsAtExit = vmlib.edFloat(player, ent.ammo_shells)
buffer.writef32(vm.globals, glob.time * 4, svr.time)
buffer.writei32(vm.globals, glob.self * 4, trig.num)
buffer.writei32(vm.globals, glob.other * 4, 1)
vmlib.exec(vm, vmlib.edInt(trig, ent.touch))

for _ = 1, 50 do
	pump()
end
t.check(intermissionSeen, "intermission running")
for _ = 1, 60 do
	local move = cllib.buildMove(c, 0, 0, 0, true, false, 0) -- +attack
	if move then
		table.insert(sc.inbox, move)
	end
	pump()
	if svr.changelevelTo then
		break
	end
end
t.eq(svr.changelevelTo, "e1m2", "changelevel to e1m2 issued")

local nextMap = svr.changelevelTo :: string
svr.changelevelTo = nil
host.saveSpawnparms(svr)
host.spawnServer(svr, nextMap)
t.check(svr.active, "e1m2 spawned")
host.connectClient(svr, 1, true)
for _ = 1, 10 do
	pump()
end
t.eq(c.signon, cllib.SIGNONS, "signed on to e1m2")
t.eq(c.model_precache[2], "maps/e1m2.bsp", "world is e1m2")

-- inventory earned through play carried via SetChangeParms/DecodeLevelParms
player = svr.clients[1].edict
t.eq(vmlib.edFloat(player, ent.ammo_shells), shellsAtExit, `shells carried ({shellsAtExit})`)
t.eq(vmlib.edFloat(player, ent.health), healthAtExit, `damaged health carried ({healthAtExit})`)
for _ = 1, 3 do
	pump()
end
t.eq(c.stats[cllib.STAT_SHELLS], shellsAtExit, "carried shells visible on the client")

-- SAVE/LOAD round-trip on e1m2
for _ = 1, 20 do
	pump()
end
local savedHealth = vmlib.edFloat(player, ent.health)
local savedShells = vmlib.edFloat(player, ent.ammo_shells)
local savedOrigin = vmlib.edVector(player, ent.origin)
local savedTime = svr.time
local sav = savegame.write(svr)
t.check(#sav > 10000, "savegame written")

-- wreck the state, then load must undo it
vmlib.edSetFloat(player, ent.health, 13)
for _ = 1, 40 do
	pump()
end
local ok = savegame.load(svr, sav, function(mapname: string)
	host.spawnServer(svr, mapname)
end)
t.check(ok, "load succeeded")
t.check(math.abs(svr.time - savedTime) < 0.001, "server time restored")
svr.paused = false
host.connectClient(svr, 1)
for _ = 1, 10 do
	pump()
end
t.eq(c.signon, cllib.SIGNONS, "client re-signed on after load")
player = svr.clients[1].edict
t.eq(vmlib.edFloat(player, ent.health), savedHealth, "health restored")
t.eq(vmlib.edFloat(player, ent.ammo_shells), savedShells, "shells restored")
t.check(vector.magnitude(vmlib.edVector(player, ent.origin) - savedOrigin) < 1, "origin restored")
t.eq(c.stats[cllib.STAT_HEALTH], savedHealth, "restored health reached the client stat")

-- the loaded game still runs
for _ = 1, 40 do
	pump()
end
t.check(vmlib.edFloat(player, ent.health) > 0, "player alive after resume")

t.finish("test_scenario_nq")
