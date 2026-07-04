--!strict
-- NQ monster chase family (sv_move.c) vs ground truth from the verbatim
-- C (tools/svmove_truth.c): SV_MoveToGoal / SV_StepDirection /
-- SV_NewChaseDir / SV_CloseEnough / SV_movestep / SV_CheckBottom /
-- PF_changeyaw, including the rand()-gated chase decisions — both sides
-- run the SAME msvcrt LCG from seed 12345, so every random branch
-- matches. The harness traces the world only, so every other solid
-- entity is unlinked before the run.
local t = require("./testutil")
local fs = require("@lune/fs")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local sv_move = require("../src/shared/engine/server/sv_move")
local worldlib = require("../src/shared/engine/server/world")
local qd = require("../src/shared/engine/quakedef")

local ent = defs.ent
local glob = defs.glob

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

-- world-only tracing: unlink every solid entity (the truth harness has
-- no entities at all)
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edFloat(e, ent.solid) ~= 0 then
		worldlib.unlinkEdict(e)
	end
end

-- the scenario twins: grunt-size walker at (480,100,24) chasing a goal
-- at (480,480,24), yaw_speed 20, dist 8, 200 MoveToGoal calls
local monster = vmlib.alloc(vm)
vmlib.edSetVector(monster, ent.origin, vector.create(480, 100, 24))
vmlib.edSetVector(monster, ent.mins, vector.create(-16, -16, -24))
vmlib.edSetVector(monster, ent.maxs, vector.create(16, 16, 24))
vmlib.edSetFloat(monster, ent.flags, qd.FL_ONGROUND)
vmlib.edSetFloat(monster, ent.yaw_speed, 20)
vmlib.edSetFloat(monster, ent.ideal_yaw, 0)
vmlib.edSetVector(monster, ent.angles, vector.zero)
local goal = vmlib.alloc(vm)
vmlib.edSetVector(goal, ent.origin, vector.create(480, 480, 24))
vmlib.edSetVector(goal, ent.mins, vector.zero)
vmlib.edSetVector(goal, ent.maxs, vector.zero)
vmlib.edSetInt(monster, ent.enemy, goal.num)
vmlib.edSetInt(monster, ent.goalentity, goal.num)
worldlib.linkEdict(svr.world, monster, false)
worldlib.linkEdict(svr.world, goal, false)
worldlib.unlinkEdict(monster) -- keep traces world-only; abs boxes are set
worldlib.unlinkEdict(goal)

local truth = {}
for line in fs.readFile("tests/fixtures/svmove_truth.txt"):gmatch("[^\n]+") do
	local n = {}
	for w in line:gmatch("%S+") do
		table.insert(n, tonumber(w))
	end
	truth[n[1]] = n
end

svr.randSeed = 12345
local maxErr, maxYawErr = 0, 0
for i = 1, 200 do
	buffer.writei32(vm.globals, glob.self * 4, monster.num)
	vmlib.setGlobalFloat(vm, defs.OFS_PARM0, 8)
	sv_move.moveToGoal(svr)
	local tr = truth[i]
	local org = vmlib.edVector(monster, ent.origin)
	local err = vector.magnitude(org - vector.create(tr[2], tr[3], tr[4]))
	maxErr = math.max(maxErr, err)
	local yawDelta = math.abs(((vmlib.edVector(monster, ent.angles).y - tr[5]) + 180) % 360 - 180)
	maxYawErr = math.max(maxYawErr, yawDelta)
end

print(("chase course: max position error %.6f, max yaw error %.6f over 200 MoveToGoal calls"):format(maxErr, maxYawErr))
t.check(maxErr < 0.01, "chase positions match the verbatim C within 0.01 units")
t.check(maxYawErr < 0.01, "yaw/changeyaw matches the verbatim C")
local final = vmlib.edVector(monster, ent.origin)
t.check(vector.magnitude(final - vector.create(480, 100, 24)) > 300, `the monster really chased ({string.format("%.0f", vector.magnitude(final - vector.create(480, 100, 24)))} units)`)
t.finish("test_svmove")
