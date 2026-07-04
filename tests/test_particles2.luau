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

t.finish("test_particles2")
