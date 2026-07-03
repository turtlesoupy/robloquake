--!strict
--!optimize 2
-- Texture conversion: Quake 8-bit palettized pixels -> EditableImages.

local AssetService = game:GetService("AssetService")

local textures = {}

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

-- Create an EditableImage from palettized pixels.
function textures.createImage(pixels: buffer, width: number, height: number, pal: Palette, alphaIndex: boolean): EditableImage
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	local rgba = textures.toRGBA(pixels, width * height, pal, alphaIndex)
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), rgba)
	return img
end

return textures
