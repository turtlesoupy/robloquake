--!strict
-- Pause menu (PRODUCT layer, NOT engine): the game's "menu" overlay opened
-- with E or the top-right MENU plaque (this file also owns the always-on
-- MENU/SCORE plaques next to the director gear). The world keeps simulating
-- while it is up (Roblox multiplayer never pauses); we only drop an 80%
-- black scrim over it.
--
-- REMOVAL: delete this file plus the two attach blocks (search "pause menu"
-- in src/client/init.client.luau and src/client/qwclient.luau), the MENU
-- FONT toggle in src/client/tweaksui.luau, src/client/menuicons.luau, and
-- tools/build_menuicons.py.
--
-- Design: a fixed "content box" (836x408 design px, scaled to the viewport)
-- subdivided into cells with 12px spacers. Every page shares the same
-- title-on-top / button-on-bottom framing and picks a layout:
--   main      hero + 4 blocks   (profile, GAMEMODES, SHOP, FRIENDS, SETTINGS)
--   settings  1 full block
--   gamemodes 2-up
--   shop      3-up daily cards  (rarity, weapon render, FRAGS + ROBUX buttons)
--   skins     8-grid            (weapon render + APPLY, in-grid pager arrows)
-- Cells are the Quake gfx/box_*.lmp nine-slice (border + tiled fill); cell
-- content lives INSIDE the panel frame so the press pulse scales the whole
-- card. Text is the conchars bitmap font tinted via ImageColor3 (the
-- tweaks-menu toggle swaps small cool-white "classic" — the default — for
-- large orange "plaque"). Weapon cards render the real v_rock2.mdl rocket
-- launcher with skinforge skins in a ViewportFrame, one baked mesh cloned
-- per card. The shop rotates daily: three picks (common/rare/legendary from
-- a fixed rarity split) seeded by the UTC day number, with a live countdown.
-- Clicks anywhere outside the interactive bits trigger the bottom action.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)
local mdllib = require(engine.models.mdl)

local textures = require(script.Parent.render.textures)
local confontlib = require(script.Parent.render.confont)
local entrender = require(script.Parent.render.entrender)
local skinforge = require(script.Parent.render.skinforge)
local menuicons = require(script.Parent.menuicons)

local pausemenu = {}

-- design-space geometry (scaled to the viewport by a UIScale) --------------
local BOX_W, BOX_H, GAP = 836, 408, 6
-- the cell grid renders ~10% smaller than its 836x408 slot (boxes shrink,
-- gaps/title/bottom-nav keep their size), centred in the slot
local GRID_W, GRID_H = 754, 368
local GRID_X = (BOX_W - GRID_W) / 2
local TITLE_H, BTN_H = 48, 52
local BOX_Y = TITLE_H + GAP + (BOX_H - GRID_H) / 2
local CANVAS_W = BOX_W
local CANVAS_H = TITLE_H + GAP + BOX_H + GAP + BTN_H
local BOTTOM_Y = TITLE_H + GAP + BOX_H + GAP
local BOXSCALE = 2 -- each box_*.lmp pixel blown up this much
local CARD_BTN_H = 46 -- full-bleed card button height

local BOX_PIECES = { "box_tl", "box_tr", "box_bl", "box_br", "box_tm", "box_bm", "box_ml", "box_mr", "box_mm" }

local RARITY_GREY = Color3.fromRGB(150, 140, 130)
local ROBUX_GLYPH = "rbxasset://textures/ui/common/robux.png" -- built-in Roblox icon

-- The conchars glyphs are white on transparent, so ImageColor3 tints them.
-- "classic" (default) = smaller cool-white; "big" = large orange plaque.
export type FontStyle = { color: Color3, title: number, head: number, body: number }
local ORANGE = Color3.fromRGB(255, 150, 60)
local COOL = Color3.fromRGB(210, 222, 235)
local BIG_FONT: FontStyle = { color = ORANGE, title = 4, head = 2, body = 2 }
local CLASSIC_FONT: FontStyle = { color = COOL, title = 3, head = 2, body = 2 }

-- shop rarity tiers (prices per tier; picks rotate daily)
local RARITIES = {
	{ name = "COMMON", frags = 50, robux = 49 },
	{ name = "RARE", frags = 150, robux = 99 },
	{ name = "LEGENDARY", frags = 1000, robux = 199 },
}

export type Handle = {
	toggle: () -> (),
	isOpen: () -> boolean,
	setBigFont: (on: boolean) -> (),
	isBigFont: () -> boolean,
}

export type Opts = {
	playerGui: Instance,
	fs: vfslib.Vfs,
	pal: textures.Palette,
	isTyping: () -> boolean,
	onUiToggle: ((open: boolean) -> ())?,
	onReturnToGame: (() -> ())?,
	-- menu click sound (S_LocalSound misc/menu2.wav, wired by the boot)
	playSound: (() -> ())?,
	-- same hook as tweaksui: nil spec restores the authentic skin; APPLY
	-- pushes the picked skin onto every viewmodel at once
	setWeaponSkin: ((mdlName: string, spec: string?) -> ())?,
	-- scoreboard override for the top-right SCORE plaque (hudlib.setShowScores)
	setShowScores: ((on: boolean) -> ())?,
	-- top-right MAP plaque / M: ask the director for a mid-game map vote
	-- (directorui.Handle.callVote); plaque omitted when nil
	callMapVote: (() -> ())?,
}

-- every viewmodel APPLY re-skins (matches tweaksui.WEAPONS)
local VIEWMODELS = {
	"progs/v_axe.mdl",
	"progs/v_shot.mdl",
	"progs/v_shot2.mdl",
	"progs/v_nail.mdl",
	"progs/v_nail2.mdl",
	"progs/v_rock.mdl",
	"progs/v_rock2.mdl",
	"progs/v_light.mdl",
}

-- Thousands separators, e.g. 4200 -> "4,200".
local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end
pausemenu._commas = commas

-- base64 -> buffer (menu icons are baked as base64 RGBA by build_menuicons.py)
local B64: { [number]: number } = {}
do
	local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, #A do
		B64[A:byte(i)] = i - 1
	end
end
local function b64decode(s: string): buffer
	local pad = 0
	if s:sub(-1) == "=" then
		pad += 1
	end
	if s:sub(-2, -2) == "=" then
		pad += 1
	end
	local outLen = (#s // 4) * 3 - pad
	local out = buffer.create(outLen)
	local oi = 0
	for i = 1, #s, 4 do
		local n = (B64[s:byte(i)] or 0) * 262144
			+ (B64[s:byte(i + 1)] or 0) * 4096
			+ (B64[s:byte(i + 2)] or 0) * 64
			+ (B64[s:byte(i + 3)] or 0)
		if oi < outLen then
			buffer.writeu8(out, oi, math.floor(n / 65536) % 256)
			oi += 1
		end
		if oi < outLen then
			buffer.writeu8(out, oi, math.floor(n / 256) % 256)
			oi += 1
		end
		if oi < outLen then
			buffer.writeu8(out, oi, n % 256)
			oi += 1
		end
	end
	return out
end

export type BoxImg = { img: EditableImage?, w: number, h: number }

local function loadPic(fs: vfslib.Vfs, pal: textures.Palette, name: string): BoxImg
	local buf = vfslib.loadFile(fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return { img = nil, w = 8, h = 8 }
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, pal, true)
	return { img = img, w = pic.width, h = pic.height }
end

-- one tiling/stretched slice of a nine-slice
local function slice(parent: Instance, box: BoxImg, tile: boolean, x: number, y: number, w: number, h: number)
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

type Pieces = { [string]: BoxImg }

-- box_*.lmp border ring into `parent` (which is `w`x`h`). `center` fills the
-- middle with box_mm; skip it to keep the parent's own background.
-- Edge strips STRETCH rather than tile: their bevel runs along the strip so
-- the two are visually identical, and Tile-mode EditableImages at fractional
-- UIScale paint a ghost duplicate outside their rect (renderer artifact).
local function nineSlice(parent: GuiObject, pieces: Pieces, w: number, h: number, center: boolean)
	local cw = pieces.box_tl.w * BOXSCALE
	local ch = pieces.box_tl.h * BOXSCALE
	if center then
		slice(parent, pieces.box_mm, true, cw, ch, w - 2 * cw, h - 2 * ch)
	end
	slice(parent, pieces.box_tm, false, cw, 0, w - 2 * cw, ch)
	slice(parent, pieces.box_bm, false, cw, h - ch, w - 2 * cw, ch)
	slice(parent, pieces.box_ml, false, 0, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_mr, false, w - cw, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_tl, false, 0, 0, cw, ch)
	slice(parent, pieces.box_tr, false, w - cw, 0, cw, ch)
	slice(parent, pieces.box_bl, false, 0, h - ch, cw, ch)
	slice(parent, pieces.box_br, false, w - cw, h - ch, cw, ch)
end

-- re-anchor a top-left-positioned element to its centre so a UIScale press
-- pulse shrinks it in place
local function centerAnchor(g: GuiObject)
	local p, s = g.Position, g.Size
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.fromOffset(p.X.Offset + s.X.Offset // 2, p.Y.Offset + s.Y.Offset // 2)
end

-- layout cells (box-local rects: x,y from the box's top-left) ---------------
type Rect = { x: number, y: number, w: number, h: number }

-- n equal columns with integer edges (the naive w=(GRID_W-gaps)/n leaves
-- fractional positions and the right edge drifts a pixel between pages)
local function cols(n: number, y: number, h: number): { Rect }
	local out = {}
	local span = GRID_W + GAP
	for i = 0, n - 1 do
		local x0 = math.round(i * span / n)
		local x1 = math.round((i + 1) * span / n) - GAP
		out[i + 1] = { x = GRID_X + x0, y = y, w = x1 - x0, h = h }
	end
	return out
end

local function layout1(): { Rect }
	return { { x = GRID_X, y = 0, w = GRID_W, h = GRID_H } }
end
local function layout2(): { Rect }
	return cols(2, 0, GRID_H)
end
local function layout3(): { Rect }
	return cols(3, 0, GRID_H)
end
-- hero (left) + 2x2 blocks (right). cells[1] = hero, [2..5] = blocks row-major
local function layoutHero4(): { Rect }
	local bh = (GRID_H - GAP) / 2
	local bw = bh -- square blocks
	local rightX = GRID_X + GRID_W - (2 * bw + GAP)
	local heroW = rightX - GAP - GRID_X
	return {
		{ x = GRID_X, y = 0, w = heroW, h = GRID_H },
		{ x = rightX, y = 0, w = bw, h = bh },
		{ x = rightX + bw + GAP, y = 0, w = bw, h = bh },
		{ x = rightX, y = bh + GAP, w = bw, h = bh },
		{ x = rightX + bw + GAP, y = bh + GAP, w = bw, h = bh },
	}
end
local function layout8(): { Rect }
	local ch = (GRID_H - GAP) / 2
	local top = cols(4, 0, ch)
	local bottom = cols(4, ch + GAP, ch)
	return { top[1], top[2], top[3], top[4], bottom[1], bottom[2], bottom[3], bottom[4] }
end

function pausemenu.attach(opts: Opts): Handle
	local fs, pal = opts.fs, opts.pal

	-- conchars font sheet (shared with the console / HUD)
	local font: confontlib.Font? = nil
	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	if wadbuf then
		local w = wadlib.load(wadbuf)
		local ok, conchars = pcall(wadlib.getRaw, w, "conchars")
		if ok then
			font = confontlib.new(conchars, pal)
		end
	end

	local pieces: Pieces = {}
	for _, name in BOX_PIECES do
		pieces[name] = loadPic(fs, pal, name)
	end

	-- menu icons -> EditableImages (RGBA baked in menuicons.luau)
	local iconImg: { [string]: EditableImage? } = {}
	for name, b64 in menuicons.data do
		iconImg[name] = textures.createRGBAImage(b64decode(b64), menuicons.size, menuicons.size)
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakePauseMenu"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 25
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = opts.playerGui

	-- hidden holder for the weapon template mesh (cloned into card viewports)
	local weaponHolder = Instance.new("Folder")
	weaponHolder.Name = "WeaponTemplates"
	weaponHolder.Parent = gui

	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.BorderSizePixel = 0
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.2
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = gui

	-- clicks that land on nothing interactive trigger the bottom action
	-- (RETURN TO GAME / BACK TO MENU); panels are Active so their bodies
	-- swallow clicks instead of falling through to this
	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 0
	catcher.Parent = gui

	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(CANVAS_W, CANVAS_H)
	canvas.ZIndex = 1
	canvas.Parent = gui
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = canvas
	local function fitCanvas()
		local sz = gui.AbsoluteSize
		if sz.X > 0 and sz.Y > 0 then
			uiScale.Scale = math.min(sz.X / (CANVAS_W + 48), sz.Y / (CANVAS_H + 48))
		end
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCanvas)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = canvas

	-- ---- press feedback --------------------------------------------------
	local function playClick()
		if opts.playSound then
			opts.playSound()
		end
	end
	-- shrink `visual` to 0.95 while the pointer is down on `btn`
	local function pressPulse(btn: GuiButton, visual: GuiObject)
		local sc = visual:FindFirstChildOfClass("UIScale")
		if not sc then
			local ns = Instance.new("UIScale")
			ns.Parent = visual
			sc = ns
		end
		local scale = sc :: UIScale
		btn.MouseButton1Down:Connect(function()
			scale.Scale = 0.95
		end)
		btn.MouseButton1Up:Connect(function()
			scale.Scale = 1
		end)
		btn.MouseLeave:Connect(function()
			scale.Scale = 1
		end)
	end

	-- ---- weapon template (lazy; entrender.create yields once) ----------
	local weaponDef: any = nil
	local weaponTemplate: BasePart? = nil
	local weaponTried = false
	local weaponBuilding = false
	local skinCache: { [string]: EditableImage? } = {}
	local function ensureWeapon(): BasePart?
		-- create() yields (CreateMeshPartAsync); a page built during that
		-- yield must wait for the template rather than render without guns
		while weaponBuilding do
			task.wait()
		end
		if weaponTried then
			return weaponTemplate
		end
		weaponTried = true
		weaponBuilding = true
		local ok, err = pcall(function()
			local buf = vfslib.loadFile(fs, "progs/v_rock2.mdl", true)
			if not buf then
				return
			end
			local am = mdllib.load("progs/v_rock2.mdl", buf)
			local def = { kind = "alias", alias = am, flags = am.flags }
			entrender.prepareImages(def :: any, pal)
			local re = entrender.create(def :: any, weaponHolder)
			if not re or not re.part then
				return
			end
			entrender.setLight(re, 300) -- bright bake; ViewportFrame is Ambient-only
			weaponDef = def
			weaponTemplate = re.part
		end)
		weaponBuilding = false
		if not ok then
			warn(`[robloquake] pause-menu weapon template failed: {err}`)
		end
		return weaponTemplate
	end
	local function skinImage(spec: string): EditableImage?
		if skinCache[spec] == nil and weaponDef then
			skinCache[spec] = skinforge.createImage(spec, weaponDef.skinPixels, weaponDef.skinW, weaponDef.skinH, pal)
		end
		return skinCache[spec]
	end

	-- a weapon render (rocket launcher w/ skin) in a ViewportFrame
	local function weaponView(parent: Instance, x: number, y: number, w: number, h: number, spec: string)
		local vf = Instance.new("ViewportFrame")
		vf.BackgroundTransparency = 1
		vf.BorderSizePixel = 0
		vf.Position = UDim2.fromOffset(x, y)
		vf.Size = UDim2.fromOffset(w, h)
		vf.Ambient = Color3.new(1, 1, 1)
		vf.LightColor = Color3.new(0, 0, 0)
		vf.ZIndex = 3
		vf.Parent = parent
		local template = ensureWeapon()
		if not template then
			return
		end
		local world = Instance.new("WorldModel")
		world.Parent = vf
		local cam = Instance.new("Camera")
		cam.Parent = vf
		vf.CurrentCamera = cam
		local p = template:Clone()
		local img = skinImage(spec)
		-- template may be the box-fallback Part when the Mesh API is off
		if img and p:IsA("MeshPart") then
			p.TextureContent = Content.fromObject(img)
		end
		local ext = p.Size
		local maxE = math.max(ext.X, ext.Y, ext.Z)
		-- near-profile pose (reference mockup): muzzle right, slightly
		-- toward camera and dipped; nudged left so the visual mass (the
		-- thick muzzle end sits right of the bbox centre) reads centred
		p.CFrame = CFrame.new(-maxE * 0.07, 0, 0) * CFrame.Angles(math.rad(4), math.rad(-30), math.rad(-6))
		p.Parent = world
		cam.FieldOfView = 40
		local dist = maxE * 1.3
		cam.CFrame = CFrame.lookAt(Vector3.new(0, maxE * 0.06, dist), Vector3.zero)
	end

	-- ---- text + widgets ------------------------------------------------
	local style: FontStyle = CLASSIC_FONT
	-- draw one line at (x,y); align 0 left / 0.5 centre within [x, x+wspan]
	local function text(parent: Instance, x: number, y: number, str: string, scale: number, color: Color3?, wspan: number?, align: number?): Frame
		local f = font
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
		local col = color or style.color
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

	-- fixed-capacity, updatable text line (the shop countdown); centred
	-- within wspan for its full capacity so updates never move it
	local function dynamicText(parent: Instance, x: number, y: number, capacity: number, scale: number, color: Color3, wspan: number): (string) -> ()
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(capacity * 8 * scale, 8 * scale)
		holder.Position = UDim2.fromOffset(math.floor(x + (wspan - capacity * 8 * scale) / 2), y)
		holder.ZIndex = 4
		holder.Parent = parent
		local f = font
		if f then
			local row = confontlib.newRow(holder, capacity, scale)
			for _, lbl in row.labels do
				lbl.ImageColor3 = color
				lbl.ZIndex = 4
			end
			return function(s: string)
				confontlib.setRow(f, row, s)
			end
		end
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.Code
		lbl.TextScaled = true
		lbl.TextColor3 = color
		lbl.Parent = holder
		return function(s: string)
			lbl.Text = s
		end
	end

	-- lift a widget's glyphs above the button border (Sibling ZIndex)
	local function raiseZ(inst: Instance)
		for _, d in inst:GetDescendants() do
			if d:IsA("ImageLabel") or d:IsA("TextLabel") then
				(d :: any).ZIndex = 6
			end
		end
	end

	-- Bottom button strip of a card, FULL-BLEED (mockup): the card's own
	-- side/bottom borders frame the buttons; the only added chrome is a
	-- full-width divider line at each row's top. The wash fills the whole
	-- bounded region without covering any border.
	type StripRow = { label: string?, robux: number?, onClick: (() -> ())? }
	local DIVIDER = 8 -- squashed-bevel divider line height
	local function cardButtons(p: Frame, cellW: number, cellH: number, rows: { StripRow })
		local sideW = pieces.box_ml.w * BOXSCALE
		local botH = pieces.box_bl.h * BOXSCALE
		local innerX, innerW = sideW, cellW - 2 * sideW
		local top = cellH - botH - #rows * CARD_BTN_H
		for i, row in rows do
			local rowY = top + (i - 1) * CARD_BTN_H
			local b = Instance.new("TextButton")
			b.AutoButtonColor = false
			b.Text = ""
			b.BorderSizePixel = 0
			b.BackgroundTransparency = 1
			b.ClipsDescendants = true
			b.Position = UDim2.fromOffset(innerX, rowY)
			b.Size = UDim2.fromOffset(innerW, CARD_BTN_H)
			b.ZIndex = 5
			b.Parent = p
			centerAnchor(b)
			-- wash spans border-to-border below the divider
			local wash = Instance.new("Frame")
			wash.Name = "Wash"
			wash.BorderSizePixel = 0
			wash.BackgroundColor3 = Color3.new(1, 1, 1)
			wash.BackgroundTransparency = 0.82
			wash.Position = UDim2.fromOffset(0, DIVIDER)
			wash.Size = UDim2.fromOffset(innerW, CARD_BTN_H - DIVIDER)
			wash.ZIndex = 2
			wash.Parent = b
			-- full-width divider at the row top (fill/row and row/row lines)
			local div = slice(b, pieces.box_tm, false, 0, 0, innerW, DIVIDER)
			div.ZIndex = 3
			b.MouseEnter:Connect(function()
				wash.BackgroundTransparency = 0.72
			end)
			b.MouseLeave:Connect(function()
				wash.BackgroundTransparency = 0.82
			end)
			pressPulse(b, b)
			local cb = row.onClick
			b.Activated:Connect(function()
				playClick()
				if cb then
					cb()
				end
			end)
			-- content centres in the region below the divider
			local cy = DIVIDER + math.floor((CARD_BTN_H - DIVIDER - 8 * style.body) / 2)
			if row.robux then
				local numStr = commas(row.robux :: number)
				local gs = 8 * style.body
				local total = gs + 6 + #numStr * 8 * style.body
				local sx = math.floor((innerW - total) / 2)
				local g = Instance.new("ImageLabel")
				g.BackgroundTransparency = 1
				g.Image = ROBUX_GLYPH
				g.Size = UDim2.fromOffset(gs, gs)
				g.Position = UDim2.fromOffset(sx, cy)
				g.ZIndex = 6
				g.Parent = b
				raiseZ(text(b, sx + gs + 6, cy, numStr, style.body, Color3.new(1, 1, 1)))
			else
				raiseZ(text(b, 0, cy, row.label :: string, style.body, Color3.new(1, 1, 1), innerW, 0.5))
			end
		end
	end

	-- transparent click target over a rect; `visual` gets the press pulse
	local function clickable(parent: Instance, x: number, y: number, w: number, h: number, visual: GuiObject?, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.BackgroundTransparency = 1
		b.Text = ""
		b.AutoButtonColor = false
		b.Position = UDim2.fromOffset(x, y)
		b.Size = UDim2.fromOffset(w, h)
		b.ZIndex = 7
		b.Parent = parent
		if visual then
			pressPulse(b, visual)
		end
		b.Activated:Connect(function()
			playClick()
			onClick()
		end)
	end

	-- centre an icon EditableImage inside a panel (panel-local coords)
	local function iconInPanel(p: Frame, w: number, h: number, name: string)
		local img = iconImg[name]
		if not img then
			return
		end
		local side = math.min(w, h) * 0.52
		local l = Instance.new("ImageLabel")
		l.BackgroundTransparency = 1
		l.ImageContent = Content.fromObject(img)
		l.ResampleMode = Enum.ResamplerMode.Pixelated
		l.Size = UDim2.fromOffset(side, side)
		l.Position = UDim2.fromOffset((w - side) / 2, (h - side) / 2 + 12)
		l.ZIndex = 3
		l.Parent = p
	end

	-- ---- daily shop rotation --------------------------------------------
	-- fixed rarity split over the sorted kinds (deterministic shuffle so
	-- every client agrees); TODO: hand-curate the groups later
	local rarityGroups: { { string } }? = nil
	local function getRarityGroups(): { { string } }
		if rarityGroups then
			return rarityGroups :: { { string } }
		end
		local kinds = skinforge.kinds()
		local rng = Random.new(1337)
		for i = #kinds, 2, -1 do
			local j = rng:NextInteger(1, i)
			kinds[i], kinds[j] = kinds[j], kinds[i]
		end
		local split = { {}, {}, {} } -- common | rare | legendary
		for i, k in kinds do
			if i <= math.ceil(#kinds * 0.5) then
				table.insert(split[1], k)
			elseif i <= math.ceil(#kinds * 0.8) then
				table.insert(split[2], k)
			else
				table.insert(split[3], k)
			end
		end
		rarityGroups = split
		return split
	end
	-- the three skins on sale for a given UTC day (one per rarity)
	local function shopPicks(day: number): { { kind: string, spec: string } }
		local groups = getRarityGroups()
		local rng = Random.new(day)
		local picks = {}
		for i = 1, 3 do
			local list = groups[i]
			local kind = list[rng:NextInteger(1, #list)]
			picks[i] = { kind = kind, spec = `{kind}:{rng:NextInteger(0, 999999)}` }
		end
		return picks
	end
	local function utcDay(): number
		return os.time() // 86400
	end

	-- ---- pages ---------------------------------------------------------
	local state = "main"
	local skinPage = 0
	local showPage: () -> ()
	local close: () -> ()

	-- a cell's box panel; Active so its body swallows clicks (instead of
	-- falling through to the outside-click catcher)
	local function cellPanel(cell: Rect): Frame
		local f = Instance.new("Frame")
		f.BackgroundTransparency = 1
		f.Active = true
		-- tiled slices at fractional UIScale can paint a partial extra tile
		-- beyond the frame (ghost lines in the gaps); clip them
		f.ClipsDescendants = true
		f.Position = UDim2.fromOffset(cell.x, BOX_Y + cell.y)
		f.Size = UDim2.fromOffset(cell.w, cell.h)
		f.Parent = content
		centerAnchor(f)
		nineSlice(f, pieces, cell.w, cell.h, true)
		return f
	end

	local function buildMain()
		local cells = layoutHero4()
		local hero = cells[1]
		local blocks = { cells[2], cells[3], cells[4], cells[5] }

		-- hero: profile card, click -> skins
		local hp = cellPanel(hero)
		text(hp, 20, 16, "SKELETANK420", style.head)
		local stats = {
			{ commas(480), "FRAGS" },
			{ commas(2490), "DEATHS" },
			{ commas(900), "WINS" },
			{ commas(4200), "LOSSES" },
			{ "#428", "GLOBALLY" },
		}
		local sy = hero.h - (#stats * (8 * style.body + 6)) - 20
		for _, row in stats do
			text(hp, 22, sy, `{row[1]} {row[2]}`, style.body)
			sy += 8 * style.body + 6
		end
		clickable(content, hero.x, BOX_Y + hero.y, hero.w, hero.h, hp, function()
			state, skinPage = "skins", 0
			showPage()
		end)

		local legendary = shopPicks(utcDay())[3]
		local defs = {
			{ label = "GAMEMODES", icon = "gamemodes", go = "gamemodes" },
			{ label = "SHOP", weapon = legendary.spec, go = "shop" },
			{ label = "FRIENDS", icon = "friends", go = "friends" },
			{ label = "SETTINGS", icon = "settings", go = "settings" },
		}
		for i, d in defs do
			local cell = blocks[i]
			local p = cellPanel(cell)
			-- block labels are centred (mockup), unlike the hero's header
			text(p, 0, 16, d.label, style.head, nil, cell.w, 0.5)
			if d.icon then
				iconInPanel(p, cell.w, cell.h, d.icon)
			elseif d.weapon then
				weaponView(p, 10, 30, cell.w - 20, cell.h - 40, d.weapon)
			end
			clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, function()
				state = d.go
				showPage()
			end)
		end
	end

	local function buildSettings()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		text(p, 0, cell.h / 2 - 8 * style.body, "SETTINGS COMING SOON", style.body, RARITY_GREY, cell.w, 0.5)
	end

	local function buildGamemodes()
		for i, cell in layout2() do
			local p = cellPanel(cell)
			text(p, 0, 20, `MODE {i}`, style.head, nil, cell.w, 0.5)
		end
	end

	local function buildShop()
		local day = utcDay()
		local picks = shopPicks(day)
		for i, cell in layout3() do
			local r = RARITIES[i]
			local pick = picks[i]
			local p = cellPanel(cell)
			text(p, 0, 14, pick.kind:upper(), style.head, nil, cell.w, 0.5)
			text(p, 0, 14 + 8 * style.head + 6, r.name, style.body, RARITY_GREY, cell.w, 0.5)
			-- weapon render fills the middle, above the two cost rows
			weaponView(p, 12, 64, cell.w - 24, cell.h - 64 - (2 * CARD_BTN_H + 22), pick.spec)
			-- shared-divider button strip at the bottom: FRAGS then ROBUX
			cardButtons(p, cell.w, cell.h, {
				{ label = `FRAGS {commas(r.frags)}` },
				{ robux = r.robux },
			})
		end
		-- countdown under the title; rebuilds the page when the day rolls
		-- over (swapping in the next three picks)
		local setTimer = dynamicText(content, 0, TITLE_H - 8, 15, style.body, RARITY_GREY, CANVAS_W)
		local alive = content:FindFirstChildOfClass("Frame") -- any page child: dies on rebuild
		task.spawn(function()
			while alive and alive.Parent do
				local now = os.time()
				if now // 86400 ~= day then
					if state == "shop" and gui.Enabled then
						task.defer(showPage)
					end
					break
				end
				local rem = 86400 - now % 86400
				setTimer(string.format("RESETS IN %02d:%02d", rem // 3600, (rem % 3600) // 60))
				task.wait(1)
			end
		end)
	end

	local function buildSkins()
		local cells = layout8()
		local kinds = skinforge.kinds() -- sorted, stable order
		local n = #kinds
		-- in-grid pager (mockup): past page 0 the first cell is a back
		-- arrow, and while skins remain the cell after the last skin is a
		-- forward arrow; unused cells sit as dark empty slots
		local starts, counts = { 1 }, {}
		if n <= #cells then
			counts[1] = n
		else
			counts[1] = #cells - 1 -- page 0: skins + forward arrow
			local start = #cells
			while true do
				table.insert(starts, start)
				local rem = n - start + 1
				if rem <= #cells - 1 then
					table.insert(counts, rem) -- last page: back arrow + rest
					break
				end
				table.insert(counts, #cells - 2) -- middle: back + skins + fwd
				start += #cells - 2
			end
		end
		local pageCount = #starts
		skinPage = math.clamp(skinPage, 0, pageCount - 1)
		local first = starts[skinPage + 1]
		local count = counts[skinPage + 1]

		local function arrowCell(cell: Rect, glyph: string, dir: number)
			local p = cellPanel(cell)
			text(p, 0, math.floor((cell.h - 8 * 5) / 2), glyph, 5, Color3.new(1, 1, 1), cell.w, 0.5)
			clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, function()
				skinPage += dir
				showPage()
			end)
		end
		local function skinCell(cell: Rect, kind: string)
			local p = cellPanel(cell)
			local name = kind:upper()
			local sc = if #name * 8 * style.head <= cell.w - 12 then style.head else 1
			text(p, 0, 16, name, sc, nil, cell.w, 0.5)
			weaponView(p, 8, 34, cell.w - 16, cell.h - 34 - (CARD_BTN_H + 14), `{kind}:7`)
			cardButtons(p, cell.w, cell.h, {
				{
					label = "APPLY",
					onClick = function()
						if opts.setWeaponSkin then
							for _, mdl in VIEWMODELS do
								opts.setWeaponSkin(mdl, `{kind}:7`)
							end
						end
					end,
				},
			})
		end
		local function emptyCell(cell: Rect)
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.Active = true
			f.BackgroundColor3 = Color3.fromRGB(16, 10, 8)
			f.BackgroundTransparency = 0.45
			f.Position = UDim2.fromOffset(cell.x, BOX_Y + cell.y)
			f.Size = UDim2.fromOffset(cell.w, cell.h)
			f.ZIndex = 2
			f.Parent = content
		end

		local ci = 1
		if skinPage > 0 then
			arrowCell(cells[ci], "<", -1)
			ci += 1
		end
		for k = 0, count - 1 do
			skinCell(cells[ci], kinds[first + k])
			ci += 1
		end
		if first + count - 1 < n then
			arrowCell(cells[ci], ">", 1)
			ci += 1
		end
		while ci <= #cells do
			emptyCell(cells[ci])
			ci += 1
		end
	end

	local function buildFriends()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		text(p, 0, cell.h / 2 - 8 * style.body, "FRIENDS COMING SOON", style.body, RARITY_GREY, cell.w, 0.5)
	end

	local PAGES: { [string]: { title: string, build: () -> () } } = {
		main = { title = "FRAG", build = buildMain },
		settings = { title = "SETTINGS", build = buildSettings },
		gamemodes = { title = "GAMEMODES", build = buildGamemodes },
		shop = { title = "SHOP", build = buildShop },
		skins = { title = "SKINS", build = buildSkins },
		friends = { title = "FRIENDS", build = buildFriends },
	}

	-- the bottom action: leave (main) or back out to the main page
	local function navAction()
		if state == "main" then
			close()
		else
			state = "main"
			showPage()
		end
	end

	showPage = function()
		content:ClearAllChildren()
		local page = PAGES[state] or PAGES.main
		-- shared title (same position every page)
		text(content, 0, math.floor((TITLE_H - 8 * style.title) / 2), page.title, style.title, nil, CANVAS_W, 0.5)
		page.build()
		-- shared bottom nav
		local navLabel = if state == "main" then "RETURN TO GAME" else "BACK TO MENU"
		local ty = BOTTOM_Y + math.floor((BTN_H - 8 * style.title) / 2)
		local navText = text(content, 0, ty, navLabel, style.title, nil, CANVAS_W, 0.5)
		centerAnchor(navText)
		clickable(
			content,
			math.floor((CANVAS_W - #navLabel * 8 * style.title) / 2),
			BOTTOM_Y,
			#navLabel * 8 * style.title,
			BTN_H,
			navText,
			navAction
		)
	end

	catcher.Activated:Connect(function()
		playClick()
		navAction()
	end)

	-- ---- open/close ----------------------------------------------------
	local open = false
	local function setOpen(on: boolean)
		if open == on then
			return
		end
		open = on
		gui.Enabled = on
		if on then
			state, skinPage = "main", 0
			showPage()
			fitCanvas()
		end
		if opts.onUiToggle then
			opts.onUiToggle(on)
		end
	end
	close = function()
		setOpen(false)
		if opts.onReturnToGame then
			opts.onReturnToGame()
		end
	end

	-- E toggles the menu, M calls a map vote (the engine's own Quake menu
	-- moved to backslash). Like the engine's hotkeys (init.client.luau's
	-- InputBegan ignores gameProcessed), raw keys drive these; suppressed
	-- only while a text field owns the keyboard.
	UserInputService.InputBegan:Connect(function(input)
		if opts.isTyping() or UserInputService:GetFocusedTextBox() then
			return
		end
		local callMapVote = opts.callMapVote
		if input.KeyCode == Enum.KeyCode.E then
			setOpen(not open)
		elseif input.KeyCode == Enum.KeyCode.M and callMapVote then
			callMapVote()
		end
	end)

	-- ---- top-right MENU/SCORE plaques ------------------------------------
	-- Always visible during play, sitting left of the director gear (which
	-- is 44px at (1,-12),(0,12) in its own inset-ignoring gui). Touch-only
	-- devices get bare labels: there is no key to hint at.
	local topGui = Instance.new("ScreenGui")
	topGui.Name = "QuakeTopButtons"
	topGui.ResetOnSpawn = false
	topGui.DisplayOrder = 24 -- under the menu's 25: its scrim + catcher swallow these while open
	topGui.IgnoreGuiInset = true
	topGui.Parent = opts.playerGui

	-- conchars scale only, so the pixel font stays crisp (integer upscales)
	local TOP_H, TOP_SCALE = 52, 2
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- one plaque, right edge at `rightEdge` (offset from the screen's right);
	-- returns the right edge for the next plaque to its left
	local function topButton(label: string, rightEdge: number, onClick: () -> ()): number
		local w = #label * 8 * TOP_SCALE + 24
		local btn = Instance.new("TextButton")
		btn.Name = label
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.BackgroundTransparency = 1
		btn.AnchorPoint = Vector2.new(1, 0)
		btn.Position = UDim2.new(1, rightEdge, 0, 10)
		btn.Size = UDim2.fromOffset(w, TOP_H)
		btn.Parent = topGui
		nineSlice(btn, pieces, w, TOP_H, true)
		text(btn, 0, (TOP_H - 8 * TOP_SCALE) / 2, label, TOP_SCALE, ORANGE, w, 0.5)
		pressPulse(btn, btn)
		btn.Activated:Connect(function()
			playClick()
			onClick()
		end)
		return rightEdge - w - 10
	end

	-- the plaque is a toggle where the key is hold-to-show (+showscores);
	-- last writer wins on the shared hud flag, which is fine
	local scoresOn = false
	local nextEdge = topButton(if touchOnly then "SCORE" else "SCORE [R]", -68, function()
		scoresOn = not scoresOn
		if opts.setShowScores then
			opts.setShowScores(scoresOn)
		end
	end)
	nextEdge = topButton(if touchOnly then "MENU" else "MENU [E]", nextEdge, function()
		setOpen(not open)
	end)
	local callMapVote = opts.callMapVote
	if callMapVote then
		topButton(if touchOnly then "MAP" else "MAP [M]", nextEdge, function()
			callMapVote()
		end)
	end

	return {
		toggle = function()
			setOpen(not open)
		end,
		isOpen = function()
			return open
		end,
		setBigFont = function(on: boolean)
			style = if on then BIG_FONT else CLASSIC_FONT
			if open then
				showPage()
			end
		end,
		isBigFont = function()
			return style == BIG_FONT
		end,
	}
end

return pausemenu
