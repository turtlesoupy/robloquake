--!strict
--!optimize 2
-- Particles — the Roblox rendering half of WinQuake r_part.c: wraps the
-- headless simulation in particlesim.luau with a pool of small neon cubes
-- (D_DrawParticle stand-ins).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local textures = require(script.Parent.textures)
local particlesim = require(script.Parent.particlesim)

local particles = {}

export type System = {
	sim: particlesim.System,
	parts: { Part },
	shown: { boolean },
	palette: { Color3 }, -- 256 palette colors
	folder: Folder,
	lastColor: { number }, -- palette index written to each part
	moveParts: { Part }, -- BulkMoveTo scratch, rebuilt per frame
	moveCFrames: { CFrame },
}

function particles.new(pal: textures.Palette, parent: Instance): System
	local folder = Instance.new("Folder")
	folder.Name = "QuakeParticles"
	folder.Parent = parent

	local palette = table.create(256)
	for i = 1, 256 do
		palette[i] = Color3.fromRGB(pal.r[i], pal.g[i], pal.b[i])
	end

	local parts: { Part } = table.create(particlesim.MAX_PARTICLES)
	local shown: { boolean } = table.create(particlesim.MAX_PARTICLES)
	for i = 1, particlesim.MAX_PARTICLES do
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
		parts[i] = part
		shown[i] = false
	end

	return {
		sim = particlesim.new(),
		parts = parts,
		shown = shown,
		palette = palette,
		folder = folder,
		lastColor = {},
		moveParts = {},
		moveCFrames = {},
	}
end

--------------------------------------------------------------------------
-- effect spawners (see particlesim.luau for the r_part.c logic)

-- R_ParticleExplosion
function particles.explosion(sys: System, org: vector, time: number)
	particlesim.explosion(sys.sim, org, time)
end

-- R_ParticleExplosion2
function particles.particleExplosion2(sys: System, org: vector, colorStart: number, colorLength: number, time: number)
	particlesim.particleExplosion2(sys.sim, org, colorStart, colorLength, time)
end

-- R_BlobExplosion
function particles.blobExplosion(sys: System, org: vector, time: number)
	particlesim.blobExplosion(sys.sim, org, time)
end

-- R_RunParticleEffect (blood, gunshot sparks, etc.)
function particles.runEffect(sys: System, org: vector, dir: vector, color: number, count: number, time: number, qwScale: boolean?)
	particlesim.runEffect(sys.sim, org, dir, color, count, time, qwScale)
end

-- R_RocketTrail
function particles.rocketTrail(sys: System, start: vector, endp: vector, ttype: number, time: number)
	particlesim.rocketTrail(sys.sim, start, endp, ttype, time)
end

-- R_EntityParticles (EF_BRIGHTFIELD)
function particles.entityParticles(sys: System, org: vector, time: number)
	particlesim.entityParticles(sys.sim, org, time)
end

-- R_TeleportSplash
function particles.teleportSplash(sys: System, org: vector, time: number)
	particlesim.teleportSplash(sys.sim, org, time)
end

-- R_LavaSplash
function particles.lavaSplash(sys: System, org: vector, time: number)
	particlesim.lavaSplash(sys.sim, org, time)
end

--------------------------------------------------------------------------
-- per-frame simulation + render (R_DrawParticles)

function particles.update(sys: System, time: number, frametime: number)
	particlesim.update(sys.sim, time, frametime)

	-- positions move through ONE BulkMoveTo (an explosion lights up to
	-- 1024 particles — per-part Position writes spiked exactly when
	-- fights are busiest), and Color is written only when the palette
	-- index changed (ramps step ~10Hz, not per render frame)
	local parts = sys.parts
	local shown = sys.shown
	local lastColor = sys.lastColor
	local moveParts = sys.moveParts
	local moveCFrames = sys.moveCFrames
	table.clear(moveParts)
	table.clear(moveCFrames)
	for i, p in sys.sim.pool do
		local part = parts[i]
		if not p.alive then
			if shown[i] then
				shown[i] = false
				part.Transparency = 1
			end
			continue
		end
		table.insert(moveParts, part)
		table.insert(moveCFrames, CFrame.new(qcoords.toRoblox(p.org)))
		local ci = math.clamp(math.floor(p.color), 0, 255) + 1
		if lastColor[i] ~= ci then
			lastColor[i] = ci
			part.Color = sys.palette[ci]
		end
		if not shown[i] then
			shown[i] = true
			part.Transparency = 0
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- R_ClearParticles (map change): headless clear + hide the shown parts
function particles.clear(sys: System)
	particlesim.clear(sys.sim)
	for i, part in sys.parts do
		if sys.shown[i] then
			sys.shown[i] = false
			part.Transparency = 1
		end
	end
end

return particles
