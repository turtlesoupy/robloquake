--!strict
-- Validates R_ParticleExplosion2 and R_BlobExplosion against r_part.c: spawn
-- counts, color ranges, die times, particle types, and the pt_blob/pt_blob2
-- update physics — all on the headless sim core (particlesim.luau).

local t = require("./testutil")
local sim = require("../src/client/render/particlesim")

--------------------------------------------------------------------------
-- R_ParticleExplosion2: 512 particles, color colorStart + (i % colorLength),
-- die = time + 0.3, all pt_blob, org ±16, vel ±256

local org = vector.create(100, 200, 300)
local time = 10
local colorStart, colorLength = 64, 4

local s = sim.new()
sim.particleExplosion2(s, org, colorStart, colorLength, time)

local alive = 0
for i, p in s.pool do
	if not p.alive then
		continue
	end
	alive += 1
	t.eq(p.type, sim.pt_blob, `explosion2 particle {i} type`)
	t.eq(p.die, time + 0.3, `explosion2 particle {i} die`)
	t.eq(p.color, colorStart + (i - 1) % colorLength, `explosion2 particle {i} color`)
	t.check(p.color >= colorStart and p.color < colorStart + colorLength, `explosion2 particle {i} color range`)
	local d = p.org - org
	t.check(d.x >= -16 and d.x < 16 and d.y >= -16 and d.y < 16 and d.z >= -16 and d.z < 16, `explosion2 particle {i} org offset`)
	t.check(
		p.vel.x >= -256 and p.vel.x < 256 and p.vel.y >= -256 and p.vel.y < 256 and p.vel.z >= -256 and p.vel.z < 256,
		`explosion2 particle {i} vel range`
	)
end
t.eq(alive, 512, "explosion2 spawns 512 particles")

--------------------------------------------------------------------------
-- R_BlobExplosion: 1024 particles, odd i (0-based) pt_blob color 66+rand%6,
-- even i pt_blob2 color 150+rand%6, die = time + 1 + (rand()&8)*0.05

s = sim.new()
sim.blobExplosion(s, org, time)

local nBlob, nBlob2 = 0, 0
for i, p in s.pool do
	t.check(p.alive, `blob particle {i} alive`)
	local ci = i - 1 -- C loop index
	if ci % 2 == 1 then
		nBlob += 1
		t.eq(p.type, sim.pt_blob, `blob particle {i} type`)
		t.check(p.color >= 66 and p.color < 72, `blob particle {i} color range`)
	else
		nBlob2 += 1
		t.eq(p.type, sim.pt_blob2, `blob particle {i} type`)
		t.check(p.color >= 150 and p.color < 156, `blob particle {i} color range`)
	end
	-- (rand()&8)*0.05 is either 0 or 0.4
	t.check(p.die == time + 1 or p.die == time + 1 + 8 * 0.05, `blob particle {i} die`)
	local d = p.org - org
	t.check(d.x >= -16 and d.x < 16 and d.y >= -16 and d.y < 16 and d.z >= -16 and d.z < 16, `blob particle {i} org offset`)
end
t.eq(nBlob, 512, "blob population (pt_blob)")
t.eq(nBlob2, 512, "blob2 population (pt_blob2)")

--------------------------------------------------------------------------
-- pt_blob / pt_blob2 physics: blob accelerates on all axes (vel += vel*dvel)
-- and falls; blob2 decelerates on x/y only (vel -= vel*dvel) and falls

local frametime = 0.1
local dvel = 4 * frametime
local grav = frametime * 800 * 0.05

local before: { vector } = {}
for i, p in s.pool do
	before[i] = p.vel
end
sim.update(s, time, frametime)
for i, p in s.pool do
	local v = before[i]
	if p.type == sim.pt_blob then
		t.check(
			math.abs(p.vel.x - (v.x + v.x * dvel)) < 1e-3
				and math.abs(p.vel.y - (v.y + v.y * dvel)) < 1e-3
				and math.abs(p.vel.z - (v.z + v.z * dvel - grav)) < 1e-3,
			`pt_blob physics particle {i}`
		)
	else
		t.check(
			math.abs(p.vel.x - (v.x - v.x * dvel)) < 1e-3
				and math.abs(p.vel.y - (v.y - v.y * dvel)) < 1e-3
				and math.abs(p.vel.z - (v.z - grav)) < 1e-3,
			`pt_blob2 physics particle {i}`
		)
	end
end

-- particles expire: everything is dead after die times pass
sim.update(s, time + 2, frametime)
for i, p in s.pool do
	t.check(not p.alive, `blob particle {i} expired`)
end

--------------------------------------------------------------------------
-- R_EntityParticles: 162 anorm particles, color 0x6f, die time+0.01,
-- org on a shell dist 64 + beamlength-16 forward wobble
local s2 = sim.new()
local eorg = vector.create(0, 0, 0)
sim.entityParticles(s2, eorg, time)
local ecount = 0
local eOk = true
for _, p in s2.pool do
	if not p.alive then
		continue
	end
	ecount += 1
	if p.color ~= 0x6f or p.die ~= time + 0.01 then
		eOk = false
	end
	local d = vector.magnitude(p.org - eorg)
	if d < 64 - 16 - 0.01 or d > 64 + 16 + 0.01 then
		eOk = false
	end
end
t.eq(ecount, 162, "entityParticles spawns one per vertex normal (162)")
t.check(eOk, "entityParticles color 0x6f, die +0.01, orgs on the 64±16 shell")

--------------------------------------------------------------------------
-- R_TeleportSplash: 8x8x14 grid = 896 particles, color 7+(rand&7),
-- die in [t+0.2, t+0.34], vel = normalize(j*8,i*8,k*8) * (50+(rand&63)).
-- Pollute the pool first so stale velocities would be caught (the C
-- normalizes a zero dir to zero and always writes vel).
local s3 = sim.new()
sim.blobExplosion(s3, vector.create(0, 0, 0), 0)
sim.update(s3, 100, 0.05) -- expire everything, leaving stale vels in the pool
local torg = vector.create(50, 60, 70)
sim.teleportSplash(s3, torg, time)
local tcount = 0
local tOk = true
for _, p in s3.pool do
	if not p.alive then
		continue
	end
	tcount += 1
	if p.color < 7 or p.color > 14 then
		tOk = false
	end
	if p.die < time + 0.2 - 1e-9 or p.die > time + 0.34 + 1e-9 then
		tOk = false
	end
	local off = p.org - torg
	if math.abs(off.x) > 19 or math.abs(off.y) > 19 or math.abs(off.z) > 31 then
		tOk = false
	end
	-- f32 vectors (like C's vec3_t): tolerance at single precision
	local speed = vector.magnitude(p.vel)
	if speed > 0 then
		if speed < 50 - 1e-3 or speed > 113 + 1e-3 then
			tOk = false
		end
	end
end
t.eq(tcount, 896, "teleportSplash spawns the full -16..12 / -24..28 grid (896)")
t.check(tOk, "teleportSplash colors 7..14, die window, org jitter bounds, speeds 50..113")
local center = false
for _, p in s3.pool do
	if p.alive and vector.magnitude(p.vel) == 0 then
		center = true
	end
end
t.check(center, "the zero-dir center particle has zero velocity (stale pool vel would leak here)")

--------------------------------------------------------------------------
-- R_RocketTrail type 0: len/3 particles, die +2, color from ramp3[0..3]
-- = {0x6d, 0x6b, 6, 5}, org jitter ±3 around the advancing point (C
-- advances start by the NORMALIZED vec — 1 unit — per 3-unit len step)
local s4 = sim.new()
local rstart = vector.create(0, 0, 0)
local rend = vector.create(90, 0, 0)
sim.rocketTrail(s4, rstart, rend, 0, time)
local ramp3set = { [0x6d] = true, [0x6b] = true, [6] = true, [5] = true }
local rcount = 0
local rOk = true
for _, p in s4.pool do
	if not p.alive then
		continue
	end
	rcount += 1
	if not ramp3set[p.color] or p.die ~= time + 2 then
		rOk = false
	end
	-- authentic quirk: start advances 1 unit per 3-unit len decrement,
	-- so 30 particles cover only the first 30 units (+/-3 jitter)
	if p.org.x < -3.01 or p.org.x > 33.01 or math.abs(p.org.y) > 3.01 or math.abs(p.org.z) > 3.01 then
		rOk = false
	end
end
t.eq(rcount, 30, "rocketTrail: len 90 / dec 3 = 30 particles")
t.check(rOk, "rocketTrail ramp3 colors, die +2, orgs hug the first third of the segment (authentic quirk)")

--------------------------------------------------------------------------
-- R_ParticleExplosion (r_part.c): 1024 particles, die +5, color ramp1[0]
-- = 0x6f, ramp rand&3, types alternate pt_explode/pt_explode2 on i&1,
-- org ±16 (rand%32-16), vel ±256 (rand%512-256). Port delta noted on the
-- row: C interleaves org[j]/vel[j] rand() draws, the port draws org's
-- three then vel's three — same distribution, different rand order.
local s5 = sim.new()
sim.explosion(s5, vector.create(100, 200, 300), time)
local e1, e2, eOk = 0, 0, true
for _, p in s5.pool do
	if not p.alive then
		continue
	end
	if p.type == sim.pt_explode then
		e1 += 1
	elseif p.type == sim.pt_explode2 then
		e2 += 1
	else
		eOk = false
	end
	if p.color ~= 0x6f or p.die ~= time + 5 or p.ramp < 0 or p.ramp > 3 then
		eOk = false
	end
	local d = p.org - vector.create(100, 200, 300)
	if d.x < -16 or d.x >= 16 or d.y < -16 or d.y >= 16 or d.z < -16 or d.z >= 16 then
		eOk = false
	end
	if p.vel.x < -256 or p.vel.x >= 256 or p.vel.y < -256 or p.vel.y >= 256 or p.vel.z < -256 or p.vel.z >= 256 then
		eOk = false
	end
end
t.eq(e1 + e2, 1024, "explosion spawns 1024 particles")
t.eq(e1, 512, "explosion: 512 pt_explode (odd i)")
t.eq(e2, 512, "explosion: 512 pt_explode2 (even i)")
t.check(eOk, "explosion: color ramp1[0]=0x6f, die +5, ramp 0..3, org ±16, vel ±256")

--------------------------------------------------------------------------
-- R_RunParticleEffect: die 0.1*(rand%5), color (c&~7)+(rand&7),
-- pt_slowgrav, org ±8 (rand&15-8), vel = dir*15 exactly; count==1024
-- takes the rocket-explosion branch (same fields as R_ParticleExplosion)
local s6 = sim.new()
local rdir = vector.create(0, 0, -1)
sim.runEffect(s6, vector.create(10, 20, 30), rdir, 73, 20, time)
local rc, rOk2 = 0, true
for _, p in s6.pool do
	if not p.alive then
		continue
	end
	rc += 1
	local dieOk = false
	for k = 0, 4 do
		if math.abs(p.die - (time + 0.1 * k)) < 1e-9 then
			dieOk = true
		end
	end
	if not dieOk then
		rOk2 = false
	end
	if p.color < 72 or p.color > 79 or p.type ~= sim.pt_slowgrav then
		rOk2 = false -- 73 & ~7 = 72, + rand&7
	end
	local d = p.org - vector.create(10, 20, 30)
	if d.x < -8 or d.x >= 8 or d.y < -8 or d.y >= 8 or d.z < -8 or d.z >= 8 then
		rOk2 = false
	end
	if p.vel ~= rdir * 15 then
		rOk2 = false
	end
end
t.eq(rc, 20, "runEffect spawns count particles")
t.check(rOk2, "runEffect: die 0.1*(rand%5), color 72..79 for base 73, pt_slowgrav, org ±8, vel dir*15")

local s7 = sim.new()
sim.runEffect(s7, vector.zero, vector.zero, 0, 1024, time)
local rc2, expl = 0, true
for _, p in s7.pool do
	if p.alive then
		rc2 += 1
		if p.die ~= time + 5 or p.color ~= 0x6f then
			expl = false
		end
	end
end
t.eq(rc2, 1024, "runEffect count=1024 takes the rocket-explosion branch")
t.check(expl, "runEffect 1024-branch fields match R_ParticleExplosion (die +5, ramp1[0])")

-- QW variant (QW/client/r_part.c): count-based org-spread scale — >130 →
-- 3, >20 → 2, else 1. Same die/color/vel; pt_grav there is physics-
-- identical to pt_slowgrav (stock WinQuake fall-through).
for _, case_ in { { count = 10, scale = 1 }, { count = 50, scale = 2 }, { count = 200, scale = 3 } } do
	local sq = sim.new()
	sim.runEffect(sq, vector.zero, vector.zero, 0, case_.count, time, true)
	local maxAbs, alive = 0, 0
	for _, p in sq.pool do
		if p.alive then
			alive += 1
			maxAbs = math.max(maxAbs, math.abs(p.org.x), math.abs(p.org.y), math.abs(p.org.z))
		end
	end
	t.eq(alive, case_.count, `qw runEffect count {case_.count} spawns`)
	t.check(maxAbs <= 8 * case_.scale, `qw runEffect count {case_.count} spread within ±{8 * case_.scale} (scale {case_.scale})`)
	t.check(maxAbs > 8 * (case_.scale - 1), `qw runEffect count {case_.count} actually uses scale {case_.scale}`)
end

--------------------------------------------------------------------------
-- R_LavaSplash: 32x32 grid (i,j in -16..15, k single pass), die
-- 2+(rand&31)*0.02, color 224+(rand&7), pt_slowgrav, org xy = grid*8 +
-- rand&7, org z + rand&63, vel = normalize(dir)*(50+(rand&63)) with
-- dir = (j*8+r, i*8+r, 256) — vel points up and |vel| in [50,113]
local s8 = sim.new()
local lorg = vector.create(-100, -200, 50)
sim.lavaSplash(s8, lorg, time)
local lc, lOk = 0, true
for _, p in s8.pool do
	if not p.alive then
		continue
	end
	lc += 1
	if p.color < 224 or p.color > 231 or p.type ~= sim.pt_slowgrav then
		lOk = false
	end
	if p.die < time + 2 - 1e-9 or p.die > time + 2 + 31 * 0.02 + 1e-9 then
		lOk = false
	end
	local d = p.org - lorg
	if d.x < -128 or d.x > 127 + 7 or d.y < -128 or d.y > 127 + 7 or d.z < 0 or d.z > 63 then
		lOk = false
	end
	local speed = vector.magnitude(p.vel)
	-- vectors are float32: allow 1e-3 slop on the [50,113] speed window
	if p.vel.z <= 0 or speed < 50 - 1e-3 or speed > 113 + 1e-3 then
		lOk = false
	end
	-- dir.z is always 256 with |dir.xy| <= ~191, so the pitch is steep:
	-- vel.z must dominate each horizontal component
	if math.abs(p.vel.x) > p.vel.z or math.abs(p.vel.y) > p.vel.z then
		lOk = false
	end
end
t.eq(lc, 1024, "lavaSplash spawns the full 32x32 grid")
t.check(lOk, "lavaSplash: color 224+&7, die 2..2.62, pt_slowgrav, grid orgs, up-dominant vel 50..113")

--------------------------------------------------------------------------
-- R_ParseParticleEffect (svc_particle wire parse): org coords, dir
-- chars/16, count byte with the 255→1024 rocket-explosion escape, color
local cllib = require("../src/shared/engine/client/cl")
local msg = require("../src/shared/engine/common/msg")
local proto = require("../src/shared/engine/protocol")

local pc = cllib.new("Tester", 0)
pc.print = function(_s: string) end
local got: { any } = {}
pc.onParticle = function(_c, org: vector, dir: vector, color: number, count: number)
	table.insert(got, { org = org, dir = dir, color = color, count = count })
end
local function particleMsg(count: number): buffer
	local sb = msg.newBuf(64)
	msg.writeByte(sb, proto.svc_particle)
	msg.writeCoord(sb, 24.5)
	msg.writeCoord(sb, -100)
	msg.writeCoord(sb, 3)
	msg.writeChar(sb, 16) -- dir/16 = 1
	msg.writeChar(sb, -8) -- -0.5
	msg.writeChar(sb, 0)
	msg.writeByte(sb, count)
	msg.writeByte(sb, 73)
	local out = buffer.create(sb.cursize)
	buffer.copy(out, 0, sb.data, 0, sb.cursize)
	return out
end
cllib.parseServerMessage(pc, particleMsg(30))
cllib.parseServerMessage(pc, particleMsg(255))
--------------------------------------------------------------------------
-- R_DrawParticles physics for the remaining types (r_part.c switch):
-- pt_explode ramps ramp1 at time2=10/s and accelerates (vel += vel*dvel,
-- z -= grav); pt_explode2 ramps ramp2 at time3=15/s and drags (vel -=
-- vel*frametime); pt_fire ramps ramp3 at time1=5/s and RISES (z += grav);
-- pt_grav falls through to pt_slowgrav in stock WinQuake (plain grav —
-- the grav*20 variant is #ifdef QUAKE2; QW writes plain grav too)
local s9 = sim.new()
sim.explosion(s9, vector.zero, time) -- pt_explode/pt_explode2 with ramp 0..3
local pre: { { vel: vector, ramp: number } } = {}
for i, p in s9.pool do
	pre[i] = { vel = p.vel, ramp = p.ramp }
end
local ft = 0.1
local grav2 = ft * 800 * 0.05
local dvel2 = 4 * ft
local ramp1 = { 0x6f, 0x6d, 0x6b, 0x69, 0x67, 0x65, 0x63, 0x61 }
local ramp2 = { 0x6f, 0x6e, 0x6d, 0x6c, 0x6b, 0x6a, 0x68, 0x66 } -- verbatim r_part.c:30
sim.update(s9, time, ft)
local expOk = true
for i, p in s9.pool do
	local v, r0 = pre[i].vel, pre[i].ramp
	if p.type == sim.pt_explode then
		local want = r0 + ft * 10
		if math.abs(p.ramp - want) > 1e-6 or p.color ~= ramp1[math.floor(want) + 1] then
			expOk = false
		end
		if math.abs(p.vel.x - (v.x + v.x * dvel2)) > 1e-3 or math.abs(p.vel.z - (v.z + v.z * dvel2 - grav2)) > 1e-3 then
			expOk = false
		end
	elseif p.type == sim.pt_explode2 then
		local want = r0 + ft * 15
		if math.abs(p.ramp - want) > 1e-6 or p.color ~= ramp2[math.floor(want) + 1] then
			expOk = false
		end
		if math.abs(p.vel.x - (v.x - v.x * ft)) > 1e-3 or math.abs(p.vel.z - (v.z - v.z * ft - grav2)) > 1e-3 then
			expOk = false
		end
	end
end
t.check(expOk, "pt_explode/pt_explode2 physics: ramp1@10/s + dvel accel, ramp2@15/s + frametime drag, both -grav")

-- pt_slowgrav and pt_grav: identical plain-grav fall (WinQuake fall-through)
local s10 = sim.new()
sim.runEffect(s10, vector.zero, vector.create(1, 0, 0), 0, 2, time) -- pt_slowgrav, vel (15,0,0)
local pg
for _, p in s10.pool do
	if p.alive then
		pg = p
		break
	end
end
assert(pg)
pg.type = sim.pt_grav
pg.die = time + 99
sim.update(s10, time, ft)
t.check(math.abs(pg.vel.z - -grav2) < 1e-4 and pg.vel.x == 15, "pt_grav falls at plain grav (stock WinQuake fall-through, not the QUAKE2 grav*20)")

t.eq(#got, 2, "svc_particle parsed twice")
t.check(got[1].org == vector.create(24.5, -100, 3), "svc_particle org coords")
t.check(got[1].dir == vector.create(1, -0.5, 0), "svc_particle dir chars * 1/16")
t.eq(got[1].color, 73, "svc_particle color byte")
t.eq(got[1].count, 30, "svc_particle plain count passes through")
t.eq(got[2].count, 1024, "svc_particle count 255 -> 1024 rocket-explosion escape (R_ParseParticleEffect)")

t.finish("test_particles2")
