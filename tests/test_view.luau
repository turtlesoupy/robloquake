--!strict
-- view.c math vs hand-computed C truths: V_CalcRoll (cl_rollangle 2 /
-- cl_rollspeed 200), V_CalcBob (cl_bob .02 / cycle .6 / bobup .5),
-- V_CalcViewRoll (dmg kick decay, dead roll 80) and the V_CalcRefdef
-- composition (1/32 nudge, gun bob offsets, punch AFTER gun angles,
-- 80 u/s stair smoothing with the 12-unit cap).
local t = require("./testutil")
local view = require("../src/shared/engine/client/view")
local cllib = require("../src/shared/engine/client/cl")
local mathlib = require("../src/shared/engine/common/mathlib")

local function approx(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-5)
end

--------------------------------------------------------------------------
-- V_CalcRoll: side = dot(velocity, right); < 200 scales by 2/200, else 2
-- zero angles => right = (0,-1,0); yaw 90 => right = (1,0,0)
t.check(approx(view.calcRoll(vector.zero, vector.create(0, -100, 0)), 1), "calcRoll: side 100 -> 100*2/200 = 1")
t.check(approx(view.calcRoll(vector.zero, vector.create(0, 300, 0)), -2), "calcRoll: side -300 clamps to -cl_rollangle")
t.check(approx(view.calcRoll(vector.zero, vector.create(0, -200, 0)), 2), "calcRoll: side exactly 200 is NOT < rollspeed -> full 2")
t.check(approx(view.calcRoll(vector.create(0, 90, 0), vector.create(50, 0, 0)), 0.5), "calcRoll: yaw 90 right=(1,0,0), side 50 -> 0.5")
t.check(approx(view.calcRoll(vector.zero, vector.zero), 0), "calcRoll: at rest -> 0")

--------------------------------------------------------------------------
-- V_CalcBob truths (cycle = frac(time/.6); < .5 -> pi*cycle/.5):
--  time .15 -> cycle .25 -> sin(pi/2)=1;  time .45 -> sin(1.5pi)=-1
local function mockC(time: number, vel: vector)
	return {
		time = time,
		oldtime = time - 0.05,
		velocity = vel,
		viewangles = vector.zero,
		viewheight = 22,
		entities = { [1] = { origin = vector.zero, angles = vector.zero } },
		viewentity = 1,
		dmg_time = 0,
		dmg_roll = 0,
		dmg_pitch = 0,
		onground = false,
		punchangle = vector.zero,
		stats = { [cllib.STAT_HEALTH] = 100, [cllib.STAT_WEAPON] = 5, [cllib.STAT_WEAPONFRAME] = 2 },
	}
end
t.check(approx(view.calcBob(mockC(0.15, vector.create(300, 400, 0)) :: any), 4), "calcBob: speed 500*.02=10, peak sin -> clamped to 4")
t.check(approx(view.calcBob(mockC(0.45, vector.create(300, 400, 0)) :: any), -4), "calcBob: trough sin -> 3-7 = -4 (inside the -7 floor)")
t.check(approx(view.calcBob(mockC(0.15, vector.create(30, 40, 0)) :: any), 1), "calcBob: speed 50*.02=1 at peak -> .3+.7 = 1")
t.check(approx(view.calcBob(mockC(0.3, vector.create(30, 40, 0)) :: any), 0.3, 1e-4), "calcBob: cycle .5 -> sin(pi)=0 -> .3")

--------------------------------------------------------------------------
-- V_CalcRefdef composition
local c = mockC(0.15, vector.create(30, 40, 0)) :: any
c.viewangles = vector.create(10, 90, 0)
c.entities[1] = { origin = vector.create(100, 200, 24), angles = vector.create(0, 90, 0) }
view.resetOldz(24)
local rd = view.calcRefdef(c, 0.05)
local bob = 1 -- from the truth above
t.check(rd.vieworg == vector.create(100, 200, 24) + vector.create(1 / 32, 1 / 32, 22 + bob + 1 / 32), "refdef vieworg: origin + viewheight + bob + 1/32 nudge")
-- roll: ent yaw 90, vel (30,40,0) -> side = 30 -> 0.3
t.check(approx(rd.viewangles.z, 0.3), "refdef roll: V_CalcRoll folded into viewangles")
t.check(approx(rd.viewangles.x, 10) and approx(rd.viewangles.y, 90), "refdef pitch/yaw pass through")
t.check(rd.gunangles == vector.create(-10, 90, 0), "CalcGunAngle: gun pitch = -view pitch, roll dropped")
local fwd = mathlib.angleVectors(vector.create(10, 90, 0.3))
local wantGun = vector.create(100, 200, 24) + vector.create(0, 0, 22) + fwd * (bob * 0.4) + vector.create(0, 0, bob)
t.check(vector.magnitude(rd.gunorg - wantGun) < 1e-4, "gun origin: eye + forward*bob*.4 + z bob")
t.eq(rd.gunmodel, 5, "gunmodel from STAT_WEAPON")
t.eq(rd.gunframe, 2, "gunframe from STAT_WEAPONFRAME")

-- damage kick: roll += dmg_time/kicktime*dmg_roll, pitch likewise, decays
local c2 = mockC(0.15, vector.zero) :: any
c2.dmg_time = 0.4
c2.dmg_roll = 3
c2.dmg_pitch = 5
view.resetOldz(0)
local rd2 = view.calcRefdef(c2, 0.05)
t.check(approx(rd2.viewangles.z, 0.4 / 0.5 * 3), "dmg kick roll: dmg_time/v_kicktime * dmg_roll")
t.check(approx(rd2.viewangles.x, 0.4 / 0.5 * 5), "dmg kick pitch: dmg_time/v_kicktime * dmg_pitch")
t.check(approx(c2.dmg_time, 0.35), "dmg_time decays by frametime")

-- dead: roll pinned to 80
local c3 = mockC(0.15, vector.create(0, 300, 0)) :: any
c3.stats[cllib.STAT_HEALTH] = 0
view.resetOldz(0)
local rd3 = view.calcRefdef(c3, 0.05)
t.check(approx(rd3.viewangles.z, 80), "dead view: roll 80 replaces movement roll")

-- punchangle: added to viewangles AFTER the gun angles are taken
local c4 = mockC(0.15, vector.zero) :: any
c4.viewangles = vector.create(10, 0, 0)
c4.punchangle = vector.create(-5, 0, 0)
view.resetOldz(0)
local rd4 = view.calcRefdef(c4, 0.05)
t.check(approx(rd4.viewangles.x, 5), "punchangle added to refresh angles")
t.check(rd4.gunangles == vector.create(-10, 0, 0), "gun angles exclude punch (C adds punch after CalcGunAngle)")

--------------------------------------------------------------------------
-- stair smoothing: oldz glides up at 80 u/s, never lags more than 12
local c5 = mockC(0.15, vector.zero) :: any
c5.onground = true
c5.entities[1] = { origin = vector.create(0, 0, 0), angles = vector.zero }
view.resetOldz(0)
view.calcRefdef(c5, 0.05) -- flat: else-branch pins oldz to 0

c5.entities[1].origin = vector.create(0, 0, 16) -- step up 16
c5.time = 0.2
c5.oldtime = 0.15
local bob0 = view.calcBob(c5 :: any) -- vel zero -> 0
local rdA = view.calcRefdef(c5, 0.05)
-- steptime .05 * 80 = 4; 16-4=12 which is not > 12, so offset = 4-16 = -12
t.check(approx(rdA.vieworg.z, 16 + 22 + bob0 + 1 / 32 - 12), "stair glide frame 1: eye rides 12 below the step")
local rdB = view.calcRefdef(c5, 0.05)
-- oldz 4 -> 8: offset -8
t.check(approx(rdB.vieworg.z, 16 + 22 + bob0 + 1 / 32 - 8), "stair glide frame 2: 80 u/s advance")
c5.oldtime = c5.time - 1 -- huge step: oldz clamps to origin z
local rdC = view.calcRefdef(c5, 1)
t.check(approx(rdC.vieworg.z, 16 + 22 + bob0 + 1 / 32), "stair glide converges: oldz clamped at origin z")

-- big drop-off (not onground): oldz snaps, no glide
c5.onground = false
c5.entities[1].origin = vector.create(0, 0, 100)
local rdD = view.calcRefdef(c5, 0.05)
t.check(approx(rdD.vieworg.z, 100 + 22 + bob0 + 1 / 32), "airborne: no smoothing, oldz snaps")

--------------------------------------------------------------------------
-- V_ParseDamage over the wire: count = (blood+armor)*0.5 floored at 10,
-- faceanimtime +0.2, damage cshift += 3*count clamped 0..150 with the
-- armor/blood color split, and kicks = count*side*0.6 from the hit dir
local msg = require("../src/shared/engine/common/msg")
local proto = require("../src/shared/engine/protocol")

local pc = cllib.new("Tester", 0)
pc.print = function(_s: string) end
pc.time = 7
pc.viewentity = 1
pc.entities[1] = { origin = vector.create(0, 0, 0), angles = vector.zero } :: any

local function dmgMsg(armor: number, blood: number, from: vector): buffer
	local sb = msg.newBuf(64)
	msg.writeByte(sb, proto.svc_damage)
	msg.writeByte(sb, armor)
	msg.writeByte(sb, blood)
	msg.writeCoord(sb, from.x)
	msg.writeCoord(sb, from.y)
	msg.writeCoord(sb, from.z)
	local out = buffer.create(sb.cursize)
	buffer.copy(out, 0, sb.data, 0, sb.cursize)
	return out
end

-- blood-only hit from dead ahead: pitch kick, no roll
cllib.parseServerMessage(pc, dmgMsg(0, 40, vector.create(100, 0, 0)))
t.check(approx(pc.faceanimtime, 7.2), "V_ParseDamage: faceanimtime = time + 0.2")
t.check(approx(pc.cshift_damage_percent, 60), "damage cshift: += 3*count (count 20)")
t.check(pc.cshift_damage_color == vector.create(255, 0, 0), "blood-only hit shifts pure red")
t.check(approx(pc.dmg_pitch, 20 * 1 * 0.6), "pitch kick: count*side*v_kickpitch from a frontal hit")
t.check(approx(pc.dmg_roll, 0), "no roll kick from a frontal hit")
t.check(approx(pc.dmg_time, 0.5), "dmg_time = v_kicktime")

-- armor-dominant hit: (200,100,100); percent accumulates
cllib.parseServerMessage(pc, dmgMsg(30, 10, vector.create(100, 0, 0)))
t.check(pc.cshift_damage_color == vector.create(200, 100, 100), "armor>blood shifts (200,100,100)")
t.check(approx(pc.cshift_damage_percent, 120), "damage cshift accumulates")

-- small mixed hit from the right: count floors at 10, roll kick, clamp 150
cllib.parseServerMessage(pc, dmgMsg(5, 5, vector.create(0, -100, 0)))
t.check(pc.cshift_damage_color == vector.create(220, 50, 50), "some armor (not dominant) shifts (220,50,50)")
t.check(approx(pc.cshift_damage_percent, 150), "damage cshift clamps at 150")
t.check(approx(pc.dmg_roll, 10 * 1 * 0.6), "roll kick: count floored at 10, side from the right")


--------------------------------------------------------------------------
-- V_CalcPowerupCshift priority chain (view.c:442): quad > suit > invis
-- > invuln, with the C colors/percents
local IT_INVIS, IT_SUIT, IT_QUAD, IT_INVULN = 524288, 1048576, 2097152, 4194304
local function eqShift(a: { number }?, b: { number }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end
t.check(eqShift(view.powerupShift(IT_QUAD), { 0, 0, 255, 30 }), "powerup: quad blue 30")
t.check(eqShift(view.powerupShift(IT_SUIT), { 0, 255, 0, 20 }), "powerup: suit green 20")
t.check(eqShift(view.powerupShift(IT_INVIS), { 100, 100, 100, 100 }), "powerup: invisibility grey 100")
t.check(eqShift(view.powerupShift(IT_INVULN), { 255, 255, 0, 30 }), "powerup: invulnerability yellow 30")
t.check(eqShift(view.powerupShift(IT_QUAD + IT_SUIT + IT_INVULN), { 0, 0, 255, 30 }), "powerup: quad wins the priority chain")
t.check(eqShift(view.powerupShift(IT_SUIT + IT_INVIS), { 0, 255, 0, 20 }), "powerup: suit beats invisibility")
t.check(view.powerupShift(0) == nil, "powerup: none -> nil")

--------------------------------------------------------------------------
-- V_CalcBlend accumulation (view.c V_CalcBlend): a += a2*(1-a); colors
-- weighted a2/a. Hand-computed truths.
local r, g, b, a = view.calcBlend({ { 255, 0, 0, 128 } })
t.check(approx(a, 128 / 255) and approx(r, 255) and approx(g, 0), "blend: single shift passes through")
r, g, b, a = view.calcBlend({ { 255, 0, 0, 128 }, { 0, 0, 255, 64 } })
local a1, a2v = 128 / 255, 64 / 255
local wantA = a1 + a2v * (1 - a1)
local w2 = a2v / wantA
t.check(approx(a, wantA), "blend: two-shift alpha accumulates a2*(1-a)")
t.check(approx(r, 255 * (1 - w2)) and approx(b, 255 * w2), "blend: colors weighted a2/a")
r, g, b, a = view.calcBlend({})
t.check(a == 0, "blend: empty -> transparent")

--------------------------------------------------------------------------
-- V_DriftPitch / V_StartPitchDrift / V_StopPitchDrift (view.c):
-- pitchvel accelerates at v_centerspeed 500, exact overshoot clamp,
-- forward running re-arms after v_centermove 0.15s
local d = view.newPitchDrift()
t.check(not d.nodrift and d.pitchvel == 0, "drift: C cl struct starts zeroed (drifting armed)")

-- accelerating glide toward idealpitch 10: move uses the OLD pitchvel
local p = view.driftPitch(d, 0.1, 0, 10, 0.1, true, 0)
t.check(p == 0 and approx(d.pitchvel, 50), "drift: first frame moves 0, pitchvel += ft*500")
p = view.driftPitch(d, 0.2, p, 10, 0.1, true, 0)
t.check(approx(p, 5) and approx(d.pitchvel, 100), "drift: second frame moves ft*pitchvel = 5")
p = view.driftPitch(d, 0.3, p, 10, 0.1, true, 0)
t.check(p == 10 and d.pitchvel == 0, "drift: overshoot clamps exactly at idealpitch, pitchvel 0")
p = view.driftPitch(d, 0.4, p, 10, 0.1, true, 0)
t.check(p == 10 and d.pitchvel == 0, "drift: zero delta keeps pitchvel 0")

-- negative delta drifts down symmetrically (move must EXCEED -delta to
-- clamp — C uses strict >)
d = view.newPitchDrift()
d.pitchvel = 200
p = view.driftPitch(d, 0.1, 5, -5, 0.1, true, 0)
t.check(approx(p, -5) and d.pitchvel == 0, "drift: negative delta clamps at idealpitch from above")

-- not onground resets the accumulators and leaves pitch alone
d.pitchvel = 100
d.driftmove = 0.1
p = view.driftPitch(d, 0.2, 3, 0, 0.1, false, 400)
t.check(p == 3 and d.pitchvel == 0 and d.driftmove == 0, "drift: airborne resets pitchvel/driftmove")

-- stop + re-arm: sustained forward running (>= cl_forwardspeed 200)
-- accumulates driftmove past v_centermove 0.15 and restarts the drift
d = view.newPitchDrift()
view.stopPitchDrift(d, 1.0)
t.check(d.nodrift and d.pitchvel == 0 and d.laststop == 1.0, "stopPitchDrift: nodrift + laststop stamped")
p = view.driftPitch(d, 1.1, 7, 0, 0.1, true, 100)
t.check(d.driftmove == 0 and p == 7, "drift re-arm: slow forwardmove resets driftmove")
view.driftPitch(d, 1.2, 7, 0, 0.1, true, 200)
t.check(approx(d.driftmove, 0.1) and d.nodrift, "drift re-arm: running accumulates driftmove")
view.driftPitch(d, 1.3, 7, 0, 0.1, true, 200)
t.check(not d.nodrift and d.pitchvel == 500, "drift re-arm: driftmove > 0.15 restarts (pitchvel = v_centerspeed)")

-- laststop == time guard: something else is keeping it from drifting
d = view.newPitchDrift()
view.stopPitchDrift(d, 2.0)
view.startPitchDrift(d, 2.0)
t.check(d.nodrift, "startPitchDrift: refused when stopped the same frame")
view.startPitchDrift(d, 2.1)
t.check(not d.nodrift and d.pitchvel == 500, "startPitchDrift: arms on a later frame")

-- mouselook suppression (C IN_MouseMove): under +mlook, StopPitchDrift
-- fires every frame even with zero mouse delta, so the driftmove re-arm
-- path hits the laststop==time guard and the view NEVER recenters while
-- running forward — regression test for the keyboard-look port breaking
-- mouselook by only stopping on actual pitch changes
d = view.newPitchDrift()
local mp = 7
for i = 1, 10 do
	local mt = 3.0 + i * 0.1
	view.stopPitchDrift(d, mt) -- per-frame, as IN_MouseMove does under mlook
	mp = view.driftPitch(d, mt, mp, 0, 0.1, true, 400)
end
t.check(mp == 7 and d.nodrift, "drift under mlook: per-frame stop keeps pitch pinned despite running")

--------------------------------------------------------------------------
-- V_AddIdle (view.c cvar defaults: cycles 1/2/0.5, levels 0.3/0.3/0.1)
local ip, iy, ir = view.addIdle(1.0, 1)
t.check(approx(ip, math.sin(1.0) * 0.3), "addIdle: pitch sin(t*1)*0.3")
t.check(approx(iy, math.sin(2.0) * 0.3), "addIdle: yaw sin(t*2)*0.3")
t.check(approx(ir, math.sin(0.5) * 0.1), "addIdle: roll sin(t*0.5)*0.1")
ip, iy, ir = view.addIdle(1.0, 0.5)
t.check(approx(ip, math.sin(1.0) * 0.15), "addIdle: scales by v_idlescale")

--------------------------------------------------------------------------
-- V_BoundOffsets: eye clamped to +/-14 laterally, -22/+30 vertically
local bo = view.boundOffsets(vector.create(100, -100, 100), vector.create(0, 0, 0))
t.check(bo == vector.create(14, -14, 30), "boundOffsets: clamps to +14/-14/+30")
bo = view.boundOffsets(vector.create(0, 0, -100), vector.create(0, 0, 0))
t.check(bo.z == -22, "boundOffsets: floor at -22")
bo = view.boundOffsets(vector.create(1 / 32, 1 / 32, 22), vector.create(0, 0, 0))
t.check(bo == vector.create(1 / 32, 1 / 32, 22), "boundOffsets: normal eye passes through")

--------------------------------------------------------------------------
-- V_CalcIntermissionRefdef: view pinned to the view entity, gun hidden,
-- idle sway forced to scale 1
local mc: any = {
	entities = { [7] = { origin = vector.create(10, 20, 30), angles = vector.create(5, 15, 0) } },
	viewentity = 7,
	viewangles = vector.create(99, 99, 99),
	time = 1.0,
	intermission = 1,
}
local rd = view.calcIntermissionRefdef(mc)
t.check(rd.vieworg == vector.create(10, 20, 30), "intermission: vieworg = ent origin (no viewheight/bob)")
t.check(rd.gunmodel == 0, "intermission: view model hidden")
ip, iy, ir = view.addIdle(1.0, 1)
t.check(approx(rd.viewangles.x, 5 + ip) and approx(rd.viewangles.y, 15 + iy) and approx(rd.viewangles.z, ir), "intermission: ent angles + full idle sway")

t.finish("test_view")
