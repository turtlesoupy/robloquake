--!strict
--!optimize 2
-- Particle simulation — the pure-state half of WinQuake r_part.c: the
-- particle pool, effect spawners (R_RunParticleEffect, R_ParticleExplosion,
-- R_ParticleExplosion2, R_BlobExplosion, R_TeleportSplash, R_LavaSplash,
-- R_EntityParticles, R_RocketTrail) and the R_DrawParticles physics switch.
-- No Roblox APIs so lune tests can drive it headless; particles.luau wraps
-- it with the Part-based renderer.

local particlesim = {}

local MAX_PARTICLES = 1024
local GRAVITY = 800 -- sv_gravity
particlesim.MAX_PARTICLES = MAX_PARTICLES

-- color ramps (palette indices)
local ramp1 = { 0x6f, 0x6d, 0x6b, 0x69, 0x67, 0x65, 0x63, 0x61 }
local ramp2 = { 0x6f, 0x6e, 0x6d, 0x6c, 0x6b, 0x6a, 0x68, 0x66 }
local ramp3 = { 0x6d, 0x6b, 6, 5, 4, 3 }

-- particle types
local pt_static = 0
local pt_grav = 1
local pt_slowgrav = 2
local pt_fire = 3
local pt_explode = 4
local pt_explode2 = 5
local pt_blob = 6
local pt_blob2 = 7
particlesim.pt_static = pt_static
particlesim.pt_grav = pt_grav
particlesim.pt_slowgrav = pt_slowgrav
particlesim.pt_fire = pt_fire
particlesim.pt_explode = pt_explode
particlesim.pt_explode2 = pt_explode2
particlesim.pt_blob = pt_blob
particlesim.pt_blob2 = pt_blob2

export type Particle = {
	alive: boolean,
	org: vector,
	vel: vector,
	color: number,
	ramp: number,
	die: number,
	type: number,
}

export type System = {
	pool: { Particle },
	nextIdx: number,
}

function particlesim.new(): System
	local pool: { Particle } = table.create(MAX_PARTICLES)
	for i = 1, MAX_PARTICLES do
		pool[i] = {
			alive = false,
			org = vector.zero,
			vel = vector.zero,
			color = 0,
			ramp = 0,
			die = -1,
			type = pt_static,
		}
	end
	return { pool = pool, nextIdx = 1 }
end

-- allocate the next particle (round-robin like the free list, close enough)
local function alloc(sys: System): Particle
	local p = sys.pool[sys.nextIdx]
	sys.nextIdx = sys.nextIdx % MAX_PARTICLES + 1
	p.alive = true
	p.ramp = 0
	return p
end

local rngState = 12345
local function rand(): number -- rand() & 0x7fff
	rngState = (rngState * 214013 + 2531011) % 4294967296
	return bit32.band(bit32.rshift(rngState, 16), 0x7fff)
end

--------------------------------------------------------------------------
-- effect spawners

-- R_ParticleExplosion
function particlesim.explosion(sys: System, org: vector, time: number)
	for i = 0, 1023 do
		local p = alloc(sys)
		p.die = time + 5
		p.color = ramp1[1]
		p.ramp = bit32.band(rand(), 3)
		p.type = if i % 2 == 1 then pt_explode else pt_explode2
		p.org = org + vector.create(rand() % 32 - 16, rand() % 32 - 16, rand() % 32 - 16)
		p.vel = vector.create(rand() % 512 - 256, rand() % 512 - 256, rand() % 512 - 256)
	end
end

-- R_ParticleExplosion2
function particlesim.particleExplosion2(sys: System, org: vector, colorStart: number, colorLength: number, time: number)
	local colorMod = 0
	for _ = 0, 511 do
		local p = alloc(sys)
		p.die = time + 0.3
		p.color = colorStart + colorMod % colorLength
		colorMod += 1
		p.type = pt_blob
		p.org = org + vector.create(rand() % 32 - 16, rand() % 32 - 16, rand() % 32 - 16)
		p.vel = vector.create(rand() % 512 - 256, rand() % 512 - 256, rand() % 512 - 256)
	end
end

-- R_BlobExplosion
function particlesim.blobExplosion(sys: System, org: vector, time: number)
	for i = 0, 1023 do
		local p = alloc(sys)
		p.die = time + 1 + bit32.band(rand(), 8) * 0.05
		if i % 2 == 1 then
			p.type = pt_blob
			p.color = 66 + rand() % 6
		else
			p.type = pt_blob2
			p.color = 150 + rand() % 6
		end
		p.org = org + vector.create(rand() % 32 - 16, rand() % 32 - 16, rand() % 32 - 16)
		p.vel = vector.create(rand() % 512 - 256, rand() % 512 - 256, rand() % 512 - 256)
	end
end

-- R_RunParticleEffect (blood, gunshot sparks, etc.)
function particlesim.runEffect(sys: System, org: vector, dir: vector, color: number, count: number, time: number)
	if count == 1024 then
		particlesim.explosion(sys, org, time)
		return
	end
	for _ = 1, count do
		local p = alloc(sys)
		p.die = time + 0.1 * (rand() % 5)
		p.color = bit32.band(color, bit32.bnot(7)) + bit32.band(rand(), 7)
		p.type = pt_slowgrav
		p.org = org + vector.create(rand() % 16 - 8, rand() % 16 - 8, rand() % 16 - 8)
		p.vel = dir * 15
	end
end

-- R_RocketTrail: type 0 rocket, 1 grenade smoke, 2 blood, 3/5 tracer,
-- 4 slight blood, 6 voor trail
local tracercount = 0
function particlesim.rocketTrail(sys: System, start: vector, endp: vector, ttype: number, time: number)
	local vec = endp - start
	local len = vector.magnitude(vec)
	if len > 0 then
		vec = vec / len
	end
	local dec = 3
	if ttype >= 128 then
		dec = 1
		ttype -= 128
	end

	while len > 0 do
		len -= dec

		local p = alloc(sys)
		p.vel = vector.zero
		p.die = time + 2

		if ttype == 0 then -- rocket trail
			p.ramp = bit32.band(rand(), 3)
			p.color = ramp3[p.ramp + 1]
			p.type = pt_fire
			p.org = start + vector.create(rand() % 6 - 3, rand() % 6 - 3, rand() % 6 - 3)
		elseif ttype == 1 then -- smoke smoke
			p.ramp = bit32.band(rand(), 3) + 2
			p.color = ramp3[p.ramp + 1]
			p.type = pt_fire
			p.org = start + vector.create(rand() % 6 - 3, rand() % 6 - 3, rand() % 6 - 3)
		elseif ttype == 2 then -- blood
			p.type = pt_grav
			p.color = 67 + bit32.band(rand(), 3)
			p.org = start + vector.create(rand() % 6 - 3, rand() % 6 - 3, rand() % 6 - 3)
		elseif ttype == 3 or ttype == 5 then -- tracer
			p.die = time + 0.5
			p.type = pt_static
			if ttype == 3 then
				p.color = 52 + bit32.lshift(bit32.band(tracercount, 4), 1)
			else
				p.color = 230 + bit32.lshift(bit32.band(tracercount, 4), 1)
			end
			tracercount += 1
			p.org = start
			if bit32.band(tracercount, 1) ~= 0 then
				p.vel = vector.create(30 * vec.y, 30 * -vec.x, 0)
			else
				p.vel = vector.create(30 * -vec.y, 30 * vec.x, 0)
			end
		elseif ttype == 4 then -- slight blood
			p.type = pt_grav
			p.color = 67 + bit32.band(rand(), 3)
			p.org = start + vector.create(rand() % 6 - 3, rand() % 6 - 3, rand() % 6 - 3)
			len -= 3
		elseif ttype == 6 then -- voor trail
			p.color = 9 * 16 + 8 + bit32.band(rand(), 3)
			p.type = pt_static
			p.die = time + 0.3
			p.org = start + vector.create(rand() % 16 - 8, rand() % 16 - 8, rand() % 16 - 8)
		end

		start += vec
	end
end

-- r_avertexnormals (anorms.h) for R_EntityParticles
local ANORMS = {
	vector.create(-0.525731, 0.000000, 0.850651),
	vector.create(-0.442863, 0.238856, 0.864188),
	vector.create(-0.295242, 0.000000, 0.955423),
	vector.create(-0.309017, 0.500000, 0.809017),
	vector.create(-0.162460, 0.262866, 0.951056),
	vector.create(0.000000, 0.000000, 1.000000),
	vector.create(0.000000, 0.850651, 0.525731),
	vector.create(-0.147621, 0.716567, 0.681718),
	vector.create(0.147621, 0.716567, 0.681718),
	vector.create(0.000000, 0.525731, 0.850651),
	vector.create(0.309017, 0.500000, 0.809017),
	vector.create(0.525731, 0.000000, 0.850651),
	vector.create(0.295242, 0.000000, 0.955423),
	vector.create(0.442863, 0.238856, 0.864188),
	vector.create(0.162460, 0.262866, 0.951056),
	vector.create(-0.681718, 0.147621, 0.716567),
	vector.create(-0.809017, 0.309017, 0.500000),
	vector.create(-0.587785, 0.425325, 0.688191),
	vector.create(-0.850651, 0.525731, 0.000000),
	vector.create(-0.864188, 0.442863, 0.238856),
	vector.create(-0.716567, 0.681718, 0.147621),
	vector.create(-0.688191, 0.587785, 0.425325),
	vector.create(-0.500000, 0.809017, 0.309017),
	vector.create(-0.238856, 0.864188, 0.442863),
	vector.create(-0.425325, 0.688191, 0.587785),
	vector.create(-0.716567, 0.681718, -0.147621),
	vector.create(-0.500000, 0.809017, -0.309017),
	vector.create(-0.525731, 0.850651, 0.000000),
	vector.create(0.000000, 0.850651, -0.525731),
	vector.create(-0.238856, 0.864188, -0.442863),
	vector.create(0.000000, 0.955423, -0.295242),
	vector.create(-0.262866, 0.951056, -0.162460),
	vector.create(0.000000, 1.000000, 0.000000),
	vector.create(0.000000, 0.955423, 0.295242),
	vector.create(-0.262866, 0.951056, 0.162460),
	vector.create(0.238856, 0.864188, 0.442863),
	vector.create(0.262866, 0.951056, 0.162460),
	vector.create(0.500000, 0.809017, 0.309017),
	vector.create(0.238856, 0.864188, -0.442863),
	vector.create(0.262866, 0.951056, -0.162460),
	vector.create(0.500000, 0.809017, -0.309017),
	vector.create(0.850651, 0.525731, 0.000000),
	vector.create(0.716567, 0.681718, 0.147621),
	vector.create(0.716567, 0.681718, -0.147621),
	vector.create(0.525731, 0.850651, 0.000000),
	vector.create(0.425325, 0.688191, 0.587785),
	vector.create(0.864188, 0.442863, 0.238856),
	vector.create(0.688191, 0.587785, 0.425325),
	vector.create(0.809017, 0.309017, 0.500000),
	vector.create(0.681718, 0.147621, 0.716567),
	vector.create(0.587785, 0.425325, 0.688191),
	vector.create(0.955423, 0.295242, 0.000000),
	vector.create(1.000000, 0.000000, 0.000000),
	vector.create(0.951056, 0.162460, 0.262866),
	vector.create(0.850651, -0.525731, 0.000000),
	vector.create(0.955423, -0.295242, 0.000000),
	vector.create(0.864188, -0.442863, 0.238856),
	vector.create(0.951056, -0.162460, 0.262866),
	vector.create(0.809017, -0.309017, 0.500000),
	vector.create(0.681718, -0.147621, 0.716567),
	vector.create(0.850651, 0.000000, 0.525731),
	vector.create(0.864188, 0.442863, -0.238856),
	vector.create(0.809017, 0.309017, -0.500000),
	vector.create(0.951056, 0.162460, -0.262866),
	vector.create(0.525731, 0.000000, -0.850651),
	vector.create(0.681718, 0.147621, -0.716567),
	vector.create(0.681718, -0.147621, -0.716567),
	vector.create(0.850651, 0.000000, -0.525731),
	vector.create(0.809017, -0.309017, -0.500000),
	vector.create(0.864188, -0.442863, -0.238856),
	vector.create(0.951056, -0.162460, -0.262866),
	vector.create(0.147621, 0.716567, -0.681718),
	vector.create(0.309017, 0.500000, -0.809017),
	vector.create(0.425325, 0.688191, -0.587785),
	vector.create(0.442863, 0.238856, -0.864188),
	vector.create(0.587785, 0.425325, -0.688191),
	vector.create(0.688191, 0.587785, -0.425325),
	vector.create(-0.147621, 0.716567, -0.681718),
	vector.create(-0.309017, 0.500000, -0.809017),
	vector.create(0.000000, 0.525731, -0.850651),
	vector.create(-0.525731, 0.000000, -0.850651),
	vector.create(-0.442863, 0.238856, -0.864188),
	vector.create(-0.295242, 0.000000, -0.955423),
	vector.create(-0.162460, 0.262866, -0.951056),
	vector.create(0.000000, 0.000000, -1.000000),
	vector.create(0.295242, 0.000000, -0.955423),
	vector.create(0.162460, 0.262866, -0.951056),
	vector.create(-0.442863, -0.238856, -0.864188),
	vector.create(-0.309017, -0.500000, -0.809017),
	vector.create(-0.162460, -0.262866, -0.951056),
	vector.create(0.000000, -0.850651, -0.525731),
	vector.create(-0.147621, -0.716567, -0.681718),
	vector.create(0.147621, -0.716567, -0.681718),
	vector.create(0.000000, -0.525731, -0.850651),
	vector.create(0.309017, -0.500000, -0.809017),
	vector.create(0.442863, -0.238856, -0.864188),
	vector.create(0.162460, -0.262866, -0.951056),
	vector.create(0.238856, -0.864188, -0.442863),
	vector.create(0.500000, -0.809017, -0.309017),
	vector.create(0.425325, -0.688191, -0.587785),
	vector.create(0.716567, -0.681718, -0.147621),
	vector.create(0.688191, -0.587785, -0.425325),
	vector.create(0.587785, -0.425325, -0.688191),
	vector.create(0.000000, -0.955423, -0.295242),
	vector.create(0.000000, -1.000000, 0.000000),
	vector.create(0.262866, -0.951056, -0.162460),
	vector.create(0.000000, -0.850651, 0.525731),
	vector.create(0.000000, -0.955423, 0.295242),
	vector.create(0.238856, -0.864188, 0.442863),
	vector.create(0.262866, -0.951056, 0.162460),
	vector.create(0.500000, -0.809017, 0.309017),
	vector.create(0.716567, -0.681718, 0.147621),
	vector.create(0.525731, -0.850651, 0.000000),
	vector.create(-0.238856, -0.864188, -0.442863),
	vector.create(-0.500000, -0.809017, -0.309017),
	vector.create(-0.262866, -0.951056, -0.162460),
	vector.create(-0.850651, -0.525731, 0.000000),
	vector.create(-0.716567, -0.681718, -0.147621),
	vector.create(-0.716567, -0.681718, 0.147621),
	vector.create(-0.525731, -0.850651, 0.000000),
	vector.create(-0.500000, -0.809017, 0.309017),
	vector.create(-0.238856, -0.864188, 0.442863),
	vector.create(-0.262866, -0.951056, 0.162460),
	vector.create(-0.864188, -0.442863, 0.238856),
	vector.create(-0.809017, -0.309017, 0.500000),
	vector.create(-0.688191, -0.587785, 0.425325),
	vector.create(-0.681718, -0.147621, 0.716567),
	vector.create(-0.442863, -0.238856, 0.864188),
	vector.create(-0.587785, -0.425325, 0.688191),
	vector.create(-0.309017, -0.500000, 0.809017),
	vector.create(-0.147621, -0.716567, 0.681718),
	vector.create(-0.425325, -0.688191, 0.587785),
	vector.create(-0.162460, -0.262866, 0.951056),
	vector.create(0.442863, -0.238856, 0.864188),
	vector.create(0.162460, -0.262866, 0.951056),
	vector.create(0.309017, -0.500000, 0.809017),
	vector.create(0.147621, -0.716567, 0.681718),
	vector.create(0.000000, -0.525731, 0.850651),
	vector.create(0.425325, -0.688191, 0.587785),
	vector.create(0.587785, -0.425325, 0.688191),
	vector.create(0.688191, -0.587785, 0.425325),
	vector.create(-0.955423, 0.295242, 0.000000),
	vector.create(-0.951056, 0.162460, 0.262866),
	vector.create(-1.000000, 0.000000, 0.000000),
	vector.create(-0.850651, 0.000000, 0.525731),
	vector.create(-0.955423, -0.295242, 0.000000),
	vector.create(-0.951056, -0.162460, 0.262866),
	vector.create(-0.864188, 0.442863, -0.238856),
	vector.create(-0.951056, 0.162460, -0.262866),
	vector.create(-0.809017, 0.309017, -0.500000),
	vector.create(-0.864188, -0.442863, -0.238856),
	vector.create(-0.951056, -0.162460, -0.262866),
	vector.create(-0.809017, -0.309017, -0.500000),
	vector.create(-0.681718, 0.147621, -0.716567),
	vector.create(-0.681718, -0.147621, -0.716567),
	vector.create(-0.850651, 0.000000, -0.525731),
	vector.create(-0.688191, 0.587785, -0.425325),
	vector.create(-0.587785, 0.425325, -0.688191),
	vector.create(-0.425325, 0.688191, -0.587785),
	vector.create(-0.425325, -0.688191, -0.587785),
	vector.create(-0.587785, -0.425325, -0.688191),
	vector.create(-0.688191, -0.587785, -0.425325),
}

-- R_EntityParticles (EF_BRIGHTFIELD): yellow particle field on the
-- precalculated vertex normals, spun by per-normal angular velocities
local avelocities: { vector } = {}
local BEAMLENGTH = 16
function particlesim.entityParticles(sys: System, org: vector, time: number)
	if #avelocities == 0 then
		for _ = 1, #ANORMS do
			table.insert(avelocities, vector.create((rand() % 256) * 0.01, (rand() % 256) * 0.01, 0))
		end
	end
	local dist = 64
	for i = 1, #ANORMS do
		local av = avelocities[i]
		local angle = time * av.x
		local sy, cy = math.sin(angle), math.cos(angle)
		angle = time * av.y
		local sp, cp = math.sin(angle), math.cos(angle)
		local forward = vector.create(cp * cy, cp * sy, -sp)
		local p = alloc(sys)
		p.die = time + 0.01
		p.color = 0x6f
		p.type = pt_explode
		p.ramp = 0
		p.vel = vector.zero
		p.org = org + ANORMS[i] * dist + forward * BEAMLENGTH
	end
end

-- R_TeleportSplash
function particlesim.teleportSplash(sys: System, org: vector, time: number)
	for i = -16, 12, 4 do
		for j = -16, 12, 4 do
			for k = -24, 28, 4 do
				local p = alloc(sys)
				p.die = time + 0.2 + bit32.band(rand(), 7) * 0.02
				p.color = 7 + bit32.band(rand(), 7)
				p.type = pt_slowgrav
				local dir = vector.create(j * 8, i * 8, k * 8)
				p.org = org + vector.create(i + bit32.band(rand(), 3), j + bit32.band(rand(), 3), k + bit32.band(rand(), 3))
				-- C VectorNormalize leaves a zero vector zero and always
				-- scales into vel; skipping the write here leaked stale
				-- pool velocity into the center particle
				local n = vector.magnitude(dir)
				if n > 0 then
					p.vel = dir / n * (50 + bit32.band(rand(), 63))
				else
					p.vel = vector.zero
				end
			end
		end
	end
end

-- R_LavaSplash
function particlesim.lavaSplash(sys: System, org: vector, time: number)
	for i = -16, 15 do
		for j = -16, 15 do
			local p = alloc(sys)
			p.die = time + 2 + bit32.band(rand(), 31) * 0.02
			p.color = 224 + bit32.band(rand(), 7)
			p.type = pt_slowgrav
			local dir = vector.create(j * 8 + bit32.band(rand(), 7), i * 8 + bit32.band(rand(), 7), 256)
			p.org = org + vector.create(dir.x, dir.y, bit32.band(rand(), 63))
			local n = vector.magnitude(dir)
			p.vel = dir / n * (50 + bit32.band(rand(), 63))
		end
	end
end

--------------------------------------------------------------------------
-- per-frame simulation (R_DrawParticles physics)

function particlesim.update(sys: System, time: number, frametime: number)
	local time3 = frametime * 15
	local time2 = frametime * 10
	local time1 = frametime * 5
	local grav = frametime * GRAVITY * 0.05
	local dvel = 4 * frametime

	for _, p in sys.pool do
		if not p.alive then
			continue
		end
		if p.die < time then
			p.alive = false
			continue
		end

		p.org += p.vel * frametime

		local t = p.type
		if t == pt_fire then
			p.ramp += time1
			if p.ramp >= 6 then
				p.die = -1
			else
				p.color = ramp3[math.floor(p.ramp) + 1]
			end
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z + grav)
		elseif t == pt_explode then
			p.ramp += time2
			if p.ramp >= 8 then
				p.die = -1
			else
				p.color = ramp1[math.floor(p.ramp) + 1]
			end
			p.vel += p.vel * dvel
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z - grav)
		elseif t == pt_explode2 then
			p.ramp += time3
			if p.ramp >= 8 then
				p.die = -1
			else
				p.color = ramp2[math.floor(p.ramp) + 1]
			end
			p.vel -= p.vel * frametime
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z - grav)
		elseif t == pt_blob then
			p.vel += p.vel * dvel
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z - grav)
		elseif t == pt_blob2 then
			p.vel = vector.create(p.vel.x - p.vel.x * dvel, p.vel.y - p.vel.y * dvel, p.vel.z - grav)
		elseif t == pt_grav then
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z - grav * 20)
		elseif t == pt_slowgrav then
			p.vel = vector.create(p.vel.x, p.vel.y, p.vel.z - grav)
		end
	end
end

return particlesim
