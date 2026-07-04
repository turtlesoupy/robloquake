--!strict
-- Player movement vs compiled C ground truth. tools/move_truth.c runs the
-- verbatim WinQuake movement chain (SV_ClientThink → SV_AirMove/WaterMove →
-- gravity → SV_CheckStuck → SV_WalkMove) over e1m1 with a scripted input
-- sequence; this runs the port through the identical sequence and compares
-- origin/velocity/onground per tick.
--
-- Regenerate the fixture with:
--   cc -O2 -o /tmp/move_truth tools/move_truth.c -lm && /tmp/move_truth > tests/fixtures/move_truth.txt

local fs = require("@lune/fs")

local t = require("./testutil")
local vfslib = require("../src/shared/engine/common/vfs")
local bsplib = require("../src/shared/engine/bsp/bsp")
local defs = require("../src/shared/engine/progs/defs")
local progslib = require("../src/shared/engine/progs/progs")
local vmlib = require("../src/shared/engine/progs/vm")
local qd = require("../src/shared/engine/quakedef")
local svlib = require("../src/shared/engine/server/sv")
local sv_phys = require("../src/shared/engine/server/sv_phys")
local sv_user = require("../src/shared/engine/server/sv_user")
local world = require("../src/shared/engine/server/world")

local ent = defs.ent

-- minimal world-only server (no QuakeC executes; matches the C harness)
local fsys = t.gameFs()
local progsbuf = vfslib.loadFile(fsys, "progs.dat") :: buffer
local pr = progslib.load(progsbuf)

local svr = svlib.new(fsys, 1)
svr.print = function(_s: string) end
svr.progs = pr
local vm = vmlib.new(pr, 8, 1)
svr.vm = vm
vmlib.initEdicts(vm, 2)

local mapbuf = vfslib.loadFile(fsys, "maps/e1m1.bsp") :: buffer
local models = bsplib.load("maps/e1m1.bsp", mapbuf)
svr.worldmodel = models[1]
svr.brushModels = { [1] = models[1] }
svr.world = world.new(vm, models[1], svr.brushModels)
svr.time = 1.0
svr.frametime = 0.05
vm.time = 1.0

-- world edict: SOLID_BSP so world.move clips against hull 1
local worldEd = vmlib.edictNum(vm, 0)
vmlib.edSetFloat(worldEd, ent.solid, qd.SOLID_BSP)
vmlib.edSetFloat(worldEd, ent.movetype, qd.MOVETYPE_PUSH)
vmlib.edSetFloat(worldEd, ent.modelindex, 1)

-- player edict, mirroring the harness setup exactly
local player = vmlib.edictNum(vm, 1)
vmlib.edSetVector(player, ent.origin, vector.create(480, -352, 88))
vmlib.edSetVector(player, ent.oldorigin, vector.create(480, -352, 88))
vmlib.edSetVector(player, ent.mins, vector.create(-16, -16, -24))
vmlib.edSetVector(player, ent.maxs, vector.create(16, 16, 32))
vmlib.edSetVector(player, ent.view_ofs, vector.create(0, 0, 22))
vmlib.edSetFloat(player, ent.movetype, qd.MOVETYPE_WALK)
vmlib.edSetFloat(player, ent.solid, qd.SOLID_BSP)
vmlib.edSetFloat(player, ent.health, 100)
world.linkEdict(svr.world, player, false)

local client = svlib.newClient(1)
client.active = true
client.edict = player

-- the same input script as tools/move_truth.c
type Phase = { untilTick: number, fwd: number, side: number, upm: number, yaw: number, pitch: number, jump: boolean }
local script: { Phase } = {
	{ untilTick = 40, fwd = 400, side = 0, upm = 0, yaw = 90, pitch = 0, jump = false },
	{ untilTick = 80, fwd = 400, side = 0, upm = 0, yaw = 135, pitch = 0, jump = false },
	{ untilTick = 120, fwd = 200, side = 350, upm = 0, yaw = 90, pitch = 0, jump = false },
	{ untilTick = 160, fwd = 400, side = 0, upm = 0, yaw = 90, pitch = 0, jump = true },
	{ untilTick = 200, fwd = -200, side = 0, upm = 0, yaw = 90, pitch = 0, jump = false },
	{ untilTick = 240, fwd = 400, side = -350, upm = 0, yaw = 45, pitch = 0, jump = true },
	{ untilTick = 300, fwd = 400, side = 0, upm = 0, yaw = 180, pitch = 10, jump = false },
}

-- ground truth
local fixture = fs.readFile("tests/fixtures/move_truth.txt")
local truth: { { number } } = {}
for line in fixture:gmatch("[^\n]+") do
	local vals = {}
	for w in line:gmatch("[^ ]+") do
		table.insert(vals, tonumber(w) :: number)
	end
	table.insert(truth, vals)
end
t.eq(#truth, 380, "fixture ticks (300 dry + 80 water)")

local maxPosErr, maxVelErr = 0, 0
local firstBigTick = -1
local tick = 0
for _, ph in script do
	while tick < ph.untilTick do
		client.cmd.forwardmove = ph.fwd
		client.cmd.sidemove = ph.side
		client.cmd.upmove = ph.upm
		vmlib.edSetVector(player, ent.v_angle, vector.create(ph.pitch, ph.yaw, 0))

		-- jump emulation (PlayerJump essentials), identical to the harness
		local flags = vmlib.edFloat(player, ent.flags)
		if ph.jump and bit32.band(flags, qd.FL_ONGROUND) ~= 0 then
			vmlib.edSetFloat(player, ent.flags, bit32.band(flags, bit32.bnot(qd.FL_ONGROUND)))
			local vel = vmlib.edVector(player, ent.velocity)
			vmlib.edSetVector(player, ent.velocity, vector.create(vel.x, vel.y, vel.z + 270))
		end

		sv_user.clientThink(svr, client)

		-- SV_Physics_Client MOVETYPE_WALK path (no QC thinks)
		sv_phys.checkVelocity(svr, player)
		if not sv_phys.checkWater(svr, player) and bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_WATERJUMP) == 0 then
			sv_phys.addGravity(svr, player)
		end
		sv_phys.checkStuck(svr, player)
		sv_phys.walkMove(svr, player)
		world.linkEdict(svr.world, player, false)

		svr.time += svr.frametime
		vm.time = svr.time

		-- compare with the C row for this tick
		local row = truth[tick + 1]
		local org = vmlib.edVector(player, ent.origin)
		local vel = vmlib.edVector(player, ent.velocity)
		local posErr = math.max(math.abs(org.x - row[2]), math.abs(org.y - row[3]), math.abs(org.z - row[4]))
		local velErr = math.max(math.abs(vel.x - row[5]), math.abs(vel.y - row[6]), math.abs(vel.z - row[7]))
		maxPosErr = math.max(maxPosErr, posErr)
		maxVelErr = math.max(maxVelErr, velErr)
		if posErr > 1 and firstBigTick < 0 then
			firstBigTick = tick
			print(("tick %d diverged: port=(%.3f,%.3f,%.3f) C=(%.3f,%.3f,%.3f)"):format(
				tick, org.x, org.y, org.z, row[2], row[3], row[4]))
		end

		tick += 1
	end
end

print(("course 1 (dry): max position error %.6f, max velocity error %.6f"):format(maxPosErr, maxVelErr))
t.check(maxPosErr < 0.01, "dry-course position matches the verbatim C within 0.01 units")
t.check(maxVelErr < 0.05, "dry-course velocity matches within 0.05")

--------------------------------------------------------------------------
-- course 2: the e1m1 slime pool — SV_WaterMove swim accel/friction,
-- waterlevel transitions, and a deterministic waterjump (the QC-side
-- CheckWaterJump trigger is emulated identically on both sides at tick
-- 39: FL_WATERJUMP + movedir + velocity 225 + teleport_time).
-- Mirrored in tools/move_truth.c ticks 300-379.
local waterScript: { Phase } = {
	{ untilTick = 20, fwd = 400, side = 0, upm = 0, yaw = 90, pitch = 30, jump = false },
	{ untilTick = 35, fwd = 400, side = 0, upm = 200, yaw = 270, pitch = -45, jump = false },
	{ untilTick = 60, fwd = 400, side = 0, upm = 0, yaw = 0, pitch = -10, jump = false },
	{ untilTick = 80, fwd = 0, side = 0, upm = -200, yaw = 180, pitch = 0, jump = false },
}
-- reset the player exactly like the harness memset + re-setup
for _, fld in { ent.velocity, ent.punchangle, ent.v_angle } do
	vmlib.edSetVector(player, fld, vector.zero)
end
vmlib.edSetVector(player, ent.origin, vector.create(656, 992, -330))
vmlib.edSetVector(player, ent.oldorigin, vector.create(656, 992, -330))
vmlib.edSetFloat(player, ent.flags, 0)
vmlib.edSetFloat(player, ent.waterlevel, 0)
vmlib.edSetFloat(player, ent.watertype, 0)
vmlib.edSetFloat(player, ent.teleport_time, 0)
vmlib.edSetVector(player, ent.movedir, vector.zero)
world.linkEdict(svr.world, player, false)
svr.time = 1.0
vm.time = 1.0

local wMaxPos, wMaxVel, wMismatch = 0, 0, 0
local seenLevels: { [number]: boolean } = {}
tick = 0
for _, ph in waterScript do
	while tick < ph.untilTick do
		client.cmd.forwardmove = ph.fwd
		client.cmd.sidemove = ph.side
		client.cmd.upmove = ph.upm
		vmlib.edSetVector(player, ent.v_angle, vector.create(ph.pitch, ph.yaw, 0))

		if tick == 39 then
			vmlib.edSetFloat(player, ent.flags, bit32.bor(vmlib.edFloat(player, ent.flags) // 1, qd.FL_WATERJUMP))
			vmlib.edSetVector(player, ent.movedir, vector.create(0, 100, 0))
			local vel = vmlib.edVector(player, ent.velocity)
			vmlib.edSetVector(player, ent.velocity, vector.create(vel.x, vel.y, 225))
			vmlib.edSetFloat(player, ent.teleport_time, svr.time + 2)
		end

		sv_user.clientThink(svr, client)
		sv_phys.checkVelocity(svr, player)
		if not sv_phys.checkWater(svr, player) and bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_WATERJUMP) == 0 then
			sv_phys.addGravity(svr, player)
		end
		sv_phys.checkStuck(svr, player)
		sv_phys.walkMove(svr, player)
		world.linkEdict(svr.world, player, false)

		svr.time += svr.frametime
		vm.time = svr.time

		local row = truth[300 + tick + 1]
		local org = vmlib.edVector(player, ent.origin)
		local vel = vmlib.edVector(player, ent.velocity)
		wMaxPos = math.max(wMaxPos, math.max(math.abs(org.x - row[2]), math.abs(org.y - row[3]), math.abs(org.z - row[4])))
		wMaxVel = math.max(wMaxVel, math.max(math.abs(vel.x - row[5]), math.abs(vel.y - row[6]), math.abs(vel.z - row[7])))
		if vmlib.edFloat(player, ent.waterlevel) ~= row[8] then
			wMismatch += 1
		end
		seenLevels[row[8]] = true
		tick += 1
	end
end
print(("course 2 (water): max position error %.6f, max velocity error %.6f"):format(wMaxPos, wMaxVel))
t.check(wMaxPos < 0.01, "water-course position matches the verbatim C within 0.01 units")
t.check(wMaxVel < 0.05, "water-course velocity matches within 0.05")
t.eq(wMismatch, 0, "waterlevel agrees every tick")
t.check(seenLevels[3] == true and seenLevels[0] == true, "the course crosses waterlevels 3 down to 0 (the waterjump exits the pool)")
t.finish("test_movement")
