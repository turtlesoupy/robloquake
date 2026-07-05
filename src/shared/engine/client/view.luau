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

-- V_CalcPowerupCshift: quad > suit > invis > invuln priority chain
function view.powerupShift(items: number): { number }?
	if bit32.band(items, 2097152) ~= 0 then -- IT_QUAD
		return { 0, 0, 255, 30 }
	elseif bit32.band(items, 1048576) ~= 0 then -- IT_SUIT
		return { 0, 255, 0, 20 }
	elseif bit32.band(items, 524288) ~= 0 then -- IT_INVISIBILITY
		return { 100, 100, 100, 100 }
	elseif bit32.band(items, 4194304) ~= 0 then -- IT_INVULNERABILITY
		return { 255, 255, 0, 30 }
	end
	return nil
end

-- V_CalcBlend: accumulate {r,g,b,percent} shifts with a += a2*(1-a) and
-- colors weighted a2/a (the final on-screen alpha cap of 0.85 is applied
-- by the Roblox layer, a recorded delta)
function view.calcBlend(shifts: { { number } }): (number, number, number, number)
	local r, g, b, a = 0, 0, 0, 0
	for _, sh in shifts do
		local a2 = math.clamp(sh[4], 0, 255) / 255
		a = a + a2 * (1 - a)
		if a > 0 then
			local w2 = a2 / a
			r = r * (1 - w2) + sh[1] * w2
			g = g * (1 - w2) + sh[2] * w2
			b = b * (1 - w2) + sh[3] * w2
		end
	end
	return r, g, b, a
end

-- exported for tests (C-truth checks against view.c formulas)
view.calcRoll = calcRoll
view.calcBob = calcBob
view.resetOldz = function(z: number)
	oldz = z
end

return view
