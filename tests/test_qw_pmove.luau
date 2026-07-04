--!strict
-- QW pmove vs ground truth from the verbatim C (tools/pmove_truth.c)
local t = require("./testutil")
local vfslib = require("../src/shared/engine/common/vfs")
local bsplib = require("../src/shared/engine/bsp/bsp")
local pmovelib = require("../src/shared/engine/qw/pmove")

local fs = require("@lune/fs")

local paklib = require("../src/shared/engine/common/pak")

local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/e1m1.bsp")
assert(buf)
local world = bsplib.load("maps/e1m1.bsp", buf)[1]

-- dm3 (pak1) hosts the stair-climb course; id1 content stays local-only
vfslib.addPack(
	fsys,
	paklib.load("id1/pak1.pak", buffer.fromstring(fs.readFile("external_assets/quake106/extracted/id1/pak1.pak")))
)
local dm3buf = vfslib.loadFile(fsys, "maps/dm3.bsp")
assert(dm3buf)
local stairworld = bsplib.load("maps/dm3.bsp", dm3buf)[1]

local movevars = pmovelib.defaultMoveVars()

local pm: pmovelib.PlayerMove = {
	origin = vector.create(480, -352, 88),
	angles = vector.zero,
	velocity = vector.zero,
	oldbuttons = 0,
	waterjumptime = 0,
	dead = false,
	spectator = false,
	physents = { { model = world, origin = vector.zero } },
	cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, msec = 50 },
	numtouch = 0,
	touchindex = {},
	onground = -1,
	waterlevel = 0,
	watertype = -1,
}

-- mirrored exactly in tools/pmove_truth.c
local script = {
	{ 40, 400, 0, 0, 90, 0, false },
	{ 80, 400, 0, 0, 135, 0, false },
	{ 120, 200, 350, 0, 90, 0, false },
	{ 160, 400, 0, 0, 90, 0, true },
	{ 200, -200, 0, 0, 90, 0, false },
	{ 240, 400, -350, 0, 45, 0, true },
	{ 300, 400, 0, 0, 180, 10, false },
}

local truth = {}
for line in fs.readFile("tests/fixtures/pmove_truth.txt"):gmatch("[^\n]+") do
	local n = {}
	for w in line:gmatch("%S+") do
		table.insert(n, tonumber(w))
	end
	truth[n[1]] = n
end

local maxPosErr, maxVelErr = 0, 0
local groundMismatch = 0
local function runCourse(coursePm: pmovelib.PlayerMove, courseScript: { { any } }, ticks: number, base: number)
	for tick = 1, ticks do
		local ph = courseScript[#courseScript]
		for _, s in courseScript do
			if tick <= s[1] then
				ph = s
				break
			end
		end
		coursePm.cmd = {
			angles = vector.create(ph[6], ph[5], 0),
			forwardmove = ph[2],
			sidemove = ph[3],
			upmove = ph[4],
			buttons = if ph[7] then 2 else 0,
			msec = 50,
		}
		pmovelib.playerMove(coursePm, movevars)

		local tr = truth[base + tick]
		local posErr = vector.magnitude(coursePm.origin - vector.create(tr[2], tr[3], tr[4]))
		local velErr = vector.magnitude(coursePm.velocity - vector.create(tr[5], tr[6], tr[7]))
		maxPosErr = math.max(maxPosErr, posErr)
		maxVelErr = math.max(maxVelErr, velErr)
		local cGround = tr[8] == 1
		if (coursePm.onground >= 0) ~= cGround then
			groundMismatch += 1
		end
		if coursePm.waterlevel ~= tr[9] then
			groundMismatch += 1
		end
	end
end

runCourse(pm, script, 300, 0)
print(("course 1 (e1m1 flat/run/jump): max position error %.6f, max velocity error %.6f"):format(maxPosErr, maxVelErr))
t.check(maxPosErr < 0.01, "e1m1 course position matches the verbatim QW C within 0.01 units")
t.check(maxVelErr < 0.05, "e1m1 course velocity matches within 0.05")

-- course 2: the dm3 staircase at x=-64 (risers 56/72/88/104 heading +y).
-- Climb, descend, re-climb, jumping climb, diagonal — PM_GroundMove's
-- step-up path under every approach. Mirrored in tools/pmove_truth.c.
local stairScript = {
	{ 30, 400, 0, 0, 90, 0, false },
	{ 45, 400, 0, 0, 270, 0, false },
	{ 70, 400, 0, 0, 90, 0, false },
	{ 85, 400, 0, 0, 270, 0, false },
	{ 105, 400, 0, 0, 90, 0, true },
	{ 120, 400, 0, 0, 270, 0, false },
	{ 160, 400, 350, 0, 45, 0, false },
}
local stairPm: pmovelib.PlayerMove = {
	origin = vector.create(-64, 480, 44),
	angles = vector.zero,
	velocity = vector.zero,
	oldbuttons = 0,
	waterjumptime = 0,
	dead = false,
	spectator = false,
	physents = { { model = stairworld, origin = vector.zero } },
	cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, msec = 50 },
	numtouch = 0,
	touchindex = {},
	onground = -1,
	waterlevel = 0,
	watertype = -1,
}
runCourse(stairPm, stairScript, 160, 300)
print(("course 2 (dm3 stairs): max position error %.6f, max velocity error %.6f overall"):format(maxPosErr, maxVelErr))
t.check(maxPosErr < 0.01, "stair course position matches the verbatim QW C within 0.01 units")
t.check(maxVelErr < 0.05, "stair course velocity matches within 0.05")
-- guard that the truth course really covers step-ups: the C player must
-- have climbed from the z-40 floor past the z-104 landing
local truthMaxZ = 0
for tick = 301, 460 do
	truthMaxZ = math.max(truthMaxZ, truth[tick][4])
end
t.check(truthMaxZ > 110, `truth course covers the staircase (max z {truthMaxZ})`)

-- course 3: spectator flight on e1m1 (SpectatorMove accel/friction, no
-- gravity). Mirrored in tools/pmove_truth.c ticks 461-520.
local specScript = {
	{ 20, 400, 0, 0, 90, -30, false },
	{ 35, 0, 350, 0, 90, 0, false },
	{ 50, -400, 0, 200, 180, 45, false },
	{ 60, 0, 0, 0, 0, 0, false },
}
local specPm: pmovelib.PlayerMove = {
	origin = vector.create(480, -352, 88),
	angles = vector.zero,
	velocity = vector.zero,
	oldbuttons = 0,
	waterjumptime = 0,
	dead = false,
	spectator = true,
	physents = { { model = world, origin = vector.zero } },
	cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, msec = 50 },
	numtouch = 0,
	touchindex = {},
	onground = -1,
	waterlevel = 0,
	watertype = -1,
}
runCourse(specPm, specScript, 60, 460)
print(("course 3 (spectator flight): max position error %.6f overall"):format(maxPosErr))
t.check(maxPosErr < 0.01, "spectator course matches the verbatim QW C within 0.01 units")
t.check(specPm.origin.z > 150, `spectator flew (final z {string.format("%.0f", specPm.origin.z)})`)
-- course 4: the e1m1 water pool — PM_WaterMove swim accel/friction,
-- waterlevel transitions, CheckWaterJump attempt. Mirrored in
-- tools/pmove_truth.c ticks 521-600.
local waterScript = {
	{ 20, 400, 0, 0, 90, 30, false },
	{ 35, 400, 0, 200, 270, -45, false },
	{ 55, 400, 0, 0, 0, -20, true },
	{ 80, 0, 0, -200, 180, 0, false },
}
local waterPm: pmovelib.PlayerMove = {
	origin = vector.create(656, 992, -330),
	angles = vector.zero,
	velocity = vector.zero,
	oldbuttons = 0,
	waterjumptime = 0,
	dead = false,
	spectator = false,
	physents = { { model = world, origin = vector.zero } },
	cmd = { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, msec = 50 },
	numtouch = 0,
	touchindex = {},
	onground = -1,
	waterlevel = 0,
	watertype = -1,
}
runCourse(waterPm, waterScript, 80, 520)
print(("course 4 (water): max position error %.6f overall"):format(maxPosErr))
t.check(maxPosErr < 0.01, "water course matches the verbatim QW C within 0.01 units")
local waterTicks, levelKinds = 0, {}
for tick = 521, 600 do
	if truth[tick][9] > 0 then
		waterTicks += 1
	end
	levelKinds[truth[tick][9]] = true
end
t.check(waterTicks >= 60 and levelKinds[1] and levelKinds[2] and levelKinds[3], `truth course covers waterlevels 1/2/3 over {waterTicks} wet ticks`)

t.eq(groundMismatch, 0, "onground/waterlevel agree every tick, all courses")
t.finish("test_qw_pmove")
