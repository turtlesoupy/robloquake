--!strict
--!optimize 2
-- Texture conversion: Quake 8-bit palettized pixels -> EditableImages.

-- lune runs the pure helpers (translatePixels, parsePalette) offline;
-- there is no `game` there, so resolve AssetService defensively
local gotSvc, svc = pcall(function()
	return game:GetService("AssetService")
end)
local AssetService = (if gotSvc then svc else nil) :: AssetService

local textures = {}

-- probe once: are the Mesh & Image APIs available at this security level?
local meshApiAvailable: boolean? = nil
function textures.canUseMeshApi(): boolean
	if meshApiAvailable == nil then
		local probe: EditableMesh? = nil
		meshApiAvailable = pcall(function()
			local em = AssetService:CreateEditableMesh()
			probe = em
			local v1 = em:AddVertex(Vector3.zero)
			local v2 = em:AddVertex(Vector3.xAxis)
			local v3 = em:AddVertex(Vector3.yAxis)
			em:AddTriangle(v1, v2, v3)
			AssetService:CreateMeshPartAsync(Content.fromObject(em))
		end)
		-- a dynamic EditableMesh reserves the 60k-vertex maximum against
		-- the memory budget; leaking the probe starves world builds
		if probe then
			(probe :: EditableMesh):Destroy()
		end
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

-- Fullbright overlay image: the software colormap keeps palette indices
-- 224-255 at full intensity regardless of light. Returns an image with
-- only those pixels opaque (nil when the texture has none), drawn as an
-- unlit pass above the darkness overlay.
function textures.createFullbrightImage(pixels: buffer, width: number, height: number, pal: Palette): EditableImage?
	local count = width * height
	local any = false
	for i = 0, count - 1 do
		if buffer.readu8(pixels, i) >= 224 then
			any = true
			break
		end
	end
	if not any then
		return nil
	end
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
		local rgba = buffer.create(count * 4)
		for i = 0, count - 1 do
			local p = buffer.readu8(pixels, i)
			if p >= 224 then
				local c = pal[p + 1]
				buffer.writeu8(rgba, i * 4, math.floor(c.R * 255 + 0.5))
				buffer.writeu8(rgba, i * 4 + 1, math.floor(c.G * 255 + 0.5))
				buffer.writeu8(rgba, i * 4 + 2, math.floor(c.B * 255 + 0.5))
				buffer.writeu8(rgba, i * 4 + 3, 255)
			end
		end
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), rgba)
		return image
	end)
	if not ok then
		return nil
	end
	return img
end

-- MeshPart TextureContent silently renders BLACK for non-power-of-two
-- EditableImages (platform constraint found via the black-entities
-- playtest bug: alias skins like the 300x194 soldier). Pad the image up
-- to the next power of two; callers scale their UVs by (w/padW, h/padH).
local function nextPow2(n: number): number
	local p = 1
	while p < n do
		p *= 2
	end
	return p
end

function textures.createImagePow2(pixels: buffer, width: number, height: number, pal: Palette, alphaIndex: boolean): (EditableImage?, number, number)
	local padW, padH = nextPow2(width), nextPow2(height)
	if padW == width and padH == height then
		return textures.createImage(pixels, width, height, pal, alphaIndex), padW, padH
	end
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(padW, padH) })
		local rgba = textures.toRGBA(pixels, width * height, pal, alphaIndex)
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), rgba)
		return image
	end)
	if not ok then
		return nil, padW, padH
	end
	return img, padW, padH
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

-- Turbulent water/lava warp (D_DrawTurbulent look): the texture scrolls
-- through a sine displacement on both axes.
-- pure pixel half (lune-testable); writeTurbFrame uploads it
function textures.turbFramePixels(pixels: buffer, w: number, h: number, pal: Palette, time: number): buffer
	local out = buffer.create(w * h * 4)
	local pr, pg, pb = pal.r, pal.g, pal.b
	local sinx = table.create(w)
	local siny = table.create(h)
	for x = 0, w - 1 do
		sinx[x + 1] = math.floor(8 * math.sin(2 * math.pi * (x / 32) + time * 2) + 0.5)
	end
	for y = 0, h - 1 do
		siny[y + 1] = math.floor(8 * math.sin(2 * math.pi * (y / 32) + time * 2) + 0.5)
	end
	for y = 0, h - 1 do
		local rowOfs = y * w * 4
		for x = 0, w - 1 do
			local sx = (x + siny[y + 1]) % w
			local sy = (y + sinx[x + 1]) % h
			local pidx = buffer.readu8(pixels, sy * w + sx)
			local o = rowOfs + x * 4
			buffer.writeu8(out, o, pr[pidx + 1])
			buffer.writeu8(out, o + 1, pg[pidx + 1])
			buffer.writeu8(out, o + 2, pb[pidx + 1])
			buffer.writeu8(out, o + 3, 255)
		end
	end
	return out
end

function textures.writeTurbFrame(img: EditableImage, pixels: buffer, w: number, h: number, pal: Palette, time: number)
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), textures.turbFramePixels(pixels, w, h, pal, time))
end

-- Scrolling sky: quake sky textures are 256x128 with the front (masked)
-- cloud layer on the left half and the solid background on the right.
-- Both halves of the image are rewritten with the composited scroll so any
-- UV mapping shows moving clouds.
-- pure pixel half (lune-testable); writeSkyFrame uploads it
function textures.skyFramePixels(pixels: buffer, w: number, h: number, pal: Palette, time: number): buffer?
	local half = math.floor(w / 2)
	if half < 1 then
		return nil
	end
	local out = buffer.create(w * h * 4)
	local pr, pg, pb = pal.r, pal.g, pal.b
	local shiftFront = math.floor(time * 16) % half
	local shiftBack = math.floor(time * 8) % half
	for y = 0, h - 1 do
		local rowOfs = y * w * 4
		for x = 0, w - 1 do
			local cx = x % half
			-- front layer (left half of source), palette 0 = transparent
			local fx = (cx + shiftFront) % half
			local pidx = buffer.readu8(pixels, y * w + fx)
			if pidx == 0 then
				local bx = (cx + shiftBack) % half + half
				pidx = buffer.readu8(pixels, y * w + bx)
			end
			local o = rowOfs + x * 4
			buffer.writeu8(out, o, pr[pidx + 1])
			buffer.writeu8(out, o + 1, pg[pidx + 1])
			buffer.writeu8(out, o + 2, pb[pidx + 1])
			buffer.writeu8(out, o + 3, 255)
		end
	end
	return out
end

function textures.writeSkyFrame(img: EditableImage, pixels: buffer, w: number, h: number, pal: Palette, time: number)
	local out = textures.skyFramePixels(pixels, w, h, pal, time)
	if out then
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), out)
	end
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
