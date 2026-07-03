--!strict
--!optimize 2
-- Texture conversion: Quake 8-bit palettized pixels -> EditableImages.

local AssetService = game:GetService("AssetService")

local textures = {}

-- probe once: are the Mesh & Image APIs available at this security level?
local meshApiAvailable: boolean? = nil
function textures.canUseMeshApi(): boolean
	if meshApiAvailable == nil then
		meshApiAvailable = pcall(function()
			local em = AssetService:CreateEditableMesh()
			local v1 = em:AddVertex(Vector3.zero)
			local v2 = em:AddVertex(Vector3.xAxis)
			local v3 = em:AddVertex(Vector3.yAxis)
			em:AddTriangle(v1, v2, v3)
			AssetService:CreateMeshPartAsync(Content.fromObject(em))
		end)
		if not meshApiAvailable then
			warn("[robloquake] Mesh & Image APIs are disabled — using fallback rendering. Enable them in Game Settings → Security for full visuals.")
		end
	end
	return meshApiAvailable :: boolean
end

export type Palette = { r: { number }, g: { number }, b: { number } }

-- gfx/palette.lmp -> arrays (mirrors wad.parsePalette; duplicated here so
-- the render layer doesn't depend on the wad module)
function textures.parsePalette(data: buffer): Palette
	local pr = table.create(256)
	local pg = table.create(256)
	local pb = table.create(256)
	for i = 0, 255 do
		pr[i + 1] = buffer.readu8(data, i * 3)
		pg[i + 1] = buffer.readu8(data, i * 3 + 1)
		pb[i + 1] = buffer.readu8(data, i * 3 + 2)
	end
	return { r = pr, g = pg, b = pb }
end

-- Convert palettized pixels to an RGBA8 buffer. Index 255 is transparent
-- when `alphaIndex` is true (sprites, HUD pics).
function textures.toRGBA(pixels: buffer, count: number, pal: Palette, alphaIndex: boolean): buffer
	local out = buffer.create(count * 4)
	local pr, pg, pb = pal.r, pal.g, pal.b
	for i = 0, count - 1 do
		local p = buffer.readu8(pixels, i)
		local o = i * 4
		buffer.writeu8(out, o, pr[p + 1])
		buffer.writeu8(out, o + 1, pg[p + 1])
		buffer.writeu8(out, o + 2, pb[p + 1])
		buffer.writeu8(out, o + 3, if alphaIndex and p == 255 then 0 else 255)
	end
	return out
end

-- Create an EditableImage from palettized pixels. Returns nil when the
-- Mesh & Image APIs are not enabled for the experience (Game Settings →
-- Security); callers must tolerate untextured output.
function textures.createImage(pixels: buffer, width: number, height: number, pal: Palette, alphaIndex: boolean): EditableImage?
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
		local rgba = textures.toRGBA(pixels, width * height, pal, alphaIndex)
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), rgba)
		return image
	end)
	if not ok then
		return nil
	end
	return img
end

-- Player color translation (CL_NewTranslation): shirt row 16-31 and pants
-- row 96-111 are remapped from the top/bottom color ranges. Backwards
-- ranges (>= 128) are reversed.
function textures.translatePixels(pixels: buffer, count: number, colors: number): buffer
	local top = bit32.band(colors, 0xf0)
	local bottom = bit32.lshift(bit32.band(colors, 15), 4)
	local translate = table.create(256)
	for i = 0, 255 do
		translate[i + 1] = i
	end
	for i = 0, 15 do
		if top < 128 then
			translate[16 + i + 1] = top + i
		else
			translate[16 + i + 1] = top + 15 - i
		end
		if bottom < 128 then
			translate[96 + i + 1] = bottom + i
		else
			translate[96 + i + 1] = bottom + 15 - i
		end
	end
	local out = buffer.create(count)
	for i = 0, count - 1 do
		buffer.writeu8(out, i, translate[buffer.readu8(pixels, i) + 1])
	end
	return out
end

-- Average color of a palettized image (fallback tint when images are
-- unavailable).
function textures.averageColor(pixels: buffer, count: number, pal: Palette): Color3
	local r, g, b = 0, 0, 0
	local step = math.max(1, math.floor(count / 256))
	local n = 0
	for i = 0, count - 1, step do
		local p = buffer.readu8(pixels, i)
		r += pal.r[p + 1]
		g += pal.g[p + 1]
		b += pal.b[p + 1]
		n += 1
	end
	return Color3.fromRGB(r / n, g / n, b / n)
end

return textures
