--!strict
-- CalcFov (screen.c) and the vrect fov derivation: the fov cvar is the
-- HORIZONTAL field of view; C computes fov_y = atan(height / (width /
-- tan(fov_x*pi/360))) * 360/pi. The C formula is transcribed here
-- independently and compared against the port, plus two hand-derived
-- anchors (fov 90: 73.74 at 4:3 — the classic Quake vertical fov —
-- and 58.72 at 16:9).
local t = require("./testutil")
local qcoords = require("../src/shared/engine/client/qcoords")

local function cCalcFov(fovX: number, width: number, height: number): number
	local x = width / math.tan(fovX / 360 * math.pi)
	return math.atan(height / x) * 360 / math.pi
end

t.check(math.abs(qcoords.calcFovY(90, 4, 3) - 73.7398) < 0.001, "fov 90 at 4:3 = 73.74 vertical (hand-derived)")
t.check(math.abs(qcoords.calcFovY(90, 16, 9) - 58.7155) < 0.001, "fov 90 at 16:9 = 58.72 vertical (hand-derived)")

local casesOk = true
for _, case in { { 90, 640, 480 }, { 110, 640, 480 }, { 75, 1920, 1080 }, { 130, 1280, 720 }, { 10, 800, 600 } } do
	local got = qcoords.calcFovY(case[1], case[2], case[3])
	local want = cCalcFov(case[1], case[2], case[3])
	if math.abs(got - want) > 1e-9 then
		casesOk = false
	end
end
t.check(casesOk, "calcFovY matches the transcribed screen.c CalcFov for 5 cases")

-- vrect: fov_y derives from the window minus the sbar strip (R_SetVrect
-- semantics); with no strip it degenerates to plain CalcFov and no gun
-- rotation
local fy0, gp0 = qcoords.vrect(90, 1600, 900, 0)
t.check(math.abs(fy0 - qcoords.calcFovY(90, 1600, 900)) < 1e-9 and gp0 == 0, "vrect with no sbar = plain CalcFov, no gun rotation")
local fy1, gp1 = qcoords.vrect(90, 1600, 900, 96)
t.check(math.abs(fy1 - cCalcFov(90, 1600, 900 - 96)) < 1e-9, "vrect fov_y computed at the reduced height (window minus sbar)")
t.check(gp1 > 0, "gun rotation engages with a strip")
local _, gp2 = qcoords.vrect(90, 1600, 900, 144)
t.check(gp2 > gp1, "gun rotation grows with the strip (viewsize scaling)")

t.finish("test_qcoords")
