--!strict
--!optimize 2
-- View setup — port of view.c V_CalcRefdef / V_CalcBob / V_CalcViewRoll:
-- computes the camera origin and angles (in quake space) from client state.

local cllib = require("./cl")
local mathlib = require("../common/mathlib")

local view = {}

-- cvar defaults
local cl_bob = 0.02
local cl_bobcycle = 0.6
local cl_bobup = 0.5
local v_kicktime = 0.5
local v_idlescale = 0 -- disabled by default

local oldz = 0 -- stair smoothing state

-- V_CalcRoll
local function calcRoll(angles: vector, velocity: vector): number
	local _, right = mathlib.angleVectors(angles)
	local side = vector.dot(velocity, right)
	local sign = if side < 0 then -1 else 1
	side = math.abs(side)
	if side < 200 then
		side = side * 2 / 200
	else
		side = 2
	end
	return side * sign
end

-- V_CalcBob
local function calcBob(c: cllib.Client): number
	local cycle = (c.time - math.floor(c.time / cl_bobcycle) * cl_bobcycle) / cl_bobcycle
	if cycle < cl_bobup then
		cycle = math.pi * cycle / cl_bobup
	else
		cycle = math.pi + math.pi * (cycle - cl_bobup) / (1 - cl_bobup)
	end

	-- bob is proportional to velocity in the xy plane
	local bob = math.sqrt(c.velocity.x * c.velocity.x + c.velocity.y * c.velocity.y) * cl_bob
	bob = bob * 0.3 + bob * 0.7 * math.sin(cycle)
	return math.clamp(bob, -7, 4)
end

export type Refdef = {
	vieworg: vector,
	viewangles: vector,
	-- gun
	gunorg: vector,
	gunangles: vector,
	gunmodel: number, -- precache index
	gunframe: number,
}

-- V_CalcRefdef (plus V_CalcViewRoll folded in)
function view.calcRefdef(c: cllib.Client, frametime: number): Refdef
	local e = c.entities[c.viewentity]
	local entOrigin = if e then e.origin else vector.zero

	local bob = calcBob(c)

	-- never let it sit exactly on a node line (1/32 nudge)
	local vieworg = entOrigin + vector.create(1 / 32, 1 / 32, c.viewheight + bob + 1 / 32)

	local viewangles = c.viewangles

	-- V_CalcViewRoll
	local roll = calcRoll(if e then e.angles else vector.zero, c.velocity)
	if c.dmg_time > 0 then
		roll += c.dmg_time / v_kicktime * c.dmg_roll
		viewangles = vector.create(viewangles.x + c.dmg_time / v_kicktime * c.dmg_pitch, viewangles.y, viewangles.z)
		c.dmg_time -= frametime
	end
	if c.stats[cllib.STAT_HEALTH] <= 0 then
		roll = 80 -- dead view angle
	end
	viewangles = vector.create(viewangles.x, viewangles.y, viewangles.z + roll)

	-- V_AddIdle would go here (v_idlescale is 0 by default)
	local _ = v_idlescale

	-- gun position
	local forward = mathlib.angleVectors(viewangles)
	local gunorg = entOrigin + vector.create(0, 0, c.viewheight) + forward * (bob * 0.4) + vector.create(0, 0, bob)
	-- CalcGunAngle: gun yaws/pitches with the view
	local gunangles = vector.create(-viewangles.x, viewangles.y, 0)

	-- add punch angle
	viewangles += c.punchangle

	-- smooth out stair step ups
	if c.onground and entOrigin.z - oldz > 0 then
		local steptime = math.max(c.time - c.oldtime, 0)
		oldz += steptime * 80
		if oldz > entOrigin.z then
			oldz = entOrigin.z
		end
		if entOrigin.z - oldz > 12 then
			oldz = entOrigin.z - 12
		end
		vieworg += vector.create(0, 0, oldz - entOrigin.z)
		gunorg += vector.create(0, 0, oldz - entOrigin.z)
	else
		oldz = entOrigin.z
	end

	return {
		vieworg = vieworg,
		viewangles = viewangles,
		gunorg = gunorg,
		gunangles = gunangles,
		gunmodel = c.stats[cllib.STAT_WEAPON],
		gunframe = c.stats[cllib.STAT_WEAPONFRAME],
	}
end

-- exported for tests (C-truth checks against view.c formulas)
view.calcRoll = calcRoll
view.calcBob = calcBob
view.resetOldz = function(z: number)
	oldz = z
end

return view
