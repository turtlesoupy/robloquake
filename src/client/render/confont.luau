--!strict
--!optimize 2
-- The conchars console font: 16x16 grid of 8x8 glyphs from gfx.wad, drawn
-- as one ImageLabel per character cell (Draw_Character semantics; color 0
-- is transparent).

local textures = require(script.Parent.textures)

local confont = {}

export type Font = {
	glyphs: { [number]: EditableImage? },
	conchars: buffer,
	pal: textures.Palette,
}

function confont.new(conchars: buffer, pal: textures.Palette): Font
	return { glyphs = {}, conchars = conchars, pal = pal }
end

function confont.glyph(f: Font, code: number): EditableImage?
	if f.glyphs[code] ~= nil then
		return f.glyphs[code]
	end
	local out = buffer.create(64)
	local row = math.floor(code / 16) % 16
	local col = code % 16
	for y = 0, 7 do
		for x = 0, 7 do
			local p = buffer.readu8(f.conchars, (row * 8 + y) * 128 + col * 8 + x)
			buffer.writeu8(out, y * 8 + x, if p == 0 then 255 else p)
		end
	end
	local img = textures.createImage(out, 8, 8, f.pal, true)
	f.glyphs[code] = img
	return img
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
			local img = confont.glyph(f, code)
			if img then
				label.ImageContent = Content.fromObject(img)
				label.Visible = true
			else
				label.Visible = false
			end
		else
			label.Visible = false
		end
	end
end

return confont
