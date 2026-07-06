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
-- V_AddIdle sway cvars (view.c defaults)
local v_iyaw_cycle, v_iyaw_level = 2, 0.3
local v_iroll_cycle, v_iroll_level = 0.5, 0.1
local v_ipitch_cycle, v_ipitch_level = 1, 0.3
-- pitch drift cvars
local v_centermove = 0.15
local v_centerspeed = 500
local cl_forwardspeed = 200

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

-- V_AddIdle: returns the (pitch, yaw, roll) sway additions
local function addIdle(time: number, idlescale: number): (number, number, number)
	local pitch = idlescale * math.sin(time * v_ipitch_cycle) * v_ipitch_level
	local yaw = idlescale * math.sin(time * v_iyaw_cycle) * v_iyaw_level
	local roll = idlescale * math.sin(time * v_iroll_cycle) * v_iroll_level
	return pitch, yaw, roll
end
view.addIdle = addIdle

-- V_BoundOffsets: the eye stays within 14 units laterally and -22/+30
-- vertically of the view entity origin ("don't allow cheats" in C)
local function boundOffsets(vieworg: vector, entorg: vector): vector
	return vector.create(
		math.clamp(vieworg.x, entorg.x - 14, entorg.x + 14),
		math.clamp(vieworg.y, entorg.y - 14, entorg.y + 14),
		math.clamp(vieworg.z, entorg.z - 22, entorg.z + 30)
	)
end
view.boundOffsets = boundOffsets

--------------------------------------------------------------------------
-- pitch drift (V_StartPitchDrift / V_StopPitchDrift / V_DriftPitch):
-- with +mlook centering, the view glides back to idealpitch when the
-- player runs forward. State is a plain table so both boots (and tests)
-- can drive it; under always-on mouselook any mouse pitch movement calls
-- stop, exactly like C's IN_MouseMove.

export type PitchDrift = {
	nodrift: boolean,
	pitchvel: number,
	driftmove: number,
	laststop: number,
}

function view.newPitchDrift(): PitchDrift
	-- C's cl struct starts zeroed: drifting armed
	return { nodrift = false, pitchvel = 0, driftmove = 0, laststop = -1 }
end

function view.startPitchDrift(d: PitchDrift, time: number)
	if d.laststop == time then
		return -- something else is keeping it from drifting
	end
	if d.nodrift or d.pitchvel == 0 then
		d.pitchvel = v_centerspeed
		d.nodrift = false
		d.driftmove = 0
	end
end

function view.stopPitchDrift(d: PitchDrift, time: number)
	d.laststop = time
	d.nodrift = true
	d.pitchvel = 0
end

-- V_DriftPitch: returns the new view pitch. `onground` false (or demo
-- playback upstream) resets the accumulators like C.
function view.driftPitch(d: PitchDrift, time: number, pitch: number, idealpitch: number, frametime: number, onground: boolean, forwardmove: number): number
	if not onground then
		d.driftmove = 0
		d.pitchvel = 0
		return pitch
	end

	if d.nodrift then
		-- re-arm: sustained forward running starts the drift
		if math.abs(forwardmove) < cl_forwardspeed then
			d.driftmove = 0
		else
			d.driftmove += frametime
		end
		if d.driftmove > v_centermove then
			view.startPitchDrift(d, time) -- laststop==time guard applies
		end
		return pitch
	end

	local delta = idealpitch - pitch
	if delta == 0 then
		d.pitchvel = 0
		return pitch
	end

	local move = frametime * d.pitchvel
	d.pitchvel += frametime * v_centerspeed
	if delta > 0 then
		if move > delta then
			d.pitchvel = 0
			move = delta
		end
		return pitch + move
	else
		if move > -delta then
			d.pitchvel = 0
			move = -delta
		end
		return pitch - move
	end
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

-- V_CalcIntermissionRefdef: the view sits on the view entity with the
-- gun hidden and full idle sway (v_idlescale forced 1)
local function calcIntermissionRefdef(c: cllib.Client): Refdef
	local e = c.entities[c.viewentity]
	local entOrigin = if e then e.origin else vector.zero
	local viewangles = if e then e.angles else c.viewangles
	local ip, iy, ir = addIdle(c.time, 1)
	viewangles += vector.create(ip, iy, ir)
	return {
		vieworg = entOrigin,
		viewangles = viewangles,
		gunorg = entOrigin,
		gunangles = vector.zero,
		gunmodel = 0, -- view->model = NULL
		gunframe = 0,
	}
end
view.calcIntermissionRefdef = calcIntermissionRefdef

-- V_CalcRefdef (plus V_CalcViewRoll folded in); V_RenderView's
-- intermission dispatch included
function view.calcRefdef(c: cllib.Client, frametime: number): Refdef
	if (c.intermission or 0) ~= 0 then
		return calcIntermissionRefdef(c)
	end
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

	-- V_BoundOffsets: keep the eye near the view entity (bob/viewheight
	-- never exceed the bounds in practice; kept for C shape)
	vieworg = boundOffsets(vieworg, entOrigin)

	-- V_AddIdle (v_idlescale is 0 by default outside intermission)
	if v_idlescale ~= 0 then
		local ip, iy, ir = addIdle(c.time, v_idlescale)
		viewangles += vector.create(ip, iy, ir)
	end

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
