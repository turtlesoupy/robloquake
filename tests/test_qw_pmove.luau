--!strict
-- QW pmove vs ground truth from the verbatim C (tools/pmove_truth.c)
local t = require("./testutil")
local vfslib = require("../src/shared/engine/common/vfs")
local bsplib = require("../src/shared/engine/bsp/bsp")
local pmovelib = require("../src/shared/engine/qw/pmove")

local fs = require("@lune/fs")

local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/e1m1.bsp")
assert(buf)
local world = bsplib.load("maps/e1m1.bsp", buf)[1]

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
for tick = 1, 300 do
	local ph = script[#script]
	for _, s in script do
		if tick <= s[1] then
			ph = s
			break
		end
	end
	pm.cmd = {
		angles = vector.create(ph[6], ph[5], 0),
		forwardmove = ph[2],
		sidemove = ph[3],
		upmove = ph[4],
		buttons = if ph[7] then 2 else 0,
		msec = 50,
	}
	pmovelib.playerMove(pm, movevars)

	local tr = truth[tick]
	local posErr = vector.magnitude(pm.origin - vector.create(tr[2], tr[3], tr[4]))
	local velErr = vector.magnitude(pm.velocity - vector.create(tr[5], tr[6], tr[7]))
	maxPosErr = math.max(maxPosErr, posErr)
	maxVelErr = math.max(maxVelErr, velErr)
	local cGround = tr[8] == 1
	if (pm.onground >= 0) ~= cGround then
		groundMismatch += 1
	end
	if pm.waterlevel ~= tr[9] then
		groundMismatch += 1
	end
end

print(("max position error: %.6f units, max velocity error: %.6f over 300 ticks"):format(maxPosErr, maxVelErr))
t.check(maxPosErr < 0.01, "position matches the verbatim QW C within 0.01 units")
t.check(maxVelErr < 0.05, "velocity matches within 0.05")
t.eq(groundMismatch, 0, "onground/waterlevel agree every tick")
t.finish("test_qw_pmove")
