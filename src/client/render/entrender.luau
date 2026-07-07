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
	translatedPixels: { [number]: buffer }?, -- kept for lit variants
	-- light-baked skin variants by (skin, colors, bucket) key: Part.Color
	-- does not modulate MeshPart textures and SurfaceAppearance content
	-- props are plugin-gated at runtime, so entity light is baked into
	-- the skin pixels (the software renderer's colormap, quantized)
	litSkins: { [number]: EditableImage }?,
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
	defRef: ModelDef?, -- lit-skin source (pixels/palette/caches)
	-- ViewportFrames ignore part-level tints entirely; the view weapon's
	-- light rides the frame's ImageColor3 instead of baked skins (set by
	-- the caller that owns the viewmodel frame)
	lightFrame: ViewportFrame?,
	lastLightL: number?,
	untextured: boolean?, -- no skin image: Part.Color renders, tint it directly
	skinnum: number?, -- last skin/colors updateAlias applied (lit rebake source)
	colors: number?,
	lightBucket: number?, -- quantized light from setLight
	appliedBucket: number?, -- bucket baked into the current TextureContent
	vids: { number }?, -- vertex ids by mdl vertex index (front + back seam copies)
	backVids: { number }?,
	lastFrame: number,
	lastSubframe: any?, -- resolved framegroup subframe last posed
	lastSkinKey: number?,
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

local function buildAliasEnt(def: ModelDef, parent: Instance): RenderEnt?
	if not textures.canUseMeshApi() then
		return buildAliasBoxEnt(def, parent)
	end
	local am = def.alias :: mdl.AliasModel
	local em = AssetService:CreateEditableMesh()
	if not em then
		return buildAliasBoxEnt(def, parent) -- memory budget exhausted
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
		return buildAliasBoxEnt(def, parent)
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
		return buildAliasBoxEnt(def, parent)
	end
	local part = partOrErr :: MeshPart
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	local skinImages = def.skinImages
	if skinImages and skinImages[1] then
		part.TextureContent = Content.fromObject(skinImages[1])
	end
	part.Parent = parent

	return {
		kind = "alias",
		modelindex = 0,
		em = em,
		part = part,
		defRef = def,
		untextured = not (skinImages and skinImages[1]),
		vids = vids,
		backVids = backVids,
		lastFrame = 0,
		centerOffset = centerOffset,
	}
end

-- entity light quantization: lit skin variants are baked per bucket and
-- cached (software quake equivalently buckets via the 64-row colormap);
-- bucket LIGHT_BUCKETS = full intensity = the original unlit images
local LIGHT_BUCKETS = 16

-- unlit image for (skinnum, colors): the base skin, or the player skin
-- translated into the colors byte (cached, pixels kept for lit rebakes)
local function unlitSkinImage(def: ModelDef, skinnum: number, colors: number?): EditableImage?
	if colors and def.translatedSkins and def.skinPixels then
		local cache = def.translatedSkins :: { [number]: EditableImage }
		local img = cache[colors]
		if not img then
			local translated = textures.translatePixels(
				def.skinPixels :: buffer,
				(def.skinW :: number) * (def.skinH :: number),
				colors
			)
			local tp = def.translatedPixels
			if tp then
				tp[colors] = translated
			end
			img = textures.createImage(translated, def.skinW :: number, def.skinH :: number, def.palRef :: any, false)
			if img then
				cache[colors] = img
			end
		end
		if img then
			return img
		end
	end
	local skinImages = def.skinImages
	return if skinImages then skinImages[skinnum + 1] else nil
end

-- palettized source pixels for (skinnum, colors) lit rebakes
local function skinPixelsFor(def: ModelDef, skinnum: number, colors: number?): buffer?
	if colors and def.skinPixels then
		local tp = def.translatedPixels
		local buf = if tp then tp[colors] else nil
		if not buf then
			buf = textures.translatePixels(
				def.skinPixels :: buffer,
				(def.skinW :: number) * (def.skinH :: number),
				colors
			)
			if tp then
				tp[colors] = buf
			end
		end
		return buf
	end
	local am = def.alias
	local skin = if am then am.skins[skinnum + 1] else nil
	if not skin then
		return def.skinPixels
	end
	return if skin.group then (skin.frames :: { buffer })[1] else skin.pixels :: buffer
end

-- skin image with the entity light baked in (cached per skin/colors/
-- bucket); falls back to the unlit image when the image budget is out
local function litSkinImage(def: ModelDef, skinnum: number, colors: number?, bucket: number): EditableImage?
	if bucket >= LIGHT_BUCKETS then
		return unlitSkinImage(def, skinnum, colors)
	end
	local cache = def.litSkins
	if not cache then
		return unlitSkinImage(def, skinnum, colors)
	end
	local key = bucket + (skinnum + 1) * 100 + (if colors then (colors + 1) * 100000 else 0)
	local img = cache[key]
	if not img then
		local px = skinPixelsFor(def, skinnum, colors)
		local w, h = def.skinW, def.skinH
		if not px or not w or not h then
			return unlitSkinImage(def, skinnum, colors)
		end
		img = textures.createLitImage(px, w, h, def.palRef :: any, bucket / LIGHT_BUCKETS)
		if not img then
			return unlitSkinImage(def, skinnum, colors)
		end
		cache[key] = img
	end
	return img
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
		-- framegroup models (torches/flames) hit this path every render
		-- frame; re-pose (2 x numverts SetPosition calls) only when the
		-- time-resolved subframe actually changed
		if f ~= re.lastSubframe then
			re.lastSubframe = f
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
	end

	-- skins (player entities get color-translated variants), baked at
	-- the entity's current light bucket (setLight owns the bucket)
	local bucket = re.lightBucket or LIGHT_BUCKETS
	local wantSkinKey = (skinnum + 1) + (if colors then (colors + 1) * 1000 else 0)
	if re.lastSkinKey ~= wantSkinKey or re.appliedBucket ~= bucket then
		re.lastSkinKey = wantSkinKey
		re.skinnum = skinnum
		re.colors = colors
		local img = litSkinImage(def, skinnum, colors, bucket)
		if img then
			part.TextureContent = Content.fromObject(img)
			re.appliedBucket = bucket
		end
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
	if spriteImages and spriteImages[1] then
		img.ImageContent = Content.fromObject(spriteImages[1])
	end
	img.Parent = gui

	part.Parent = parent
	return {
		kind = "sprite",
		modelindex = 0,
		lastFrame = -1,
		billboardPart = part,
		billboardImage = img,
	}
end

function entrender.updateSprite(re: RenderEnt, def: ModelDef, origin: vector, frame: number)
	local part = re.billboardPart :: Part
	part.Position = qcoords.toRoblox(origin)
	if frame ~= re.lastFrame then
		re.lastFrame = frame
		local spriteImages = def.spriteImages
		local img = re.billboardImage
		if spriteImages and img and spriteImages[frame + 1] then
			img.ImageContent = Content.fromObject(spriteImages[frame + 1])
		end
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
-- (software adds an ambient floor so nothing goes fully black).
-- Part.Color does not modulate MeshPart textures and SurfaceAppearance
-- content properties are plugin-gated at runtime, so the light bakes
-- into cached lit skin variants (quantized; swapped via TextureContent).
-- The view weapon instead rides its ViewportFrame's ImageColor3 —
-- smooth, and viewports ignore part-level tints anyway.
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
	local frame = re.lightFrame
	if frame then
		local last = re.lastLightL
		if last and math.abs(l - last) < 0.02 then
			return
		end
		re.lastLightL = l
		frame.ImageColor3 = Color3.new(l, l, l)
		return
	end
	if re.untextured then
		part.Color = Color3.new(l, l, l) -- no skin: the part color renders
		return
	end
	local bucket = math.clamp((l * LIGHT_BUCKETS + 0.5) // 1, 1, LIGHT_BUCKETS)
	if bucket == re.lightBucket then
		return
	end
	re.lightBucket = bucket
	local def = re.defRef
	if def and re.appliedBucket ~= bucket then
		local img = litSkinImage(def, re.skinnum or 0, re.colors, bucket)
		if img then
			part.TextureContent = Content.fromObject(img)
			re.appliedBucket = bucket
		end
	end
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
	if def.litSkins then
		for _, img in def.litSkins do
			img:Destroy()
		end
		def.litSkins = nil
	end
	def.translatedPixels = nil
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
		def.translatedPixels = {}
		def.litSkins = {}
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

return entrender
