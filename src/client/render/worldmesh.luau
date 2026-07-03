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

local function retainMesh(container: Instance, em: EditableMesh)
	local list = liveMeshes[container]
	if not list then
		list = {}
		liveMeshes[container] = list
		container.Destroying:Connect(function()
			liveMeshes[container] = nil
		end)
	end
	table.insert(list, em)
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
	return math.min(total * 2, 255) / 255
end
local combineLight = worldmesh.combineLight

local function baseStyleValue(_style: number): number
	return worldmesh.BASE_STYLE_VALUE
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

	for miptex, surfs in byTexture do
		local tex = data.textures[miptex + 1]
		local em = AssetService:CreateEditableMesh()
		if not em then
			-- memory budget exhausted: fall back to wedges for the rest
			warn("[robloquake] EditableMesh budget exhausted; falling back to wedges")
			container:Destroy()
			return worldmesh.buildWedges(model, pal, parent, name), {}
		end

		-- pass 1: gather face data and the batch bounding box
		type FaceData = { pos: { Vector3 }, uv: { Vector2 }, layers: { { { number } }? } }
		local faceList: { FaceData } = {}
		local mins = Vector3.new(math.huge, math.huge, math.huge)
		local maxs = -mins

		for _, surf in surfs do
			local ti = data.texinfo[surf.texinfonum + 1]
			local vecs = ti.vecs
			local texW = if tex then tex.width else 64
			local texH = if tex then tex.height else 64

			local fd: FaceData = { pos = {}, uv = {}, layers = {} }
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

				local rp = qcoords.toRoblox(v)
				mins = mins:Min(rp)
				maxs = maxs:Max(rp)
				table.insert(fd.pos, rp)
				table.insert(fd.uv, Vector2.new(s / texW, t / texH))
				fd.layers[#fd.pos] = sampleLightStyles(data, surf, s, t)
			end
			table.insert(faceList, fd)
		end

		-- pass 2: build the mesh with vertices centered on the batch origin,
		-- so the part pivot (mesh bounds center) is exactly (mins+maxs)/2
		local center = (mins + maxs) / 2
		-- rank = nth AddColor call; used to remap ids onto the fixed copy
		local pendingAnim: { { rank: number, layers: { { number } } } } = {}
		local colorRank = 0
		for _, fd in faceList do
			local vids = {}
			local uvids = {}
			local cids = {}
			for i, rp in fd.pos do
				table.insert(vids, em:AddVertex(rp - center))
				table.insert(uvids, em:AddUV(fd.uv[i]))
				local layers = fd.layers[i]
				local light = combineLight(layers, baseStyleValue)
				local cid = em:AddColor(Color3.new(light, light, light), 1)
				colorRank += 1
				table.insert(cids, cid)
				if layers then
					-- animated if any layer's style is non-zero (style 0 is constant)
					for _, sv in layers do
						if sv[1] ~= 0 then
							table.insert(pendingAnim, { rank = colorRank, layers = layers })
							break
						end
					end
				end
			end
			-- quake winds clockwise from the front; roblox fronts are CCW
			for k = 3, #vids do
				local fid = em:AddTriangle(vids[1], vids[k], vids[k - 1])
				em:SetFaceUVs(fid, { uvids[1], uvids[k], uvids[k - 1] })
				em:SetFaceColors(fid, { cids[1], cids[k], cids[k - 1] })
			end
		end

		-- fixed-size copy releases the 60k-vertex reservation
		local ok, fixedOrErr = pcall(function()
			return AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
		end)
		em:Destroy()
		if not ok or not fixedOrErr then
			warn(`[robloquake] fixed mesh copy failed for texture {miptex}: {fixedOrErr}`)
			continue
		end
		local fixed = fixedOrErr :: EditableMesh

		local ok2, partOrErr = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(fixed))
		end)
		if not ok2 then
			fixed:Destroy()
			warn(`[robloquake] mesh build failed for texture {miptex}: {partOrErr}`)
			continue
		end
		local part = partOrErr :: MeshPart
		retainMesh(container, fixed)

		-- remap animated colors onto the fixed copy: GetColors returns ids in
		-- creation order, so the nth AddColor call maps to newIds[n]
		if #pendingAnim > 0 then
			local newIds = fixed:GetColors()
			for _, entry in pendingAnim do
				local newId = newIds[entry.rank]
				if newId then
					table.insert(animOut, { em = fixed, cid = newId, layers = entry.layers })
				end
			end
		end
		part.Name = if tex then tex.name else tostring(miptex)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic

		if tex then
			local img = textures.createImage(tex.pixels, tex.width, tex.height, pal, false)
			if img then
				part.TextureContent = Content.fromObject(img)
			else
				part.Color = textures.averageColor(tex.pixels, tex.width * tex.height, pal)
			end
		end

		-- CreateMeshPartAsync centers geometry on the part; restore world
		-- placement from the mesh bounding box center
		part.CFrame = CFrame.new((mins + maxs) / 2)
		part.Parent = container
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
