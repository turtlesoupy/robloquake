--!strict
--!optimize 2
-- World geometry: builds MeshParts from a BSP model's surfaces, batched by
-- texture, with per-vertex lightmap lighting sampled at each corner.

local AssetService = game:GetService("AssetService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local bsp = require(engine.bsp.bsp)
local qcoords = require(engine.client.qcoords)

local textures = require(script.Parent.textures)
local tris = require(script.Parent.tris)
local lightatlaslib = require(script.Parent.lightatlas)

local worldmesh = {}

function worldmesh.canUseMeshApi(): boolean
	return textures.canUseMeshApi()
end

-- MeshParts render FROM their EditableMesh object, so the (fixed-size)
-- meshes must stay referenced for as long as their container lives. A
-- dynamic EditableMesh reserves the 60k-vertex maximum against the memory
-- budget; a FixedSize copy only reserves its actual size, which is why
-- every builder goes dynamic → fixed copy → destroy dynamic.
local liveMeshes: { [Instance]: { EditableMesh } } = {}
local liveImages: { [Instance]: { EditableImage } } = {}

local function retainMesh(container: Instance, em: EditableMesh)
	local list = liveMeshes[container]
	if not list then
		list = {}
		liveMeshes[container] = list
		container.Destroying:Connect(function()
			local held = liveMeshes[container]
			liveMeshes[container] = nil
			if held then
				-- release the editable memory budget immediately; waiting
				-- for GC starves the next map's build
				for _, m in held do
					m:Destroy()
				end
			end
		end)
	end
	table.insert(list, em)
end

-- Destroy a build (world model or brush template) and release its retained
-- meshes NOW. The Destroying hook above is only a backstop: Studio defers
-- signals, so a teardown that relies on it still holds the mesh budget
-- while the next map builds — which starves that build into skipped
-- batches (missing world geometry).
function worldmesh.destroyBuild(container: Instance)
	local held = liveMeshes[container]
	liveMeshes[container] = nil
	if held then
		for _, m in held do
			m:Destroy()
		end
	end
	-- EditableImages share the same budget-starvation failure mode: parts
	-- reference them via Content, so nothing destroys them until GC — long
	-- sessions starved texture/anim-frame creation (e.g. +slip chains
	-- silently losing their animation)
	local imgs = liveImages[container]
	liveImages[container] = nil
	if imgs then
		for _, img in imgs do
			img:Destroy()
		end
	end
	container:Destroy()
end

local function retainImage(container: Instance, img: EditableImage)
	local list = liveImages[container]
	if not list then
		list = {}
		liveImages[container] = list
	end
	table.insert(list, img)
end

export type BuiltModel = {
	folder: Model,
	-- parts positioned assuming entity origin (0,0,0); reposition by setting
	-- the folder's pivot offset from the build origin
	center: Vector3,
}

-- Lightstyle handling: surfaces carry up to MAXLIGHTMAPS (4) style layers
-- of lightmap samples, stored consecutively. Style values animate at 10Hz
-- from the style strings ('a'=0 .. 'z'≈2x, value = (c-'a')*22; style 0 is
-- the constant "m" = 264).
worldmesh.BASE_STYLE_VALUE = 264

-- Sample all style layers for a surface at texture coords (s, t).
-- Returns nil for unlit surfaces (sky/water/fullbright), else an array of
-- { style, sample } pairs.
local function sampleLightStyles(data: bsp.BspData, surf: bsp.Surface, s: number, t: number): { { number } }?
	if bit32.band(surf.flags, bsp.SURF_DRAWTILED) ~= 0 then
		return nil -- sky/water: no lightmap, fullbright
	end
	local lightdata = data.lightdata
	if not lightdata or surf.lightofs < 0 then
		return nil -- no light data: fullbright (matches software renderer)
	end

	local smax = bit32.rshift(surf.extents[1], 4) + 1
	local tmax = bit32.rshift(surf.extents[2], 4) + 1
	local ls = math.clamp(math.floor((s - surf.texturemins[1]) / 16 + 0.5), 0, smax - 1)
	local lt = math.clamp(math.floor((t - surf.texturemins[2]) / 16 + 0.5), 0, tmax - 1)

	local out = {}
	local blockSize = smax * tmax
	for layer = 1, 4 do
		local style = surf.styles[layer]
		if style == 255 then
			break
		end
		local ofs = surf.lightofs + (layer - 1) * blockSize + lt * smax + ls
		if ofs >= buffer.len(lightdata) then
			break
		end
		table.insert(out, { style, buffer.readu8(lightdata, ofs) })
	end
	return out
end

-- Combine style layers into 0..1 brightness given a per-style value lookup
-- (blocklights accumulation: sum(sample * value / 256), then overbright x2).
function worldmesh.combineLight(layers: { { number } }?, styleValue: (style: number) -> number): number
	if not layers then
		return 1
	end
	local total = 0
	for _, sv in layers do
		total += sv[2] * styleValue(sv[1]) / 256
	end
	-- overbright x2 then gamma-brighten toward the DOS look
	local linear = math.min(total * 2, 255) / 255
	return linear ^ 0.7
end
local combineLight = worldmesh.combineLight

local function baseStyleValue(_style: number): number
	return worldmesh.BASE_STYLE_VALUE
end

-- Per-map light atlas (the software surface cache). resetLighting must be
-- called before building a map's meshes; brush submodels built later share
-- the same atlas so doors/plats keep their lightmaps.
local currentAtlas: lightatlaslib.Atlas? = nil
local currentStyleValue: (number) -> number = baseStyleValue

function worldmesh.resetLighting(styleValue: (number) -> number)
	if currentAtlas then
		lightatlaslib.destroy(currentAtlas)
	end
	currentAtlas = lightatlaslib.new()
	currentStyleValue = styleValue
end

-- debug hook (RQDBG): expose the live atlas + style fn for Studio probing
function worldmesh._debug(): (lightatlaslib.Atlas?, (number) -> number)
	return currentAtlas, currentStyleValue
end

function worldmesh.updateLightStyles(changed: { [number]: boolean })
	if currentAtlas then
		lightatlaslib.updateStyles(currentAtlas, currentStyleValue, changed)
	end
end

function worldmesh.updateDlights(data: bsp.BspData, dlights: { lightatlaslib.Dlight })
	if currentAtlas then
		lightatlaslib.updateDlights(currentAtlas, data, dlights, currentStyleValue)
	end
end

-- Animated textures registered during builds; the client takes and owns
-- them (worldmesh.takeTextureAnims). turb/sky rewrite their image every
-- tick; "wall" (+N miptex chains, R_TextureAnimation) swaps the chunk
-- MeshParts' TextureContent between prebuilt per-frame images.
export type TextureAnim = {
	kind: string, -- "turb" | "sky" | "wall"
	img: EditableImage,
	pixels: buffer,
	w: number,
	h: number,
	-- "wall" only:
	base: bsp.Texture?, -- chain entry the surfaces were compiled with
	frames: { [string]: EditableImage }?, -- texture name -> image (base + alt chains)
	parts: { MeshPart }?, -- chunks textured by this miptex
	current: string?, -- name of the frame currently applied
}
worldmesh.textureAnims = {} :: { TextureAnim }

function worldmesh.takeTextureAnims(): { TextureAnim }
	local t = worldmesh.textureAnims
	worldmesh.textureAnims = {}
	return t
end

-- One animated vertex color: recomputed when its styles' values change.
export type AnimEntry = {
	em: EditableMesh,
	cid: number,
	layers: { { number } }, -- { {style, sample}, ... }
}

-- Build MeshParts for one brush model. Returns a Model containing one
-- MeshPart per texture batch. Vertex positions are relative to the quake
-- origin so the caller can position the whole Model by entity origin.
function worldmesh.build(model: bsp.Model, pal: textures.Palette, parent: Instance, name: string): (Model, { AnimEntry })
	local animOut: { AnimEntry } = {}
	if not worldmesh.canUseMeshApi() then
		return worldmesh.buildWedges(model, pal, parent, name), animOut
	end
	local data = model.brush

	-- group surfaces by texture
	local byTexture: { [number]: { bsp.Surface } } = {}
	for i = 0, model.nummodelsurfaces - 1 do
		local surf = data.surfaces[model.firstmodelsurface + i + 1]
		local ti = data.texinfo[surf.texinfonum + 1]
		local list = byTexture[ti.miptex]
		if not list then
			list = {}
			byTexture[ti.miptex] = list
		end
		table.insert(list, surf)
	end

	local container = Instance.new("Model")
	container.Name = name

	-- shared per-texture images; turb/sky textures register for animation
	local texImages: { [number]: EditableImage? } = {}
	local function textureImage(miptex: number): EditableImage?
		local tex = data.textures[miptex + 1]
		if not tex then
			return nil
		end
		if texImages[miptex] ~= nil then
			return texImages[miptex]
		end
		-- non-pow2 textures render BLACK on MeshParts; resample up like
		-- GLQuake so tiling UVs stay valid (see textures.resamplePixelsPow2)
		local rpix, rw, rh = textures.resamplePixelsPow2(tex.pixels, tex.width, tex.height)
		local img = textures.createImage(rpix, rw, rh, pal, false)
		texImages[miptex] = img
		if img then
			retainImage(container, img)
		end
		if img then
			local first = tex.name:sub(1, 1)
			if rw ~= tex.width or rh ~= tex.height then
				-- turb/sky pumps WritePixels at the original dims; id1 has
				-- no non-pow2 turb/sky, so just stay static if one appears
				if first == "*" or tex.name:sub(1, 3) == "sky" then
					warn(`[robloquake] non-pow2 animated texture {tex.name}; stays static`)
				end
			elseif first == "*" then
				table.insert(worldmesh.textureAnims, { kind = "turb", img = img, pixels = tex.pixels, w = tex.width, h = tex.height })
			elseif tex.name:sub(1, 3) == "sky" then
				table.insert(worldmesh.textureAnims, { kind = "sky", img = img, pixels = tex.pixels, w = tex.width, h = tex.height })
			end
		end
		return img
	end

	type FaceData = { pos: { Vector3 }, uv: { Vector2 } }
	local MAX_BATCH_VERTS = 50000 -- stay under the 60k EditableMesh cap

	-- generic chunked mesh builder: positions+uvs -> MeshParts in container
	local function buildChunks(faces: { FaceData }, partName: string, img: EditableImage?, fallbackColor: Color3?, translucentMap: boolean, partsOut: { MeshPart }?)
		local chunk: { FaceData } = {}
		local chunkVerts = 0

		local function flushChunk()
			if #chunk == 0 then
				return
			end
			local batch = chunk
			chunk = {}
			chunkVerts = 0

			local em = AssetService:CreateEditableMesh()
			if not em then
				warn("[robloquake] EditableMesh budget exhausted; skipping batch")
				return
			end

			local mins = Vector3.new(math.huge, math.huge, math.huge)
			local maxs = -mins
			for _, fd in batch do
				for _, rp in fd.pos do
					mins = mins:Min(rp)
					maxs = maxs:Max(rp)
				end
			end
			local center = (mins + maxs) / 2

			for _, fd in batch do
				local vids = {}
				local uvids = {}
				for i, rp in fd.pos do
					table.insert(vids, em:AddVertex(rp - center))
					table.insert(uvids, em:AddUV(fd.uv[i]))
				end
				-- quake winds clockwise from the front; roblox fronts are CCW
				for k = 3, #vids do
					local fid = em:AddTriangle(vids[1], vids[k], vids[k - 1])
					em:SetFaceUVs(fid, { uvids[1], uvids[k], uvids[k - 1] })
				end
			end

			-- fixed-size copy releases the 60k-vertex reservation; if the
			-- budget can't fit the copy, keep rendering from the dynamic
			-- mesh rather than dropping the batch (a hole in the world)
			local ok, fixedOrErr = pcall(function()
				return AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
			end)
			local fixed: EditableMesh
			if ok and fixedOrErr then
				em:Destroy()
				fixed = fixedOrErr :: EditableMesh
			else
				warn(`[robloquake] fixed mesh copy failed for {partName} (rendering dynamic): {fixedOrErr}`)
				fixed = em
			end

			local ok2, partOrErr = pcall(function()
				return AssetService:CreateMeshPartAsync(Content.fromObject(fixed))
			end)
			if not ok2 then
				fixed:Destroy()
				warn(`[robloquake] mesh build failed for {partName}: {partOrErr}`)
				return
			end
			local part = partOrErr :: MeshPart
			retainMesh(container, fixed)

			part.Name = partName
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.SmoothPlastic

			if img then
				-- both passes ride TextureContent; the overlay/fullbright
				-- images carry alpha which MeshPart textures blend
				-- (SurfaceAppearance content props are plugin-gated at runtime)
				part.TextureContent = Content.fromObject(img)
				if translucentMap then
					-- epsilon transparency forces the translucent render
					-- queue, where texture alpha blends per-texel (the
					-- opaque queue alpha-tests instead)
					part.Transparency = 0.02
					part.Color = Color3.new(1, 1, 1)
				end
			elseif fallbackColor then
				part.Color = fallbackColor
			end

			-- CreateMeshPartAsync centers geometry on the part; restore
			-- placement from this chunk's bounding box center
			part.CFrame = CFrame.new(center)
			part.Parent = container
			if partsOut then
				table.insert(partsOut, part)
			end
		end

		for _, fd in faces do
			if chunkVerts + #fd.pos > MAX_BATCH_VERTS then
				flushChunk()
			end
			table.insert(chunk, fd)
			chunkVerts += #fd.pos
		end
		flushChunk()
	end

	-- overlay faces grouped by atlas page; fullbright faces by texture
	local overlayByPage: { [number]: { FaceData } } = {}
	local fbFaces: { [number]: { FaceData } } = {}
	local fbImages: { [number]: EditableImage? } = {}
	local atlas = currentAtlas

	for miptex, surfs in byTexture do
		local tex = data.textures[miptex + 1]
		local faceList: { FaceData } = {}

		for _, surf in surfs do
			local ti = data.texinfo[surf.texinfonum + 1]
			local vecs = ti.vecs
			local texW = if tex then tex.width else 64
			local texH = if tex then tex.height else 64

			-- surface normal for overlay offset (lightmap floats 1 unit in
			-- front of the face; fullbright pixels 2)
			local plane = data.planes[surf.planenum + 1]
			local normal = plane.normal
			if bit32.band(surf.flags, bsp.SURF_PLANEBACK) ~= 0 then
				normal = -normal
			end

			local region = if atlas then lightatlaslib.alloc(atlas, data, surf, currentStyleValue) else nil

			local fd: FaceData = { pos = {}, uv = {} }
			local ofd: FaceData? = if region then { pos = {}, uv = {} } else nil
			for e = 0, surf.numedges - 1 do
				local se = data.surfedges[surf.firstedge + e + 1]
				local v: vector
				if se >= 0 then
					v = data.vertexes[data.edges0[se + 1] + 1]
				else
					v = data.vertexes[data.edges1[-se + 1] + 1]
				end

				local sc = v.x * vecs[1] + v.y * vecs[2] + v.z * vecs[3] + vecs[4]
				local tc = v.x * vecs[5] + v.y * vecs[6] + v.z * vecs[7] + vecs[8]

				table.insert(fd.pos, qcoords.toRoblox(v))
				table.insert(fd.uv, Vector2.new(sc / texW, tc / texH))

				if ofd and region then
					local ls = (sc - surf.texturemins[1]) / 16
					local lt = (tc - surf.texturemins[2]) / 16
					local u, vv = lightatlaslib.uv(region, ls, lt)
					table.insert(ofd.pos, qcoords.toRoblox(v + normal))
					table.insert(ofd.uv, Vector2.new(u, vv))
				end
			end
			table.insert(faceList, fd)

			if ofd and region then
				local list = overlayByPage[region.page]
				if not list then
					list = {}
					overlayByPage[region.page] = list
				end
				table.insert(list, ofd)

				-- fullbright pixels reassert above the darkness overlay
				if tex then
					if fbImages[miptex] == nil then
						local fpix, fw, fh = textures.resamplePixelsPow2(tex.pixels, tex.width, tex.height)
						local fb = textures.createFullbrightImage(fpix, fw, fh, pal)
						if fb then
							retainImage(container, fb)
						end
						fbImages[miptex] = fb or false :: any
					end
					if fbImages[miptex] then
						local fbd: FaceData = { pos = {}, uv = {} }
						for i, rp in fd.pos do
							-- re-derive from quake vertex: fd.pos is transformed;
							-- offset 2 units along the normal in quake space
							fbd.pos[i] = rp + qcoords.toRoblox(normal * 2) - qcoords.toRoblox(vector.zero)
							fbd.uv[i] = fd.uv[i]
						end
						local flist = fbFaces[miptex]
						if not flist then
							flist = {}
							fbFaces[miptex] = flist
						end
						table.insert(flist, fbd)
					end
				end
			end
		end

		-- +N miptex chains register for R_TextureAnimation frame swaps;
		-- prebuild one image per chain texture (base and alternate)
		local img = textureImage(miptex)
		local wallParts: { MeshPart }? = nil
		if img and tex and tex.anim_total > 0 then
			local frames: { [string]: EditableImage } = { [tex.name] = img }
			local visited: { [bsp.Texture]: boolean } = {}
			local function walk(start: bsp.Texture?): boolean
				local t = start
				while t and not visited[t] do
					visited[t] = true
					if not frames[t.name] then
						local apix, aw, ah = textures.resamplePixelsPow2(t.pixels, t.width, t.height)
						local fimg = textures.createImage(apix, aw, ah, pal, false)
						if not fimg then
							warn(`[robloquake] anim frame image failed for {t.name}; chain stays static`)
							return false -- image budget exhausted; stay on the base frame
						end
						retainImage(container, fimg)
						frames[t.name] = fimg
					end
					t = t.anim_next
				end
				return true
			end
			if walk(tex) and walk(tex.alternate_anims) then
				wallParts = {}
				table.insert(worldmesh.textureAnims, {
					kind = "wall",
					img = img,
					pixels = tex.pixels,
					w = tex.width,
					h = tex.height,
					base = tex,
					frames = frames,
					parts = wallParts,
				})
			end
		end

		buildChunks(
			faceList,
			if tex then tex.name else tostring(miptex),
			img,
			if tex then textures.averageColor(tex.pixels, tex.width * tex.height, pal) else Color3.fromRGB(128, 128, 128),
			false,
			wallParts
		)
	end

	-- the darkness overlay: black pages with alpha = 1 - brightness
	if atlas then
		for pi, faces in overlayByPage do
			local img = lightatlaslib.pageImage(atlas, pi)
			if img then
				buildChunks(faces, `lightmap{pi}`, img, nil, true)
			end
		end
	end
	for miptex, faces in fbFaces do
		local img = fbImages[miptex]
		if img then
			buildChunks(faces, `fullbright{miptex}`, img :: EditableImage, nil, true)
		end
	end

	if atlas then
		lightatlaslib.flushPages(atlas)
	end

	container.Parent = parent
	return container, animOut
end

-- Fallback when the Mesh & Image APIs are disabled: draw every face as
-- wedge-part triangles tinted by texture average color and lightmap level.
function worldmesh.buildWedges(model: bsp.Model, pal: textures.Palette, parent: Instance, name: string): Model
	local data = model.brush
	local container = Instance.new("Model")
	container.Name = name

	local texColors: { [number]: Color3 } = {}

	for i = 0, model.nummodelsurfaces - 1 do
		local surf = data.surfaces[model.firstmodelsurface + i + 1]
		local ti = data.texinfo[surf.texinfonum + 1]
		local tex = data.textures[ti.miptex + 1]

		local base = texColors[ti.miptex]
		if not base then
			base = if tex
				then textures.averageColor(tex.pixels, tex.width * tex.height, pal)
				else Color3.fromRGB(128, 128, 128)
			texColors[ti.miptex] = base
		end

		-- average lightmap level across the face
		local vecs = ti.vecs
		local verts: { Vector3 } = {}
		local lightSum, lightN = 0, 0
		for e = 0, surf.numedges - 1 do
			local se = data.surfedges[surf.firstedge + e + 1]
			local v: vector
			if se >= 0 then
				v = data.vertexes[data.edges0[se + 1] + 1]
			else
				v = data.vertexes[data.edges1[-se + 1] + 1]
			end
			local s = v.x * vecs[1] + v.y * vecs[2] + v.z * vecs[3] + vecs[4]
			local t = v.x * vecs[5] + v.y * vecs[6] + v.z * vecs[7] + vecs[8]
			lightSum += combineLight(sampleLightStyles(data, surf, s, t), baseStyleValue)
			lightN += 1
			table.insert(verts, qcoords.toRoblox(v))
		end
		local light = if lightN > 0 then lightSum / lightN else 1
		local color = Color3.new(base.R * light, base.G * light, base.B * light)

		for k = 3, #verts do
			tris.draw(verts[1], verts[k - 1], verts[k], color, container)
		end
	end

	container.Parent = parent
	return container
end

return worldmesh
