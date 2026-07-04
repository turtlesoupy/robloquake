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

t.finish("test_particles2")
