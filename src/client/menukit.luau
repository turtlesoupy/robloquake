--!strict
-- Quake-style UI kit (PRODUCT layer): the gfx/box_*.lmp wood nine-slice
-- and conchars bitmap text, packaged so product UIs OUTSIDE the pause
-- menu (the round-end vote panel in directorui, ...) can draw the same
-- look. Extracted from pausemenu.luau, which still carries its own
-- originals — consolidate pausemenu onto this module the next time its
-- internals are open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)

local confontlib = require(script.Parent.render.confont)
local textures = require(script.Parent.render.textures)

local menukit = {}

local BOXSCALE = 2 -- each box_*.lmp pixel blown up this much
menukit.BOXSCALE = BOXSCALE
menukit.GLYPH = 8 -- conchars cell size in design px (multiply by scale)

-- shared palette accents (pausemenu's)
menukit.ORANGE = Color3.fromRGB(255, 150, 60)
menukit.COOL = Color3.fromRGB(210, 222, 235)
menukit.GREY = Color3.fromRGB(150, 140, 130)

export type BoxImg = { img: EditableImage?, w: number, h: number }
export type Kit = {
	pieces: { [string]: BoxImg },
	font: confontlib.Font?,
}

local BOX_PIECES = { "box_tl", "box_tr", "box_bl", "box_br", "box_tm", "box_bm", "box_ml", "box_mr", "box_mm" }

-- mirror an 8-bit (palette-index) pixel buffer horizontally and/or vertically
local function flipPixels(px: buffer, w: number, h: number, flipH: boolean, flipV: boolean): buffer
	local out = buffer.create(w * h)
	for y = 0, h - 1 do
		local sy = if flipV then h - 1 - y else y
		for x = 0, w - 1 do
			local sx = if flipH then w - 1 - x else x
			buffer.writeu8(out, y * w + x, buffer.readu8(px, sy * w + sx))
		end
	end
	return out
end

local function loadPic(fs: vfslib.Vfs, pal: textures.Palette, name: string, flipH: boolean?, flipV: boolean?): BoxImg
	local buf = vfslib.loadFile(fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return { img = nil, w = 8, h = 8 }
	end
	local pic = wadlib.parseQPic(buf)
	local px = pic.pixels
	if flipH or flipV then
		px = flipPixels(px, pic.width, pic.height, flipH == true, flipV == true)
	end
	local img = textures.createImage(px, pic.width, pic.height, pal, true)
	return { img = img, w = pic.width, h = pic.height }
end

-- box pieces (incl. the mirrored "lit" variants — see pausemenu.luau's
-- nineSlice notes for why every side uses the top-left-lit bevel) + the
-- conchars font, loaded once per boot
function menukit.load(fs: vfslib.Vfs, pal: textures.Palette): Kit
	local pieces: { [string]: BoxImg } = {}
	for _, name in BOX_PIECES do
		pieces[name] = loadPic(fs, pal, name)
	end
	pieces.box_ml_lit_r = loadPic(fs, pal, "box_ml", true, false)
	pieces.box_tm_lit_b = loadPic(fs, pal, "box_tm", false, true)
	pieces.box_tl_lit_tr = loadPic(fs, pal, "box_tl", true, false)
	pieces.box_tl_lit_bl = loadPic(fs, pal, "box_tl", false, true)
	pieces.box_tl_lit_br = loadPic(fs, pal, "box_tl", true, true)

	local font: confontlib.Font? = nil
	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	if wadbuf then
		local w = wadlib.load(wadbuf)
		local ok, conchars = pcall(wadlib.getRaw, w, "conchars")
		if ok then
			font = confontlib.new(conchars, pal)
		end
	end
	return { pieces = pieces, font = font }
end

-- one tiling/stretched slice of a nine-slice
local function slice(parent: Instance, box: BoxImg, tile: boolean, x: number, y: number, w: number, h: number): ImageLabel
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.ResampleMode = Enum.ResamplerMode.Pixelated
	l.Position = UDim2.fromOffset(x, y)
	l.Size = UDim2.fromOffset(w, h)
	if box.img then
		l.ImageContent = Content.fromObject(box.img)
	end
	if tile then
		l.ScaleType = Enum.ScaleType.Tile
		l.TileSize = UDim2.fromOffset(box.w * BOXSCALE, box.h * BOXSCALE)
	end
	l.Parent = parent
	return l
end

-- box_*.lmp border ring into `parent` (which is `w`x`h`), lit uniformly on
-- all four sides; `center` paints the box_mm wood fill on top of the ring,
-- stopping at the shadow line (see pausemenu.luau for the full rationale)
function menukit.nineSlice(kit: Kit, parent: GuiObject, w: number, h: number, center: boolean)
	local pieces = kit.pieces
	local cw = pieces.box_tl.w * BOXSCALE
	local ch = pieces.box_tl.h * BOXSCALE
	slice(parent, pieces.box_tm, false, cw, 0, w - 2 * cw, ch)
	slice(parent, pieces.box_tm_lit_b, false, cw, h - ch, w - 2 * cw, ch)
	slice(parent, pieces.box_ml, false, 0, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_ml_lit_r, false, w - cw, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_tl, false, 0, 0, cw, ch)
	slice(parent, pieces.box_tl_lit_tr, false, w - cw, 0, cw, ch)
	slice(parent, pieces.box_tl_lit_bl, false, 0, h - ch, cw, ch)
	slice(parent, pieces.box_tl_lit_br, false, w - cw, h - ch, cw, ch)
	if center then
		local ins = 6 * BOXSCALE
		local fw, fh = w - 2 * ins, h - 2 * ins
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.ClipsDescendants = true
		holder.Position = UDim2.fromOffset(ins, ins)
		holder.Size = UDim2.fromOffset(fw, fh)
		holder.Parent = parent
		slice(holder, pieces.box_mm, true, 0, 0, fw, fh)
	end
end

-- draw one conchars line at (x,y); align 0 left / 0.5 centre / 1 right
-- within [x, x+wspan]. Falls back to a stock TextLabel without the font.
function menukit.text(
	kit: Kit,
	parent: Instance,
	x: number,
	y: number,
	str: string,
	scale: number,
	color: Color3?,
	wspan: number?,
	align: number?
): Frame
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(math.max(#str, 1) * 8 * scale, 8 * scale)
	local px = x
	if wspan and align then
		px = x + (wspan - #str * 8 * scale) * align
	end
	holder.Position = UDim2.fromOffset(math.floor(px), y)
	holder.ZIndex = 4
	holder.Parent = parent
	local col = color or menukit.COOL
	local f = kit.font
	if f then
		local row = confontlib.newRow(holder, math.max(#str, 1), scale)
		confontlib.setRow(f, row, str)
		for _, lbl in row.labels do
			lbl.ImageColor3 = col
			lbl.ZIndex = 4
		end
	else
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.Code
		lbl.TextScaled = true
		lbl.TextColor3 = col
		lbl.Text = str
		lbl.Parent = holder
	end
	return holder
end

return menukit
