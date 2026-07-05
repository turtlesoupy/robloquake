--!strict
--!optimize 2
-- Entity rendering: alias models (.mdl) as animated EditableMeshes,
-- sprites as billboards, and brush submodels (doors/plats) as prebuilt
-- MeshPart groups positioned by entity origin.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local mathlib = require(engine.common.mathlib)
local mdl = require(engine.models.mdl)
local spr = require(engine.models.spr)
local qcoords = require(engine.client.qcoords)

local textures = require(script.Parent.textures)

local entrender = {}

-- bumped whenever a translated skin image is created mid-game; clients
-- watch it to schedule a texverify pass over the new image
entrender.translationCount = 0

export type ModelDef = {
	kind: "alias" | "sprite" | "brush" | "none",
	alias: mdl.AliasModel?,
	sprite: spr.SpriteModel?,
	brushModel: Model?, -- prebuilt template (cloned per entity)
	flags: number,
	skinImages: { EditableImage }?,
	spriteImages: { EditableImage }?,
	-- translated player skins by colors byte (shirt/pants)
	translatedSkins: { [number]: EditableImage }?,
	skinPixels: buffer?, -- kept for building translations
	skinW: number?,
	skinH: number?,
	palRef: any?, -- palette, kept for fallback tinting
	fullbrightSkin: boolean?, -- mostly palette-224+ skin: render unlit
}

-- One rendered entity instance
export type RenderEnt = {
	kind: string,
	fullbrightSkin: boolean?,
	modelindex: number,
	-- alias
	em: EditableMesh?,
	part: MeshPart?,
	vids: { number }?, -- vertex ids by mdl vertex index (front + back seam copies)
	backVids: { number }?,
	lastFrame: number,
	lastSkinKey: number?,
	boundImg: EditableImage?, -- identity of the image actually bound
	boundSpriteImg: EditableImage?,
	-- sprite
	billboardPart: Part?,
	billboardImage: ImageLabel?,
	-- brush
	model: Model?,
	baseCFrames: { [BasePart]: CFrame }?,
	-- CreateMeshPartAsync centers geometry on the part; this restores the
	-- model-origin-relative placement (alias models)
	centerOffset: CFrame?,
	defRef: ModelDef?, -- owning def (alias ents; routes mesh back to its pool)
}

--------------------------------------------------------------------------
-- alias models

-- Build the static topology of an alias model (UVs/triangles); vertex
-- positions are filled per-frame.
local function buildAliasBoxEnt(def: ModelDef, parent: Instance): RenderEnt
	local am = def.alias :: mdl.AliasModel
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	-- size from frame 0's packed bbox
	local f0 = am.frames[1]
	local mins = f0.bboxmin * am.scale + am.scale_origin
	local maxs = f0.bboxmax * am.scale + am.scale_origin
	local size = (maxs - mins) * qcoords.SCALE
	part.Size = Vector3.new(math.max(size.x, 0.5), math.max(size.z, 0.5), math.max(size.y, 0.5))
	local skin = am.skins[1]
	local pixels = if skin.group then (skin.frames :: { buffer })[1] else skin.pixels :: buffer
	part.Color = textures.averageColor(pixels, am.skinwidth * am.skinheight, def.palRef :: any)
	part.Parent = parent
	return {
		kind = "aliasbox",
		modelindex = 0,
		lastFrame = -1,
		billboardPart = part,
	}
end

-- Per-entity mesh POOL + quiet-window regeneration. The zombie-object
-- platform defect hits per-ENTITY meshes too: an EditableMesh/MeshPart
-- born during a hot creation stretch can silently lose its GPU upload
-- and render black forever (undetectable in place; recreation heals).
-- Mid-play sightings are ALWAYS hot — a backpack drops the same frame
-- as the kill's gib burst, and nails/gibs reset any quiet clock — so
-- runtime healing can never keep up during combat. The pool removes
-- the exposure instead: instances are pre-built in the post-load
-- settle window (proven-safe) and RECYCLED as entities come and go;
-- steady-state play then creates no GPU objects at all. Overflow
-- live-builds are marked suspect and rerolled by the quiet-window
-- regen (live swap while visible, silent cure while parked).
local REGEN_QUIET = 1.5
local REGEN_SPACING = 2.5 -- live swaps: rebuilds are ISOLATED creations, never a burst
local CURE_SPACING = 1.0 -- parked cures are invisible; trickle faster
local PARK_CFRAME = CFrame.new(0, -100000, 0)

type PoolInst = {
	em: EditableMesh,
	part: MeshPart,
	vids: { number },
	backVids: { number },
	centerOffset: CFrame?,
	suspect: boolean, -- born hot; reroll its mesh when quiet allows
}

local meshPool: { [ModelDef]: { PoolInst } } = {}
local parkedCure: { [PoolInst]: ModelDef } = {} -- parked suspects awaiting reroll
local meshRegenQueue: { [RenderEnt]: ModelDef } = {} -- live suspects
local lastRegenAt = 0
local prewarming = false
local overflowBuilds = 0
local poolParent: Instance? = nil -- home for parked parts (set per level)
local regenConn: RBXScriptConnection? = nil
local buildAliasMesh -- forward decl
local drainMeshRegen -- forward decl

-- Boots call this at level build. Parked parts need an explicit parent:
-- visibility culling parents LIVE ent parts to nil, so a nil Parent on
-- release does not mean destroyed — without a home, parked meshes
-- could not be told apart from torn-down ones.
function entrender.setPoolParent(folder: Instance)
	poolParent = folder
end

local function ensureRegenConn()
	if not regenConn then
		regenConn = game:GetService("RunService").Heartbeat:Connect(function()
			drainMeshRegen()
		end)
	end
end

-- bind the def's CURRENT first skin (never a cached binding: the image
-- regeneration pass may have destroyed the object an old binding points
-- at, and a destroyed image renders black)
local function bindFreshSkin(def: ModelDef, p: MeshPart): EditableImage?
	local skins = def.skinImages
	local img = if skins then skins[1] else nil
	if img then
		p.TextureContent = Content.fromObject(img)
	end
	return img
end

local function poolAcquire(def: ModelDef): PoolInst?
	local list = meshPool[def]
	if not list then
		return nil
	end
	while #list > 0 do
		local inst = table.remove(list) :: PoolInst
		parkedCure[inst] = nil
		if inst.part.Parent then
			return inst
		end
		-- a level teardown destroyed the part; reclaim the mesh budget
		inst.em:Destroy()
	end
	return nil
end

-- park an alias ent's mesh for reuse; false = nothing poolable
local function poolRelease(re: RenderEnt): boolean
	local def = re.defRef
	local p = re.part
	local em = re.em
	local home = poolParent
	if not (def and p and em) then
		return false
	end
	if not (home and home.Parent) then
		-- no live pool home (teardown window): destroy rather than park
		em:Destroy()
		p:Destroy()
		re.part = nil
		re.em = nil
		return true
	end
	p.CFrame = PARK_CFRAME
	p.Transparency = 1
	p.Parent = home -- visibility culling may have parented the part to nil
	local inst: PoolInst = {
		em = em,
		part = p,
		vids = re.vids :: { number },
		backVids = re.backVids :: { number },
		centerOffset = re.centerOffset,
		suspect = meshRegenQueue[re] ~= nil,
	}
	meshRegenQueue[re] = nil
	local list = meshPool[def]
	if not list then
		list = {}
		meshPool[def] = list
	end
	table.insert(list, inst)
	if inst.suspect then
		parkedCure[inst] = def
		ensureRegenConn()
	end
	re.part = nil
	re.em = nil
	return true
end

function drainMeshRegen()
	local now = os.clock()
	if prewarming or textures.timeSinceCreation() < REGEN_QUIET then
		return
	end
	-- live suspects first (they are visible); parked cures when idle
	local re, def = next(meshRegenQueue)
	if re then
		if now - lastRegenAt < REGEN_SPACING then
			return
		end
		lastRegenAt = now
		meshRegenQueue[re] = nil
		local oldPart = re.part
		if not oldPart then
			return
		end
		local em, part, vids, backVids, centerOffset = buildAliasMesh(def)
		if not part then
			return -- keep the old mesh; better than nothing
		end
		local p = part :: MeshPart
		p.CFrame = oldPart.CFrame
		p.Color = oldPart.Color
		p.Transparency = oldPart.Transparency
		re.boundImg = bindFreshSkin(def, p)
		p.Parent = oldPart.Parent
		local oldEm = re.em
		re.em = em
		re.part = p
		re.vids = vids
		re.backVids = backVids
		re.centerOffset = centerOffset
		re.lastFrame = -999 -- force a re-pose next updateAlias
		oldPart:Destroy()
		if oldEm then
			oldEm:Destroy()
		end
		return
	end
	local inst, def2 = next(parkedCure)
	if inst then
		if now - lastRegenAt < CURE_SPACING then
			return
		end
		lastRegenAt = now
		parkedCure[inst] = nil
		local list = meshPool[def2]
		local at = if list then table.find(list, inst) else nil
		if not at or not inst.part.Parent then
			return -- re-acquired or torn down since queuing; nothing to cure
		end
		local em, part, vids, backVids, centerOffset = buildAliasMesh(def2)
		if not part then
			return -- keep the suspect instance; still better than nothing
		end
		local p = part :: MeshPart
		bindFreshSkin(def2, p)
		p.Transparency = 1
		p.CFrame = PARK_CFRAME
		p.Parent = inst.part.Parent
		inst.part:Destroy()
		inst.em:Destroy()
		inst.em = em :: EditableMesh
		inst.part = p
		inst.vids = vids :: { number }
		inst.backVids = backVids :: { number }
		inst.centerOffset = centerOffset
		inst.suspect = false
		return
	end
	if regenConn then
		regenConn:Disconnect()
		regenConn = nil
	end
end

local function queueMeshRegen(re: RenderEnt, def: ModelDef)
	meshRegenQueue[re] = def
	ensureRegenConn()
end

local function buildAliasEnt(def: ModelDef, parent: Instance): RenderEnt?
	if not textures.canUseMeshApi() then
		return buildAliasBoxEnt(def, parent)
	end
	local suspect: boolean
	local em: EditableMesh?, part: MeshPart?, vids: { number }?, backVids: { number }?, centerOffset: CFrame?
	local inst = poolAcquire(def)
	if inst then
		em, part, vids, backVids, centerOffset = inst.em, inst.part, inst.vids, inst.backVids, inst.centerOffset
		suspect = inst.suspect
	else
		-- pool empty: build live. This is the hot path the pool exists to
		-- avoid — mark suspect so the quiet-window regen rerolls it.
		textures.noteCreation()
		em, part, vids, backVids, centerOffset = buildAliasMesh(def)
		if not part then
			return buildAliasBoxEnt(def, parent) -- budget exhausted / build failed
		end
		textures.noteCreation()
		suspect = true
		overflowBuilds += 1
		workspace:SetAttribute("RQDBG_PoolOverflow", overflowBuilds)
	end
	local p = part :: MeshPart
	p.Transparency = 0
	local initialImg = bindFreshSkin(def, p)
	p.Parent = parent

	local re: RenderEnt = {
		kind = "alias",
		boundImg = initialImg,
		modelindex = 0,
		em = em,
		part = p,
		vids = vids,
		backVids = backVids,
		lastFrame = -999, -- pooled meshes hold their previous pose
		centerOffset = centerOffset,
		defRef = def,
	}
	if suspect then
		queueMeshRegen(re, def)
	end
	return re
end

-- Pre-build pool instances for the given defs during the post-load
-- settle window (creations there survive; mid-play ones zombie). Paced;
-- aborts when canContinue() goes false (changelevel) or the mesh budget
-- runs out. Returns how many instances were built.
function entrender.prewarmPools(counts: { [ModelDef]: number }, parent: Instance, canContinue: () -> boolean): number
	poolParent = parent
	prewarming = true
	local built = 0
	for def, count in counts do
		if def.kind ~= "alias" or not def.alias then
			continue
		end
		local list = meshPool[def]
		if not list then
			list = {}
			meshPool[def] = list
		end
		for _ = #list + 1, count do
			if not canContinue() then
				prewarming = false
				return built
			end
			local em, part, vids, backVids, centerOffset = buildAliasMesh(def)
			if not part then
				prewarming = false -- mesh budget wall: stop growing pools
				return built
			end
			local p = part :: MeshPart
			bindFreshSkin(def, p)
			p.Transparency = 1
			p.CFrame = PARK_CFRAME
			p.Parent = parent
			-- the settle window is only safe while nothing ELSE creates:
			-- if the player is already fighting (overflow builds, translated
			-- skins), instances built now may be zombies that would carry a
			-- clean bill — mark them suspect so the cure loop rerolls them.
			-- (This was live-verified as the "black armor" hole: dirty-window
			-- prewarm instances acquired by early sightings.)
			local inst: PoolInst = {
				em = em :: EditableMesh,
				part = p,
				vids = vids :: { number },
				backVids = backVids :: { number },
				centerOffset = centerOffset,
				suspect = textures.timeSinceCreation() < REGEN_QUIET,
			}
			table.insert(list, inst)
			if inst.suspect then
				parkedCure[inst] = def
				ensureRegenConn()
			end
			built += 1
			workspace:SetAttribute("RQDBG_PoolPrewarmed", built)
			task.wait(0.1)
		end
	end
	prewarming = false
	return built
end

-- Pool sizing for models spawned dynamically (no spawn baselines):
-- projectiles, gibs, heads, backpacks. Baseline census covers the rest.
function entrender.dynamicPoolCount(name: string): number?
	if name == "progs/backpack.mdl" then
		return 4
	elseif name:match("^progs/gib%d") then
		return 4
	elseif name == "progs/zom_gib.mdl" then
		return 6
	elseif name:match("^progs/h_") then
		return 2 -- heads persist as corpses; overflow regen covers pile-ups
	elseif name == "progs/spike.mdl" then
		return 12
	elseif name == "progs/s_spike.mdl" then
		return 8
	elseif name == "progs/w_spike.mdl" or name == "progs/k_spike.mdl" or name == "progs/v_spike.mdl" then
		return 6
	elseif name == "progs/missile.mdl" or name == "progs/grenade.mdl" then
		return 6
	elseif name == "progs/laser.mdl" then
		return 8
	elseif name == "progs/eyes.mdl" or name == "progs/player.mdl" then
		return 2
	end
	return nil
end

function buildAliasMesh(def: ModelDef): (EditableMesh?, MeshPart?, { number }?, { number }?, CFrame?)
	local am = def.alias :: mdl.AliasModel
	local em = AssetService:CreateEditableMesh()
	if not em then
		return nil
	end

	local skinW, skinH = am.skinwidth, am.skinheight

	-- vertices: each mdl vertex gets a front-facing and a back-facing copy
	-- (back-facing verts on the seam have s + skinwidth/2)
	local vids = table.create(am.numverts)
	local backVids = table.create(am.numverts)
	for i = 1, am.numverts do
		vids[i] = em:AddVertex(Vector3.zero)
		backVids[i] = em:AddVertex(Vector3.zero)
	end

	local frontUV = table.create(am.numverts)
	local backUV = table.create(am.numverts)
	for i = 1, am.numverts do
		local stv = am.stverts[i]
		frontUV[i] = em:AddUV(Vector2.new((stv.s + 0.5) / skinW, (stv.t + 0.5) / skinH))
		local bs = if stv.onseam then stv.s + skinW / 2 else stv.s
		backUV[i] = em:AddUV(Vector2.new((bs + 0.5) / skinW, (stv.t + 0.5) / skinH))
	end

	for tri = 1, am.numtris do
		local facesfront = am.facesfront[tri]
		local i1 = am.vertindex[(tri - 1) * 3 + 1] + 1
		local i2 = am.vertindex[(tri - 1) * 3 + 2] + 1
		local i3 = am.vertindex[(tri - 1) * 3 + 3] + 1
		local v1 = if facesfront then vids[i1] else backVids[i1]
		local v2 = if facesfront then vids[i2] else backVids[i2]
		local v3 = if facesfront then vids[i3] else backVids[i3]
		local u1 = if facesfront then frontUV[i1] else backUV[i1]
		local u2 = if facesfront then frontUV[i2] else backUV[i2]
		local u3 = if facesfront then frontUV[i3] else backUV[i3]
		local fid = em:AddTriangle(v1, v3, v2) -- flip winding for roblox
		em:SetFaceUVs(fid, { u1, u3, u2 })
	end

	-- set frame 0 positions before building the part (a degenerate mesh
	-- fails CreateMeshPartAsync)
	local frame0 = am.frames[1].frames[1]
	local bmins = Vector3.new(math.huge, math.huge, math.huge)
	local bmaxs = -bmins
	local positions: { Vector3 } = table.create(am.numverts)
	for i = 1, am.numverts do
		local pos = mdl.frameVert(am, frame0, i)
		local rp = Vector3.new(pos.x * qcoords.SCALE, pos.z * qcoords.SCALE, -pos.y * qcoords.SCALE)
		bmins = bmins:Min(rp)
		bmaxs = bmaxs:Max(rp)
		positions[i] = rp
	end
	-- center the vertices on the mesh origin so the part pivot is exact
	local centerVec = (bmins + bmaxs) / 2
	for i = 1, am.numverts do
		local rp = positions[i] - centerVec
		em:SetPosition(vids[i], rp)
		em:SetPosition(backVids[i], rp)
	end
	local centerOffset = CFrame.new(centerVec)

	-- fixed-size copy: a dynamic EditableMesh reserves the 60k-vertex max
	-- against the memory budget; the copy reserves only its actual size and
	-- still allows SetPosition (frame animation)
	local okF, fixedOrErr = pcall(function()
		return AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
	end)
	em:Destroy()
	if not okF or not fixedOrErr then
		warn(`[robloquake] alias fixed copy failed: {fixedOrErr}`)
		return nil
	end
	em = fixedOrErr :: EditableMesh

	-- remap vertex ids: the copy preserves creation order (front/back interleaved)
	local ids = em:GetVertices()
	for i = 1, am.numverts do
		vids[i] = ids[2 * i - 1]
		backVids[i] = ids[2 * i]
	end

	local ok, partOrErr = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(em), { CollisionFidelity = Enum.CollisionFidelity.Box })
	end)
	if not ok then
		em:Destroy()
		warn(`[robloquake] alias mesh failed: {partOrErr}`)
		return nil
	end
	local part = partOrErr :: MeshPart
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	return em, part, vids, backVids, centerOffset
end

-- pick the frame (handling framegroups by time)
local aliasFrame = mdl.selectFrame -- shared so lune can drive R_AliasSetupFrame's math

-- update an alias entity's pose for this frame
function entrender.updateAlias(
	re: RenderEnt,
	def: ModelDef,
	origin: vector,
	angles: vector,
	frame: number,
	skinnum: number,
	syncbase: number,
	time: number,
	colors: number? -- player shirt/pants byte for colormapped entities
)
	if re.kind == "aliasbox" then
		local part = re.billboardPart :: Part
		part.CFrame = CFrame.new(qcoords.toRoblox(origin) + Vector3.new(0, part.Size.Y / 2 - 24 * qcoords.SCALE, 0))
			* CFrame.Angles(0, math.rad(angles.y), 0)
		return
	end
	local am = def.alias :: mdl.AliasModel
	local em = re.em :: EditableMesh
	local part = re.part :: MeshPart
	local vids = re.vids :: { number }
	local backVids = re.backVids :: { number }

	if frame ~= re.lastFrame or am.frames[frame + 1] and am.frames[frame + 1].group then
		re.lastFrame = frame
		local f = aliasFrame(am, frame, syncbase, time)
		local verts = f.verts
		local scale = am.scale
		local sorigin = am.scale_origin
		local SCALE = qcoords.SCALE
		local centerVec = (re.centerOffset or CFrame.identity).Position
		for i = 1, am.numverts do
			local o = (i - 1) * 4
			local x = buffer.readu8(verts, o) * scale.x + sorigin.x
			local y = buffer.readu8(verts, o + 1) * scale.y + sorigin.y
			local z = buffer.readu8(verts, o + 2) * scale.z + sorigin.z
			local rp = Vector3.new(x * SCALE, z * SCALE, -y * SCALE) - centerVec
			em:SetPosition(vids[i], rp)
			em:SetPosition(backVids[i], rp)
		end
	end

	-- skins (player entities get color-translated variants). Creation is
	-- gated on the skin key (a failed translation isn't retried every
	-- frame) but the BIND is identity-gated, so texverify swaps take
	-- effect on live ents the next frame.
	local wantSkinKey = (skinnum + 1) + (if colors then (colors + 1) * 1000 else 0)
	if re.lastSkinKey ~= wantSkinKey then
		re.lastSkinKey = wantSkinKey
		if colors and def.translatedSkins and def.skinPixels then
			local cache = def.translatedSkins :: { [number]: EditableImage }
			if not cache[colors] then
				local translated = textures.translatePixels(
					def.skinPixels :: buffer,
					(def.skinW :: number) * (def.skinH :: number),
					colors
				)
				local img = textures.createImage(translated, def.skinW :: number, def.skinH :: number, def.palRef :: any, false)
				if img then
					cache[colors] = img
					entrender.translationCount += 1
				end
			end
		end
	end
	local img: EditableImage? = nil
	if colors and def.translatedSkins then
		img = (def.translatedSkins :: { [number]: EditableImage })[colors]
	end
	if not img then
		local skinImages = def.skinImages
		img = if skinImages then skinImages[skinnum + 1] else nil
	end
	if img and re.boundImg ~= img then
		re.boundImg = img
		part.TextureContent = Content.fromObject(img)
	end

	-- entity angles: pitch, yaw, roll (quake degrees). Alias models pitch
	-- opposite to view pitch.
	local forward, right, up = mathlib.angleVectors(vector.create(-angles.x, angles.y, angles.z))
	part.CFrame = qcoords.modelCFrame(origin, forward, right, up) * (re.centerOffset or CFrame.identity)
end

--------------------------------------------------------------------------
-- sprites

local function buildSpriteEnt(def: ModelDef, parent: Instance): RenderEnt
	local sm = def.sprite :: spr.SpriteModel
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(sm.maxwidth * qcoords.SCALE, sm.maxheight * qcoords.SCALE)
	gui.LightInfluence = 0
	gui.Parent = part

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ResampleMode = Enum.ResamplerMode.Pixelated
	local spriteImages = def.spriteImages
	local initialSprite = if spriteImages then spriteImages[1] else nil
	if initialSprite then
		img.ImageContent = Content.fromObject(initialSprite)
	end
	img.Parent = gui

	part.Parent = parent
	return {
		kind = "sprite",
		modelindex = 0,
		lastFrame = -1,
		boundSpriteImg = initialSprite,
		billboardPart = part,
		billboardImage = img,
	}
end

function entrender.updateSprite(re: RenderEnt, def: ModelDef, origin: vector, frame: number)
	local part = re.billboardPart :: Part
	part.Position = qcoords.toRoblox(origin)
	local spriteImages = def.spriteImages
	local img = re.billboardImage
	local want = if spriteImages then spriteImages[frame + 1] else nil
	if img and want and re.boundSpriteImg ~= want then
		re.boundSpriteImg = want
		re.lastFrame = frame
		img.ImageContent = Content.fromObject(want)
	end
end

--------------------------------------------------------------------------
-- brush submodels

function entrender.updateBrush(re: RenderEnt, origin: vector, angles: vector)
	local model = re.model :: Model
	local baseCFrames = re.baseCFrames :: { [BasePart]: CFrame }
	local offset = qcoords.toRoblox(origin)
	-- brush entities in vanilla don't rotate (except rotating brushes,
	-- which id1 doesn't use), so translation is enough
	local _ = angles
	for part, base in baseCFrames do
		part.CFrame = base + offset
	end
end

--------------------------------------------------------------------------
-- instance management

function entrender.create(def: ModelDef, parent: Instance): RenderEnt?
	if def.kind == "alias" then
		local re = buildAliasEnt(def, parent)
		if re then
			re.fullbrightSkin = def.fullbrightSkin
		end
		return re
	elseif def.kind == "sprite" then
		return buildSpriteEnt(def, parent)
	elseif def.kind == "brush" then
		local template = def.brushModel
		if not template then
			return nil
		end
		local model = template:Clone()
		local baseCFrames: { [BasePart]: CFrame } = {}
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				baseCFrames[part] = part.CFrame
			end
		end
		model.Parent = parent
		return {
			kind = "brush",
			modelindex = 0,
			lastFrame = -1,
			model = model,
			baseCFrames = baseCFrames,
		}
	end
	return nil
end

-- Re-clone a live brush ent from its def's CURRENT template (used by the
-- boot's brush-template rebuild pass: a template born in the load burst
-- can be a zombie, and every clone of it inherits the black render).
-- Position self-corrects on the next updateBrush (baseCFrames + origin).
function entrender.refreshBrush(re: RenderEnt, def: ModelDef)
	local old = re.model
	local template = def.brushModel
	if re.kind ~= "brush" or not old or not template then
		return
	end
	local model = template:Clone()
	local baseCFrames: { [BasePart]: CFrame } = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			baseCFrames[part] = part.CFrame
		end
	end
	model.Parent = old.Parent
	re.model = model
	re.baseCFrames = baseCFrames
	old:Destroy()
end

-- R_LightPoint tint: models are shaded by the floor lightmap under them
-- (software adds an ambient floor so nothing goes fully black)
function entrender.setLight(re: RenderEnt, light: number)
	local part = re.part
	if not part then
		return
	end
	if re.fullbrightSkin then
		light = 255
	end
	local l = math.min((light + 8) * 2, 255) / 255 -- +8 ambient floor
	l = l ^ 0.7 -- match the world lighting gamma
	part.Color = Color3.new(l, l, l)
end

-- release a ModelDef's EditableImages NOW (skins/sprites/translations):
-- parts hold them only via Content, so GC is the only other releaser and
-- long sessions starve the image budget (same class as the mesh leak)
function entrender.destroyDef(def: ModelDef)
	-- pooled instances die with their def (defs are per-level; the pool
	-- must not outlive the images its parts are bound to, and parked
	-- EditableMeshes would leak budget across map loads)
	local pooled = meshPool[def]
	if pooled then
		for _, inst in pooled do
			parkedCure[inst] = nil
			inst.part:Destroy()
			inst.em:Destroy()
		end
		meshPool[def] = nil
	end
	for _, list in { def.skinImages, def.spriteImages } do
		if list then
			for _, img in list do
				img:Destroy()
			end
		end
	end
	if def.translatedSkins then
		for _, img in def.translatedSkins do
			img:Destroy()
		end
		def.translatedSkins = nil
	end
	def.skinImages = nil
	def.spriteImages = nil
end

function entrender.destroy(re: RenderEnt)
	-- alias meshes recycle through the pool (poolRelease also consumes the
	-- regen-queue membership as the parked suspect flag)
	if not poolRelease(re) then
		meshRegenQueue[re] = nil
		if re.part then
			re.part:Destroy()
		end
		-- the fixed-size alias mesh holds EditableMesh memory budget; leaking
		-- it across map loads starves the next world build
		if re.em then
			re.em:Destroy()
			re.em = nil
		end
	end
	if re.billboardPart then
		re.billboardPart:Destroy()
	end
	if re.model then
		re.model:Destroy()
	end
end

-- build the shared images for a model definition
function entrender.prepareImages(def: ModelDef, pal: textures.Palette)
	def.palRef = pal
	if def.kind == "alias" then
		local am = def.alias :: mdl.AliasModel
		local imgs: { EditableImage } = {}
		for si, skin in am.skins do
			local pixels = if skin.group then (skin.frames :: { buffer })[1] else skin.pixels :: buffer
			local img = textures.createImage(pixels, am.skinwidth, am.skinheight, pal, false)
			if img then
				imgs[si] = img
			end
		end
		def.skinImages = imgs
		local skin1 = am.skins[1]
		def.skinPixels = if skin1.group then (skin1.frames :: { buffer })[1] else skin1.pixels :: buffer
		-- the software colormap keeps palette 224-255 fullbright; per-pixel
		-- isn't expressible on a tinted MeshPart, so mostly-fullbright skins
		-- (torch flames, candles) render unlit as an approximation
		do
			local fb, count = 0, am.skinwidth * am.skinheight
			local px = def.skinPixels :: buffer
			for i = 0, count - 1 do
				if buffer.readu8(px, i) >= 224 then
					fb += 1
				end
			end
			def.fullbrightSkin = fb * 2 > count
		end
		def.skinW = am.skinwidth
		def.skinH = am.skinheight
		def.translatedSkins = {}
	elseif def.kind == "sprite" then
		local sm = def.sprite :: spr.SpriteModel
		local imgs: { EditableImage } = {}
		for fi, fd in sm.frames do
			local f = fd.frames[1]
			local img = textures.createImage(f.pixels, f.width, f.height, pal, true)
			if img then
				imgs[fi] = img
			end
		end
		def.spriteImages = imgs
	end
end

-- texverify slots for every image this def owns (skins, sprite frames,
-- translated skins). Source pixels ride along so zombies can be
-- recreated byte-identically.
function entrender.collectVerifySlots(def: ModelDef, pal: textures.Palette, out: { any })
	if def.kind == "alias" and def.skinImages then
		local am = def.alias :: mdl.AliasModel
		for si, skin in am.skins do
			if (def.skinImages :: { EditableImage })[si] then
				local pixels = if skin.group then (skin.frames :: { buffer })[1] else skin.pixels :: buffer
				table.insert(out, {
					tbl = def.skinImages,
					key = si,
					pixels = pixels,
					w = am.skinwidth,
					h = am.skinheight,
					alphaIndex = false,
					pal = pal,
				})
			end
		end
		if def.translatedSkins and def.skinPixels then
			for colors in def.translatedSkins :: { [number]: EditableImage } do
				table.insert(out, {
					tbl = def.translatedSkins,
					key = colors,
					pixels = textures.translatePixels(def.skinPixels :: buffer, (def.skinW :: number) * (def.skinH :: number), colors),
					w = def.skinW :: number,
					h = def.skinH :: number,
					alphaIndex = false,
					pal = pal,
				})
			end
		end
	elseif def.kind == "sprite" and def.spriteImages then
		local sm = def.sprite :: spr.SpriteModel
		for fi, fd in sm.frames do
			if (def.spriteImages :: { EditableImage })[fi] then
				local f = fd.frames[1]
				table.insert(out, {
					tbl = def.spriteImages,
					key = fi,
					pixels = f.pixels,
					w = f.width,
					h = f.height,
					alphaIndex = true,
					pal = pal,
				})
			end
		end
	end
end

return entrender
