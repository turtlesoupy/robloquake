--!strict
--!optimize 2
-- The conchars console font: 16x16 grid of 8x8 glyphs from gfx.wad, drawn
-- as ImageLabels addressing ONE 128x128 sheet image via ImageRectOffset
-- (Draw_Character semantics; color 0 is transparent). One image for the
-- whole font instead of one per glyph: live EditableImage bindings are a
-- scarce pool (~128) and every bind past the cap renders black.

local textures = require(script.Parent.textures)

local confont = {}

export type Font = {
	sheet: EditableImage?,
	sheetBuilt: boolean,
	conchars: buffer,
	pal: textures.Palette,
}

function confont.new(conchars: buffer, pal: textures.Palette): Font
	return { sheet = nil, sheetBuilt = false, conchars = conchars, pal = pal }
end

-- Build the whole 128x128 sheet once; color 0 -> index 255 (transparent).
local function sheet(f: Font): EditableImage?
	if f.sheetBuilt then
		return f.sheet
	end
	f.sheetBuilt = true
	local out = buffer.create(128 * 128)
	for i = 0, 128 * 128 - 1 do
		local p = buffer.readu8(f.conchars, i)
		buffer.writeu8(out, i, if p == 0 then 255 else p)
	end
	f.sheet = textures.createImage(out, 128, 128, f.pal, true)
	return f.sheet
end

-- Sheet image + pixel rect for a character code; nil when images are
-- unavailable (fallback rendering).
function confont.cell(f: Font, code: number): (EditableImage?, Vector2)
	local img = sheet(f)
	local row = math.floor(code / 16) % 16
	local col = code % 16
	return img, Vector2.new(col * 8, row * 8)
end

confont.CELL = Vector2.new(8, 8)

-- Point an ImageLabel at a glyph (Draw_Character for one cell).
function confont.apply(f: Font, label: ImageLabel, code: number): boolean
	local img, off = confont.cell(f, code)
	if not img then
		return false
	end
	label.ImageContent = Content.fromObject(img)
	label.ImageRectOffset = off
	label.ImageRectSize = confont.CELL
	return true
end

export type TextRow = {
	labels: { ImageLabel },
	text: string,
}

-- A fixed-capacity row of character cells at 8px pitch (scaled).
function confont.newRow(parent: Instance, cols: number, scale: number): TextRow
	local labels = table.create(cols)
	for i = 1, cols do
		local l = Instance.new("ImageLabel")
		l.BackgroundTransparency = 1
		l.ResampleMode = Enum.ResamplerMode.Pixelated
		l.Size = UDim2.fromOffset(8 * scale, 8 * scale)
		l.Position = UDim2.fromOffset((i - 1) * 8 * scale, 0)
		l.Visible = false
		l.Parent = parent
		labels[i] = l
	end
	return { labels = labels, text = "" }
end

-- Draw a string into the row. Bytes are used as-is so high-bit (bronze)
-- Quake text renders with the correct glyphs.
function confont.setRow(f: Font, row: TextRow, text: string)
	if row.text == text then
		return
	end
	row.text = text
	for i, label in row.labels do
		local code = text:byte(i)
		if code and code ~= 32 then
			label.Visible = confont.apply(f, label, code)
		else
			label.Visible = false
		end
	end
end

return confont
