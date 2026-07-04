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

t.finish("test_view")
