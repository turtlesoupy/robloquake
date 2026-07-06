--!strict
-- QW client presentation logic, kept pure so lune tests can drive it and
-- qwclient.luau stays a thin consumer:
--  * view.c screen-blend pipeline: V_SetContentsColor, V_CalcPowerupCshift,
--    V_ParseDamage's damage shift + view-angle kick, V_BonusFlash_f,
--    V_cshift_f (writes cshift_empty, like C), V_UpdatePalette's
--    150/s + 100/s drops, V_CalcBlend's accumulation
--  * cl_ents.c CL_AddFlagModels placement (CTF flag on the carrier's back)
--  * cl_tent.c CL_AllocExplosion / CL_UpdateExplosions (s_explod ring)
--    + CL_ClearTEnts
--  * sbar.c Sbar_SortFrags / Sbar_SortTeams

local mathlib = require("../common/mathlib")

local qwview = {}

export type Cshift = { r: number, g: number, b: number, percent: number }

export type BlendState = {
	-- CSHIFT_CONTENTS/DAMAGE/BONUS/POWERUP (view.c NUM_CSHIFTS order)
	cshifts: { Cshift },
	-- cshift_empty: what CONTENTS_EMPTY looks like; v_cshift edits THIS
	empty: Cshift,
	-- V_ParseDamage kick state consumed by V_CalcViewRoll
	dmgRoll: number,
	dmgPitch: number,
	dmgTime: number,
}

-- view.c cvar defaults
local V_KICKTIME = 0.5 -- v_kicktime
local V_KICKROLL = 0.6 -- v_kickroll
local V_KICKPITCH = 0.6 -- v_kickpitch

-- bothdefs.h contents values
local CONTENTS_SOLID = -2
local CONTENTS_WATER = -3
local CONTENTS_SLIME = -4
local CONTENTS_LAVA = -5

-- bothdefs.h item bits (powerups)
local IT_INVISIBILITY = 524288
local IT_INVULNERABILITY = 1048576
local IT_SUIT = 2097152
local IT_QUAD = 4194304

function qwview.newBlendState(): BlendState
	return {
		cshifts = {
			{ r = 130, g = 80, b = 50, percent = 0 }, -- contents
			{ r = 255, g = 0, b = 0, percent = 0 }, -- damage
			{ r = 215, g = 186, b = 69, percent = 0 }, -- bonus
			{ r = 0, g = 0, b = 255, percent = 0 }, -- powerup
		},
		empty = { r = 130, g = 80, b = 50, percent = 0 }, -- cshift_empty
		dmgRoll = 0,
		dmgPitch = 0,
		dmgTime = 0,
	}
end

-- V_SetContentsColor: lava {255,80,0,150}, solid/slime {0,25,5,150},
-- water {130,80,50,128}, empty = cshift_empty
function qwview.setContentsColor(st: BlendState, contents: number)
	local cs = st.cshifts[1]
	if contents == CONTENTS_LAVA then
		cs.r, cs.g, cs.b, cs.percent = 255, 80, 0, 150
	elseif contents == CONTENTS_SOLID or contents == CONTENTS_SLIME then
		cs.r, cs.g, cs.b, cs.percent = 0, 25, 5, 150
	elseif contents == CONTENTS_WATER then
		cs.r, cs.g, cs.b, cs.percent = 130, 80, 50, 128
	else
		cs.r, cs.g, cs.b, cs.percent = st.empty.r, st.empty.g, st.empty.b, st.empty.percent
	end
end

-- V_CalcPowerupCshift
function qwview.calcPowerupCshift(st: BlendState, items: number)
	local pw = st.cshifts[4]
	if bit32.band(items, IT_QUAD) ~= 0 then
		pw.r, pw.g, pw.b, pw.percent = 0, 0, 255, 30
	elseif bit32.band(items, IT_SUIT) ~= 0 then
		pw.r, pw.g, pw.b, pw.percent = 0, 255, 0, 20
	elseif bit32.band(items, IT_INVISIBILITY) ~= 0 then
		pw.r, pw.g, pw.b, pw.percent = 100, 100, 100, 100
	elseif bit32.band(items, IT_INVULNERABILITY) ~= 0 then
		pw.r, pw.g, pw.b, pw.percent = 255, 255, 0, 30
	else
		pw.percent = 0
	end
end

-- V_ParseDamage body after the wire reads: damage cshift + the view-angle
-- kick. `from` is the attack origin, simorg/simangles the view state.
-- Returns count (the caller sets faceanimtime).
function qwview.parseDamage(st: BlendState, armor: number, blood: number, from: vector, simorg: vector, simangles: vector): number
	local count = blood * 0.5 + armor * 0.5
	if count < 10 then
		count = 10
	end

	local dmg = st.cshifts[2]
	dmg.percent = math.clamp(dmg.percent + 3 * count, 0, 150)
	if armor > blood then
		dmg.r, dmg.g, dmg.b = 200, 100, 100
	elseif armor > 0 then
		dmg.r, dmg.g, dmg.b = 220, 50, 50
	else
		dmg.r, dmg.g, dmg.b = 255, 0, 0
	end

	local dir = from - simorg
	local len = vector.magnitude(dir)
	if len > 0 then
		dir = dir / len
	end
	local forward, right, _up = mathlib.angleVectors(simangles)
	st.dmgRoll = count * vector.dot(dir, right) * V_KICKROLL
	st.dmgPitch = count * vector.dot(dir, forward) * V_KICKPITCH
	st.dmgTime = V_KICKTIME
	return count
end

-- V_BonusFlash_f ("bf" stuffed by the server on item pickup)
function qwview.bonusFlash(st: BlendState)
	local b = st.cshifts[3]
	b.r, b.g, b.b, b.percent = 215, 186, 69, 50
end

-- V_cshift_f: "v_cshift r g b pct" edits cshift_empty (atoi: missing -> 0)
function qwview.cshiftCmd(st: BlendState, args: string)
	local vals = {}
	for tok in args:gmatch("%S+") do
		table.insert(vals, tonumber(tok) or 0)
	end
	st.empty.r = vals[1] or 0
	st.empty.g = vals[2] or 0
	st.empty.b = vals[3] or 0
	st.empty.percent = vals[4] or 0
end

-- V_UpdatePalette's per-frame drops (damage 150/s, bonus 100/s, floor 0)
-- and the kick timer count-down
function qwview.dropShifts(st: BlendState, frametime: number)
	local dmg = st.cshifts[2]
	dmg.percent = math.max(dmg.percent - frametime * 150, 0)
	local bonus = st.cshifts[3]
	bonus.percent = math.max(bonus.percent - frametime * 100, 0)
end

-- V_CalcBlend: accumulate the four shifts front-to-back. Returns r,g,b in
-- 0-255 and alpha 0..1 (clamped like C's v_blend[3])
function qwview.calcBlend(st: BlendState): (number, number, number, number)
	local r, g, b, a = 0, 0, 0, 0
	for _, cs in st.cshifts do
		local a2 = cs.percent / 255
		if a2 > 0 then
			a = a + a2 * (1 - a)
			a2 = a2 / a
			r = r * (1 - a2) + cs.r * a2
			g = g * (1 - a2) + cs.g * a2
			b = b * (1 - a2) + cs.b * a2
		end
	end
	return r, g, b, math.clamp(a, 0, 1)
end

--------------------------------------------------------------------------
-- cl_ents.c CL_AddFlagModels: flag riding the carrier's back. The f
-- offset leans the flag with the player's animation frame; z forward
-- component is reversed and the flag rolls -45.
function qwview.flagPlacement(frame: number, angles: vector, origin: vector): (vector, vector)
	local f = 14
	if frame >= 29 and frame <= 34 then -- axpain
		f += ({ [29] = 2, [30] = 8, [31] = 12, [32] = 11, [33] = 10, [34] = 4 })[frame] :: number
	elseif frame >= 35 and frame <= 40 then -- pain
		f += ({ [35] = 2, [36] = 10, [37] = 10, [38] = 8, [39] = 4, [40] = 2 })[frame] :: number
	elseif frame >= 103 and frame <= 106 then -- nailattack/light
		f += 6
	elseif frame >= 107 and frame <= 118 then -- rocket/shotattack
		f += 7
	end
	local forward, right, _up = mathlib.angleVectors(angles)
	forward = vector.create(forward.x, forward.y, -forward.z) -- reverse z component
	local org = origin - forward * f + right * 22 + vector.create(0, 0, -16)
	local ang = vector.create(angles.x, angles.y, angles.z - 45)
	return org, ang
end

--------------------------------------------------------------------------
-- cl_tent.c explosion ring (MAX_EXPLOSIONS 8): s_explod.spr at 10 Hz

export type Explosion = { origin: vector, start: number }

local MAX_EXPLOSIONS = 8

-- CL_AllocExplosion: first free slot, else the oldest
function qwview.allocExplosion(explosions: { Explosion? }, origin: vector, time: number): number
	local slot: number? = nil
	for i = 1, MAX_EXPLOSIONS do
		if not explosions[i] then
			slot = i
			break
		end
	end
	if not slot then
		local oldest = time
		slot = 1
		for i = 1, MAX_EXPLOSIONS do
			local ex = explosions[i] :: Explosion
			if ex.start < oldest then
				oldest = ex.start
				slot = i
			end
		end
	end
	explosions[slot :: number] = { origin = origin, start = time }
	return slot :: number
end

-- CL_UpdateExplosions frame math: 10*(time-start), truncated; nil when
-- the sprite runs out of frames (caller frees the slot)
function qwview.explosionFrame(ex: Explosion, time: number, numframes: number): number?
	local f = math.floor(10 * (time - ex.start))
	if f >= numframes then
		return nil
	end
	return f
end

-- CL_ClearTEnts: beams and explosions both zeroed on level start
function qwview.clearTEnts(beams: { any }, explosions: { Explosion? })
	table.clear(beams)
	table.clear(explosions)
end

--------------------------------------------------------------------------
-- sbar.c sorting. Slot tables are 1-based arrays of
-- { name, frags, spectator?, ping?, team? } (empty name = empty slot).

export type ScoreSlot = {
	name: string,
	frags: number,
	spectator: boolean?,
	ping: number?,
	team: string?,
}

-- Sbar_SortFrags: returns slot indices, frags descending (bubble sort =
-- stable, ties keep slot order). Spectators excluded unless includespec;
-- like C, an included spectator's frags read as -999.
function qwview.sortFrags(slots: { ScoreSlot }, includespec: boolean): { number }
	local order = {}
	for i, s in slots do
		if s.name ~= "" and (not s.spectator or includespec) then
			if s.spectator then
				s.frags = -999
			end
			table.insert(order, i)
		end
	end
	-- table.sort is unstable; replicate the C bubble sort explicitly
	local n = #order
	for i = 1, n do
		for j = 1, n - i do
			if slots[order[j]].frags < slots[order[j + 1]].frags then
				order[j], order[j + 1] = order[j + 1], order[j]
			end
		end
	end
	return order
end

export type TeamScore = {
	team: string,
	frags: number,
	players: number,
	plow: number,
	phigh: number,
	ptotal: number,
}

-- Sbar_SortTeams: aggregate non-spectator players by their team key,
-- frags descending. Returns {} when teamplay is off (C early-out).
function qwview.sortTeams(slots: { ScoreSlot }, teamplay: number): { TeamScore }
	local teams: { TeamScore } = {}
	if teamplay == 0 then
		return teams
	end
	for _, s in slots do
		if s.name == "" or s.spectator then
			continue
		end
		local t = (s.team or ""):sub(1, 16)
		if t == "" then
			continue -- not on team
		end
		local tm: TeamScore? = nil
		for _, existing in teams do
			if existing.team == t then
				tm = existing
				break
			end
		end
		if tm then
			tm.frags += s.frags
			tm.players += 1
		else
			tm = { team = t, frags = s.frags, players = 1, plow = 999, phigh = 0, ptotal = 0 }
			table.insert(teams, tm)
		end
		local ping = s.ping or 0
		if (tm :: TeamScore).plow > ping then
			(tm :: TeamScore).plow = ping
		end
		if (tm :: TeamScore).phigh < ping then
			(tm :: TeamScore).phigh = ping
		end
		(tm :: TeamScore).ptotal += ping
	end
	local n = #teams
	for i = 1, n do
		for j = 1, n - i do
			if teams[j].frags < teams[j + 1].frags then
				teams[j], teams[j + 1] = teams[j + 1], teams[j]
			end
		end
	end
	return teams
end

return qwview
