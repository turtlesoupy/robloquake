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

export type BuiltModel = {
	folder: Model,
	-- parts positioned assuming entity origin (0,0,0); reposition by setting
	-- the folder's pivot offset from the build origin
	center: Vector3,
}

-- Sample the lightmap for a surface at texture coordinates (s, t).
-- Returns 0..1 brightness (style 0 only; animated styles are approximated
-- by their base value).
local function sampleLight(data: bsp.BspData, surf: bsp.Surface, s: number, t: number): number
	if bit32.band(surf.flags, bsp.SURF_DRAWTILED) ~= 0 then
		return 1 -- sky/water: no lightmap, fullbright
	end
	local lightdata = data.lightdata
	if not lightdata or surf.lightofs < 0 then
		return 1 -- no light data: fullbright (matches software renderer)
	end

	local smax = bit32.rshift(surf.extents[1], 4) + 1
	local tmax = bit32.rshift(surf.extents[2], 4) + 1
	local ls = math.clamp(math.floor((s - surf.texturemins[1]) / 16 + 0.5), 0, smax - 1)
	local lt = math.clamp(math.floor((t - surf.texturemins[2]) / 16 + 0.5), 0, tmax - 1)

	local ofs = surf.lightofs + lt * smax + ls
	if ofs >= buffer.len(lightdata) then
		return 1
	end
	local sample = buffer.readu8(lightdata, ofs)
	-- roughly GLQuake's overbright handling: 128 is "fully lit"
	return math.min(sample * 2, 255) / 255
end

-- Build MeshParts for one brush model. Returns a Model containing one
-- MeshPart per texture batch. Vertex positions are relative to the quake
-- origin so the caller can position the whole Model by entity origin.
function worldmesh.build(model: bsp.Model, pal: textures.Palette, parent: Instance, name: string): Model
	if not worldmesh.canUseMeshApi() then
		return worldmesh.buildWedges(model, pal, parent, name)
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

		for _, surf in surfs do
			local ti = data.texinfo[surf.texinfonum + 1]
			local vecs = ti.vecs
			local texW = if tex then tex.width else 64
			local texH = if tex then tex.height else 64

			-- gather the polygon's vertices
			local vids = {}
			local uvids = {}
			local cids = {}
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

				table.insert(vids, em:AddVertex(qcoords.toRoblox(v)))
				table.insert(uvids, em:AddUV(Vector2.new(s / texW, t / texH)))
				local light = sampleLight(data, surf, s, t)
				table.insert(cids, em:AddColor(Color3.new(light, light, light), 1))
			end

			-- fan triangulation; quake polys wind clockwise viewed from
			-- the front, which lands correctly in roblox's convention
			-- after the handedness flip
			for k = 3, #vids do
				local fid = em:AddTriangle(vids[1], vids[k - 1], vids[k])
				em:SetFaceUVs(fid, { uvids[1], uvids[k - 1], uvids[k] })
				em:SetFaceColors(fid, { cids[1], cids[k - 1], cids[k] })
			end
		end

		local ok, partOrErr = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(em))
		end)
		if not ok then
			warn(`[robloquake] mesh build failed for texture {miptex}: {partOrErr}`)
			continue
		end
		local part = partOrErr :: MeshPart
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
		local mins, maxs = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, vid in em:GetVertices() do
			local p = em:GetPosition(vid)
			mins = mins:Min(p)
			maxs = maxs:Max(p)
		end
		part.CFrame = CFrame.new((mins + maxs) / 2)
		part.Parent = container
	end

	container.Parent = parent
	return container
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
			lightSum += sampleLight(data, surf, s, t)
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
