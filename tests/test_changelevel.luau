--!strict
-- Level progression: touch e1m1's trigger_changelevel, let the QuakeC
-- intermission sequence run, then respawn the server on the next map and
-- reconnect the client — the full episode flow.

local t = require("./testutil")
local cllib = require("../src/shared/engine/client/cl")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local msg = require("../src/shared/engine/common/msg")

local ent = defs.ent
local glob = defs.glob

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end

host.spawnServer(svr, "e1m1")
local vm = svr.vm

local c = cllib.new("Ranger", 0)
c.print = function(_s: string) end
local intermissionSeen = false
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

-- find the changelevel trigger and fire its touch as the player
local trig: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "trigger_changelevel" then
		trig = e
		break
	end
end
assert(trig, "found trigger_changelevel")
local touchFn = vmlib.edInt(trig, ent.touch)
t.check(touchFn ~= 0, "trigger has touch fn")

buffer.writef32(vm.globals, glob.time * 4, svr.time)
buffer.writei32(vm.globals, glob.self * 4, trig.num)
buffer.writei32(vm.globals, glob.other * 4, 1)
vmlib.exec(vm, touchFn)

-- the QC runs an intermission; after intermission_exittime the player must
-- press a button to exit (IntermissionThink)
for _ = 1, 50 do
	pump()
end
t.check(intermissionSeen, "intermission running before exit")
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
t.check(intermissionSeen, "client saw intermission")

-- give the player a nailgun + damage before leaving, so the carry-over
-- through SetChangeParms/DecodeLevelParms is observable
local player = svr.clients[1].edict
vmlib.edSetFloat(player, ent.items, bit32.bor(vmlib.edFloat(player, ent.items) // 1, 4)) -- IT_NAILGUN
vmlib.edSetFloat(player, ent.ammo_nails, 137)
vmlib.edSetFloat(player, ent.health, 61)

-- platform layer: SV_SaveSpawnparms, respawn on the next level, and
-- reconnect preserving the saved parms (C keeps the connection alive
-- and never re-runs SetNewParms on a changelevel)
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
t.eq(c.levelname, "Castle of the Damned", "e1m2 level name")
t.eq(c.model_precache[2], "maps/e1m2.bsp", "world is e1m2")

-- SV_SaveSpawnparms carry-over (parm rules live in QC DecodeLevelParms:
-- items keep the nailgun, ammo carries, health carries clamped 50..100)
player = svr.clients[1].edict
t.check(bit32.band(vmlib.edFloat(player, ent.items) // 1, 4) ~= 0, "nailgun carried to e1m2")
t.eq(vmlib.edFloat(player, ent.ammo_nails), 137, "nail count carried")
t.eq(vmlib.edFloat(player, ent.health), 61, "health carried (61)")

t.finish("test_changelevel")
