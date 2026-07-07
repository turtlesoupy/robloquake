--!strict
-- QW view/refdef composition vs ground truth from the verbatim C
-- (tools/view_truth.c): 400 scripted frames through view.calcRefdefQW —
-- forward run-up, strafe lean, airborne bob-hold, damage kick + punch,
-- stair glide, dead, gib, spectator. The tape here MUST mirror the C
-- main() exactly; regenerate the fixture per the header of view_truth.c.
local fs = require("@lune/fs")
local t = require("./testutil")
local view = require("../src/shared/engine/client/view")

local truth: { { number } } = {}
for line in fs.readFile("tests/fixtures/view_truth.txt"):gmatch("[^\n]+") do
	local n = {}
	for tok in line:gmatch("%S+") do
		table.insert(n, tonumber(tok) :: number)
	end
	truth[n[1]] = n
end
t.eq(#truth, 400, "fixture has 400 frames")

local dt = 1 / 64
local st = view.newQWRefdefState()
local dmg = { dmgTime = 0, dmgRoll = 0, dmgPitch = 0 }
local punchangle = 0

local TOL_ORG = 0.005 -- float-vs-double slack (bob cycle via float 0.6 cvar)
local TOL_ANG = 0.005

local worst = 0
local failures = 0
for f = 1, 400 do
	local seg_air = f > 120 and f <= 160
	local seg_dead = f > 200 and f <= 230
	local seg_gib = f > 230 and f <= 260
	local seg_spec = f > 260 and f <= 300

	local vx = math.min(f * 4, 320)
	local vy = if f > 80 and f <= 120 then 200 else 0
	local vz = if seg_air then 270 - (f - 120) * 800 / 64 else 0
	if seg_dead or seg_gib then
		vx, vy = 0, 0
	end
	if seg_spec then
		vx, vy, vz = 400, 300, 100
	end

	local orgz = 24
	if f > 170 and f <= 200 then
		orgz = 24 + (math.floor((f - 170) / 10) + 1) * 8
	end

	if f == 161 then
		dmg.dmgTime, dmg.dmgRoll, dmg.dmgPitch = 0.5, 6, 4
	end
	if f == 165 then
		punchangle = 2
	end
	-- DropPunchAngle runs before the refdef, like V_RenderView
	punchangle = math.max(punchangle - 10 * dt, 0)

	local vieworg, viewangles, gunorg, gunangles, gunVisible = view.calcRefdefQW(st, dmg, {
		dt = dt,
		simorg = vector.create(f * 2, f % 50, orgz),
		simvel = vector.create(vx, vy, vz),
		simangles = vector.create((f % 41 - 20) * 0.5, (f * 7) % 360, 0),
		punchangle = punchangle,
		onground = not seg_air,
		dead = seg_dead,
		gib = seg_gib,
		spectator = seg_spec,
		viewheight = 22,
		viewsize = 100,
	})

	local tr = truth[f]
	local got = {
		vieworg.x, vieworg.y, vieworg.z,
		viewangles.x, viewangles.y, viewangles.z,
		gunorg.x, gunorg.y, gunorg.z,
		gunangles.x, gunangles.y, gunangles.z,
	}
	for i = 1, 12 do
		local tol = if i >= 4 and i <= 6 or i >= 10 then TOL_ANG else TOL_ORG
		local d = math.abs(got[i] - tr[i + 1])
		worst = math.max(worst, d)
		if d > tol then
			failures += 1
			if failures <= 5 then
				print(`frame {f} component {i}: port {got[i]} vs C {tr[i + 1]} (|d|={d})`)
			end
		end
	end
	if (if gunVisible then 1 else 0) ~= tr[14] then
		failures += 1
		print(`frame {f}: gunVisible port={gunVisible} C={tr[14]}`)
	end
end

print(`  worst component |d| = {worst}`)
t.eq(failures, 0, `all 400 frames x12 components within tolerance (worst |d| = {worst})`)

-- the tape must actually exercise the interesting paths (guards against a
-- silently degenerate course, pmove_truth.c pattern)
t.check(truth[165][5] - (-9.5) > 5, "course guard: kick+punch visibly deflect view pitch at f165")
t.check(truth[165][11] - (-truth[165][5]) > 1.5, "course guard: gun pitch excludes punch at f165")
t.check(truth[205][7] == 80, "course guard: dead roll 80 at f205")
t.check(math.abs(truth[235][4] - (24 + 8 + 1 / 16)) < 0.01 and truth[235][14] == 0, "course guard: gib view +8 with gun hidden")
t.check(truth[190][4] < 48 + 22, "course guard: stair glide holds the eye below the step")
t.check(math.abs(truth[270][4] - (24 + 22 + 1 / 16)) < 1e-4, "course guard: spectator flight has zero bob")

t.finish("test_view_truth")
