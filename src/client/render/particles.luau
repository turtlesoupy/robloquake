--!strict
--!optimize 2
-- Particles — port of WinQuake r_part.c: the particle pool, effect
-- spawners (R_RunParticleEffect, R_ParticleExplosion, R_TeleportSplash,
-- R_LavaSplash) and per-frame physics, rendered as small neon cubes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local textures = require(script.Parent.textures)

local particles = {}

local MAX_PARTICLES = 1024
local GRAVITY = 800 -- sv_gravity

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

type Particle = {
	part: Part,
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
	palette: { Color3 }, -- 256 palette colors
	folder: Folder,
}

function particles.new(pal: textures.Palette, parent: Instance): System
	local folder = Instance.new("Folder")
	folder.Name = "QuakeParticles"
	folder.Parent = parent

	local palette = table.create(256)
	for i = 1, 256 do
		palette[i] = Color3.fromRGB(pal.r[i], pal.g[i], pal.b[i])
	end

	local pool: { Particle } = table.create(MAX_PARTICLES)
	for i = 1, MAX_PARTICLES do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Size = Vector3.new(0.25, 0.25, 0.25) -- ~2 quake units
		part.Transparency = 1
		part.Parent = folder
		pool[i] = {
			part = part,
			alive = false,
			org = vector.zero,
			vel = vector.zero,
			color = 0,
			ramp = 0,
			die = -1,
			type = pt_static,
		}
	end

	return { pool = pool, nextIdx = 1, palette = palette, folder = folder }
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
function particles.explosion(sys: System, org: vector, time: number)
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

-- R_RunParticleEffect (blood, gunshot sparks, etc.)
function particles.runEffect(sys: System, org: vector, dir: vector, color: number, count: number, time: number)
	if count == 1024 then
		particles.explosion(sys, org, time)
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

-- R_TeleportSplash
function particles.teleportSplash(sys: System, org: vector, time: number)
	for i = -16, 12, 4 do
		for j = -16, 12, 4 do
			for k = -24, 28, 4 do
				local p = alloc(sys)
				p.die = time + 0.2 + bit32.band(rand(), 7) * 0.02
				p.color = 7 + bit32.band(rand(), 7)
				p.type = pt_slowgrav
				local dir = vector.create(j * 8, i * 8, k * 8)
				p.org = org + vector.create(i + bit32.band(rand(), 3), j + bit32.band(rand(), 3), k + bit32.band(rand(), 3))
				local n = vector.magnitude(dir)
				if n > 0 then
					p.vel = dir / n * (50 + bit32.band(rand(), 63))
				end
			end
		end
	end
end

-- R_LavaSplash
function particles.lavaSplash(sys: System, org: vector, time: number)
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

function particles.update(sys: System, time: number, frametime: number)
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
			p.part.Transparency = 1
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

		p.part.Position = qcoords.toRoblox(p.org)
		p.part.Color = sys.palette[math.clamp(math.floor(p.color), 0, 255) + 1]
		p.part.Transparency = 0
	end
end

return particles
