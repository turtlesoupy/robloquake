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
local buildqueue = require(script.Parent.buildqueue)

local entrender = {}

--------------------------------------------------------------------------
-- Zombie-image annealing. EditableImages created during entity-def
-- sighting bursts intermittently fail their GPU upload and render BLACK
-- forever — CPU pixels stay healthy, no error is raised, and the object
-- cannot be repaired in place (rebinding, reparenting and full pixel
-- rewrites all fail; only a NEW object heals). Characterization:
-- tools/verify_editablepool.luau + the RQDBG_SelfTest gallery. So a
-- beat after creation every def image is recreated from its own pixels
-- and swapped into the def; the per-frame identity checks in
-- updateAlias/updateSprite rebind live ents, and the old object is
-- destroyed once nothing can still reference it.
-- Timing/context matter (gallery boots 2026-07-05): recreations fired 0.4s
-- after def prep, from the Heartbeat-connection context, DURING the
-- sighting burst, zombied exactly like the originals — while recreations
-- from a task context in a build-quiet window have never failed (executor
-- heals, green-quad selftest, the live rebind probe). So the anneal now
-- imitates the proven heal: it waits for the shared build queue to go
-- idle, recreates inside the exclusive build slot, and runs the work in a
-- deferred task rather than the Heartbeat callback itself.
local ANNEAL_DELAY = 0.4
-- Build-queue idle seconds required before draining. Gallery boot
-- evidence: 0.3s let recreations run in the gaps BETWEEN sighting-burst
-- builds (teleport sweep cadence ~1.2s) and those zombied exactly like
-- the originals; only well-after-the-burst recreations have ever healed.
local ANNEAL_QUIET = 1.5
local annealQueue: { { def: ModelDef, field: string, at: number } } = {}
local annealConn: RBXScriptConnection? = nil
local annealCount = 0

local function recreateImage(img: EditableImage): EditableImage?
	local ok, fresh = pcall(function(): EditableImage?
		local w, h = img.Size.X, img.Size.Y
		local px = img:ReadPixelsBuffer(Vector2.zero, Vector2.new(w, h))
		local ni = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		if not ni then
			return nil
		end
		ni:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), px)
		return ni
	end)
	return if ok then fresh else nil
end

local function processAnneal(entry: { def: ModelDef, field: string, at: number })
	local tbl = (entry.def :: any)[entry.field] :: { [any]: EditableImage }?
	if not tbl then
		return
	end
	for key, old in tbl do
		-- hold the exclusive build slot: no scratch dynamic EM (or other
		-- build-burst creation) shares the recreation window
		local fresh = buildqueue.run(function()
			return recreateImage(old)
		end)
		if fresh then
			tbl[key] = fresh
			annealCount += 1
			task.delay(0.5, function()
				old:Destroy()
			end)
		end
	end
	workspace:SetAttribute("RQDBG_AnnealCount", annealCount)
end

local function drainAnneal()
	-- only anneal in a build-quiet window; during a sighting burst the
	-- recreations would zombie exactly like the originals
	if buildqueue.idleFor() >= ANNEAL_QUIET then
		local now = os.clock()
		for i, entry in annealQueue do
			if now >= entry.at then
				table.remove(annealQueue, i)
				-- run OUT of the Heartbeat-connection context (see above)
				task.defer(processAnneal, entry)
				break -- one def per drain: spread the recreations out
			end
		end
	end
	if #annealQueue == 0 and annealConn then
		annealConn:Disconnect()
		annealConn = nil
	end
end

local function queueAnneal(def: ModelDef, field: string)
	table.insert(annealQueue, { def = def, field = field, at = os.clock() + ANNEAL_DELAY })
	if not annealConn then
		annealConn = game:GetService("RunService").Heartbeat:Connect(drainAnneal)
	end
end

-- Re-queue every image a def owns (RQDBG_SelfTest re-anneal hook; also
-- lets a caller force a late pass after a known-hot stretch)
function entrender.annealDefImages(def: ModelDef)
	if def.skinImages then
		queueAnneal(def, "skinImages")
	end
	if def.spriteImages then
		queueAnneal(def, "spriteImages")
	end
	if def.translatedSkins and next(def.translatedSkins :: any) then
		queueAnneal(def, "translatedSkins")
	end
end

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

local MAX_BUILD_ATTEMPTS = 6 -- backoff retries total ~3s before the box fallback

local function buildAliasEnt(def: ModelDef, parent: Instance): RenderEnt?
	if not textures.canUseMeshApi() then
		return buildAliasBoxEnt(def, parent)
	end
	local am = def.alias :: mdl.AliasModel
	local skinW, skinH = am.skinwidth, am.skinheight

	-- frame 0 positions, computed once across attempts (a degenerate mesh
	-- fails CreateMeshPartAsync); centered so the part pivot is exact
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
	local centerVec = (bmins + bmaxs) / 2
	local centerOffset = CFrame.new(centerVec)

	-- One build attempt: scratch dynamic EM → fixed-size copy → MeshPart.
	-- The scratch must NEVER outlive the attempt: a dynamic EditableMesh
	-- reserves the 60k-vertex maximum against the editable memory budget,
	-- and one retained dynamic saturates it for the whole session (see
	-- worldmesh — images created at that margin zombie into permanent
	-- black). The fixed copy reserves only its actual size and still
	-- allows SetPosition (frame animation). Returns nil on budget failure.
	local function attempt(): { em: EditableMesh, part: MeshPart, vids: { number }, backVids: { number } }?
		local em = AssetService:CreateEditableMesh()
		if not em then
			return nil -- memory budget exhausted
		end

		-- vertices: each mdl vertex gets a front-facing and a back-facing
		-- copy (back-facing verts on the seam have s + skinwidth/2)
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

		for i = 1, am.numverts do
			local rp = positions[i] - centerVec
			em:SetPosition(vids[i], rp)
			em:SetPosition(backVids[i], rp)
		end

		local okF, fixedOrErr = pcall(function()
			return AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
		end)
		em:Destroy()
		if not okF or not fixedOrErr then
			return nil
		end
		local fixed = fixedOrErr :: EditableMesh

		-- remap vertex ids: the copy preserves creation order (front/back interleaved)
		local ids = fixed:GetVertices()
		for i = 1, am.numverts do
			vids[i] = ids[2 * i - 1]
			backVids[i] = ids[2 * i]
		end

		local ok, partOrErr = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(fixed), { CollisionFidelity = Enum.CollisionFidelity.Box })
		end)
		if not ok then
			fixed:Destroy()
			return nil
		end
		return { em = fixed, part = partOrErr :: MeshPart, vids = vids, backVids = backVids }
	end

	-- budget pressure is transient (sighting-burst builds run through the
	-- same budget); retry with backoff before degrading to the box. Each
	-- attempt holds the exclusive build slot: one scratch dynamic EM alive
	-- at a time across worldmesh + entrender.
	local built: { em: EditableMesh, part: MeshPart, vids: { number }, backVids: { number } }? = nil
	for n = 1, MAX_BUILD_ATTEMPTS do
		built = buildqueue.run(attempt)
		if built then
			break
		end
		if n < MAX_BUILD_ATTEMPTS then
			task.wait(0.1 * 2 ^ (n - 1))
		end
	end
	if not built then
		warn(`[robloquake] alias build failed for {am.name} after {MAX_BUILD_ATTEMPTS} attempts (box fallback)`)
		return buildAliasBoxEnt(def, parent)
	end
	local em, part, vids, backVids = built.em, built.part, built.vids, built.backVids
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	local skinImages = def.skinImages
	local initialImg = if skinImages then skinImages[1] else nil
	if initialImg then
		part.TextureContent = Content.fromObject(initialImg)
	end
	part.Parent = parent

	return {
		kind = "alias",
		boundImg = initialImg,
		modelindex = 0,
		em = em,
		part = part,
		vids = vids,
		backVids = backVids,
		lastFrame = 0,
		centerOffset = centerOffset,
	}
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
	-- gated on the skin key (so a failed translation isn't retried every
	-- frame), but the BIND is identity-gated so annealed swaps take.
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
					queueAnneal(def, "translatedSkins")
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
	if re.part then
		re.part:Destroy()
	end
	if re.billboardPart then
		re.billboardPart:Destroy()
	end
	if re.model then
		re.model:Destroy()
	end
	-- the fixed-size alias mesh holds EditableMesh memory budget; leaking
	-- it across map loads starves the next world build
	if re.em then
		re.em:Destroy()
		re.em = nil
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
		queueAnneal(def, "skinImages")
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
		queueAnneal(def, "spriteImages")
	end
end

return entrender
