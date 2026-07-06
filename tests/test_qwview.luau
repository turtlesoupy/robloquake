--!strict
-- QW presentation logic vs transcribed C truths (qwview.luau):
-- view.c V_SetContentsColor/V_CalcPowerupCshift/V_ParseDamage/
-- V_BonusFlash_f/V_cshift_f/V_CalcBlend + the V_UpdatePalette drops,
-- cl_ents.c CL_AddFlagModels placement, cl_tent.c CL_AllocExplosion/
-- CL_UpdateExplosions/CL_ClearTEnts, sbar.c Sbar_SortFrags/Sbar_SortTeams.
-- Also textures.translatePixels vs CL_NewTranslation's table build.
local t = require("./testutil")
local qwview = require("../src/shared/engine/qw/qwview")
local mathlib = require("../src/shared/engine/common/mathlib")

local function approx(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-4)
end

--------------------------------------------------------------------------
-- V_SetContentsColor (bothdefs contents values, view.c cshift tables)
local st = qwview.newBlendState()
qwview.setContentsColor(st, -5) -- CONTENTS_LAVA
t.check(st.cshifts[1].r == 255 and st.cshifts[1].g == 80 and st.cshifts[1].b == 0 and st.cshifts[1].percent == 150, "contents: lava {255,80,0,150}")
qwview.setContentsColor(st, -4) -- CONTENTS_SLIME
t.check(st.cshifts[1].r == 0 and st.cshifts[1].g == 25 and st.cshifts[1].b == 5 and st.cshifts[1].percent == 150, "contents: slime {0,25,5,150}")
qwview.setContentsColor(st, -2) -- CONTENTS_SOLID shares the slime shift
t.check(st.cshifts[1].percent == 150 and st.cshifts[1].g == 25, "contents: solid shares slime shift")
qwview.setContentsColor(st, -3) -- CONTENTS_WATER
t.check(st.cshifts[1].r == 130 and st.cshifts[1].g == 80 and st.cshifts[1].b == 50 and st.cshifts[1].percent == 128, "contents: water {130,80,50,128}")
qwview.setContentsColor(st, -1) -- CONTENTS_EMPTY -> cshift_empty
t.check(st.cshifts[1].percent == 0 and st.cshifts[1].r == 130, "contents: empty -> cshift_empty (percent 0)")

-- V_cshift_f edits cshift_empty (NOT the live contents shift directly)
qwview.cshiftCmd(st, "50 60 70 80")
t.check(st.empty.r == 50 and st.empty.g == 60 and st.empty.b == 70 and st.empty.percent == 80, "v_cshift: writes cshift_empty")
qwview.setContentsColor(st, -1)
t.check(st.cshifts[1].r == 50 and st.cshifts[1].percent == 80, "v_cshift: empty contents now use the edited shift")
qwview.cshiftCmd(st, "") -- atoi of missing args = 0 (the classic "v_cshift" reset)
t.check(st.empty.percent == 0 and st.empty.r == 0, "v_cshift: no args zeroes (atoi behavior)")

--------------------------------------------------------------------------
-- V_CalcPowerupCshift priority: quad > suit > ring > pent
st = qwview.newBlendState()
qwview.calcPowerupCshift(st, 4194304 + 2097152) -- IT_QUAD|IT_SUIT
t.check(st.cshifts[4].r == 0 and st.cshifts[4].b == 255 and st.cshifts[4].percent == 30, "powerup: quad wins {0,0,255,30}")
qwview.calcPowerupCshift(st, 2097152) -- IT_SUIT
t.check(st.cshifts[4].g == 255 and st.cshifts[4].percent == 20, "powerup: suit {0,255,0,20}")
qwview.calcPowerupCshift(st, 524288) -- IT_INVISIBILITY
t.check(st.cshifts[4].r == 100 and st.cshifts[4].percent == 100, "powerup: ring {100,100,100,100}")
qwview.calcPowerupCshift(st, 1048576) -- IT_INVULNERABILITY
t.check(st.cshifts[4].r == 255 and st.cshifts[4].g == 255 and st.cshifts[4].b == 0 and st.cshifts[4].percent == 30, "powerup: pent {255,255,0,30}")
qwview.calcPowerupCshift(st, 0)
t.check(st.cshifts[4].percent == 0, "powerup: none -> percent 0")

--------------------------------------------------------------------------
-- V_ParseDamage: count = blood*.5+armor*.5 floored at 10; percent += 3*count
-- capped 150; color by armor-vs-blood; kick = count*dot*0.6, time 0.5
st = qwview.newBlendState()
local count = qwview.parseDamage(st, 0, 4, vector.create(100, 0, 0), vector.zero, vector.zero)
t.check(count == 10, "damage: tiny hit floors count at 10")
t.check(st.cshifts[2].percent == 30 and st.cshifts[2].r == 255 and st.cshifts[2].g == 0, "damage: blood-only {255,0,0}, percent 3*count")
count = qwview.parseDamage(st, 30, 10, vector.create(100, 0, 0), vector.zero, vector.zero)
t.check(count == 20 and st.cshifts[2].r == 200 and st.cshifts[2].g == 100, "damage: armor>blood -> {200,100,100}")
count = qwview.parseDamage(st, 10, 30, vector.create(100, 0, 0), vector.zero, vector.zero)
t.check(st.cshifts[2].r == 220 and st.cshifts[2].g == 50, "damage: some armor -> {220,50,50}")
for _ = 1, 5 do
	qwview.parseDamage(st, 0, 100, vector.create(100, 0, 0), vector.zero, vector.zero)
end
t.check(st.cshifts[2].percent == 150, "damage: percent caps at 150")

-- kick directions: attacker straight ahead -> pure pitch; to the right -> roll.
-- zero angles: forward=(1,0,0), right=(0,-1,0)
st = qwview.newBlendState()
qwview.parseDamage(st, 20, 20, vector.create(50, 0, 0), vector.zero, vector.zero)
t.check(approx(st.dmgPitch, 20 * 0.6) and approx(st.dmgRoll, 0), "damage kick: frontal hit -> pitch count*0.6, no roll")
t.check(st.dmgTime == 0.5, "damage kick: v_kicktime 0.5")
qwview.parseDamage(st, 20, 20, vector.create(0, -50, 0), vector.zero, vector.zero)
t.check(approx(st.dmgRoll, 20 * 0.6) and approx(st.dmgPitch, 0), "damage kick: hit from the right -> roll count*0.6")

--------------------------------------------------------------------------
-- V_BonusFlash_f + V_UpdatePalette drops
qwview.bonusFlash(st)
t.check(st.cshifts[3].r == 215 and st.cshifts[3].g == 186 and st.cshifts[3].b == 69 and st.cshifts[3].percent == 50, "bonus flash: {215,186,69,50}")
st.cshifts[2].percent = 150
qwview.dropShifts(st, 0.1)
t.check(st.cshifts[2].percent == 135 and st.cshifts[3].percent == 40, "drops: damage 150/s, bonus 100/s")
qwview.dropShifts(st, 10)
t.check(st.cshifts[2].percent == 0 and st.cshifts[3].percent == 0, "drops: floor at 0")

--------------------------------------------------------------------------
-- V_CalcBlend: hand-derived two-shift anchor (water 128 + damage 150)
st = qwview.newBlendState()
st.cshifts[1].r, st.cshifts[1].g, st.cshifts[1].b, st.cshifts[1].percent = 130, 80, 50, 128
st.cshifts[2].percent = 150 -- {255,0,0}
local r, g, b, a = qwview.calcBlend(st)
-- a1 = 128/255 = .501961; a2 = 150/255 = .588235
-- a = .501961 + .588235*(1-.501961) = .794925; w2 = .588235/.794925 = .739988
-- r = 130*(1-w2) + 255*w2 = 222.499; g = 80*(1-w2) = 20.801; b = 50*(1-w2) = 13.001
t.check(approx(a, 0.794925, 1e-5), "blend: alpha accumulates a2*(1-a)")
t.check(approx(r, 222.499, 0.01) and approx(g, 20.801, 0.01) and approx(b, 13.001, 0.01), "blend: colors weighted a2/a")
st.cshifts[1].percent = 0
st.cshifts[2].percent = 0
r, g, b, a = qwview.calcBlend(st)
t.check(a == 0, "blend: all zero -> transparent")
st.cshifts[2].percent = 500 -- percent beyond 255 clamps through the alpha clamp
r, g, b, a = qwview.calcBlend(st)
t.check(a == 1, "blend: alpha clamps at 1")

--------------------------------------------------------------------------
-- CL_AddFlagModels: f-offset table + composition (fwd z reversed, +22
-- right, -16 z, roll -45). Zero angles: forward=(1,0,0), right=(0,-1,0).
local org, ang = qwview.flagPlacement(0, vector.zero, vector.zero)
t.check(org == vector.create(-14, -22, -16), "flag: base f=14 -> (-14,-22,-16) at zero angles")
t.check(ang == vector.create(0, 0, -45), "flag: roll -45")
org = qwview.flagPlacement(31, vector.zero, vector.zero)
t.check(org.x == -26, "flag: axpain frame 31 -> f=26")
org = qwview.flagPlacement(36, vector.zero, vector.zero)
t.check(org.x == -24, "flag: pain frame 36 -> f=24")
org = qwview.flagPlacement(104, vector.zero, vector.zero)
t.check(org.x == -20, "flag: nailattack frame 104 -> f=20")
org = qwview.flagPlacement(110, vector.zero, vector.zero)
t.check(org.x == -21, "flag: rocketattack frame 110 -> f=21")
org = qwview.flagPlacement(50, vector.zero, vector.zero)
t.check(org.x == -14, "flag: run frames keep f=14")
-- pitched carrier: the z reversal makes the flag ride UP a downward-pitched
-- forward vector (C's "reverse z component")
local fwd = mathlib.angleVectors(vector.create(30, 0, 0))
org = qwview.flagPlacement(0, vector.create(30, 0, 0), vector.zero)
t.check(approx(org.z, 14 * fwd.z - 16, 1e-4), "flag: pitched carrier z uses the REVERSED forward z (-f*(-fwd.z))")

--------------------------------------------------------------------------
-- CL_AllocExplosion ring: free slots first, then the oldest
local explosions: { qwview.Explosion? } = {}
for i = 1, 8 do
	local slot = qwview.allocExplosion(explosions, vector.create(i, 0, 0), i * 1.0)
	t.check(slot == i or i > 1, i == 1 and "explosion ring: free slots fill in order" or "")
end
t.check(#explosions == 8, "explosion ring: 8 slots filled")
local slot = qwview.allocExplosion(explosions, vector.create(9, 0, 0), 9.0)
t.check(slot == 1, "explosion ring: full -> oldest (start=1) replaced")
slot = qwview.allocExplosion(explosions, vector.create(10, 0, 0), 10.0)
t.check(slot == 2, "explosion ring: next-oldest replaced")

-- CL_UpdateExplosions frame math: f = floor(10*(time-start)), dies at numframes
local ex: qwview.Explosion = { origin = vector.zero, start = 5.0 }
t.check(qwview.explosionFrame(ex, 5.0, 6) == 0, "explosion frame: t=start -> frame 0")
t.check(qwview.explosionFrame(ex, 5.35, 6) == 3, "explosion frame: 10 Hz truncation")
t.check(qwview.explosionFrame(ex, 5.59, 6) == 5, "explosion frame: last frame at 0.59")
t.check(qwview.explosionFrame(ex, 5.65, 6) == nil, "explosion frame: expires at numframes")

-- CL_ClearTEnts zeroes both stores
local beams = { { entity = 1 } }
qwview.clearTEnts(beams, explosions)
t.check(#beams == 0 and next(explosions) == nil, "CL_ClearTEnts: beams + explosions cleared")

--------------------------------------------------------------------------
-- Sbar_SortFrags: frags descending, stable on ties, spectator handling
local slots: { qwview.ScoreSlot } = {
	{ name = "alpha", frags = 5 },
	{ name = "bravo", frags = 10 },
	{ name = "watcher", frags = 7, spectator = true },
	{ name = "", frags = 99 },
	{ name = "tied", frags = 5 },
}
local order = qwview.sortFrags(slots, false)
t.check(#order == 3, "sortFrags: empty + spectator slots excluded")
t.check(order[1] == 2 and order[2] == 1 and order[3] == 5, "sortFrags: descending, ties keep slot order")
t.check(slots[3].frags == 7, "sortFrags: excluded spectator keeps frags")
order = qwview.sortFrags(slots, true)
t.check(#order == 4 and order[4] == 3, "sortFrags: includespec appends the spectator last")
t.check(slots[3].frags == -999, "sortFrags: included spectator frags forced -999 (C quirk)")

--------------------------------------------------------------------------
-- Sbar_SortTeams: aggregation + ping low/high/total, teamplay gate
slots = {
	{ name = "r1", frags = 5, ping = 20, team = "red" },
	{ name = "b1", frags = 10, ping = 50, team = "blue" },
	{ name = "r2", frags = 3, ping = 80, team = "red" },
	{ name = "spec", frags = 50, ping = 10, team = "red", spectator = true },
	{ name = "lone", frags = 7, ping = 30, team = "" },
}
local teams = qwview.sortTeams(slots, 1)
t.check(#teams == 2, "sortTeams: spectators and teamless players excluded")
t.check(teams[1].team == "blue" and teams[1].frags == 10, "sortTeams: frags descending")
t.check(teams[2].team == "red" and teams[2].frags == 8 and teams[2].players == 2, "sortTeams: team frags/players aggregate")
t.check(teams[2].plow == 20 and teams[2].phigh == 80 and teams[2].ptotal == 100, "sortTeams: ping low/high/total")
t.check(#qwview.sortTeams(slots, 0) == 0, "sortTeams: teamplay 0 -> empty (C early-out)")

--------------------------------------------------------------------------
-- CL_NewTranslation table build (textures.translatePixels): shirt rows
-- 16-31 from top*16, pants 96-111 from bottom*16, backwards ranges (>=128)
-- reversed, everything else identity
local textures = require("../src/client/render/textures")
local pixels = buffer.create(256)
for i = 0, 255 do
	buffer.writeu8(pixels, i, i)
end
local out = textures.translatePixels(pixels, 256, 4 * 16 + 12) -- top 4, bottom 12
for i = 0, 15 do
	t.check(buffer.readu8(out, 16 + i) == 4 * 16 + i or i > 0, i == 0 and "translate: shirt row remaps forward from top*16" or "")
	-- bottom 12*16=192 >= 128: reversed
	t.check(buffer.readu8(out, 96 + i) == 12 * 16 + 15 - i or i > 0, i == 0 and "translate: pants row >=128 runs BACKWARDS" or "")
end
t.check(buffer.readu8(out, 16 + 5) == 4 * 16 + 5, "translate: shirt row offset 5")
t.check(buffer.readu8(out, 96 + 5) == 12 * 16 + 10, "translate: pants row offset 5 reversed")
t.check(buffer.readu8(out, 0) == 0 and buffer.readu8(out, 200) == 200, "translate: non-armor rows identity")

t.finish("test_qwview")
