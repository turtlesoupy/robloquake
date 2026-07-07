--!strict
-- Pause menu (PRODUCT layer, NOT engine): the game's "menu" overlay opened
-- with backslash (\). Unlike the Quake M-menu (src/client/menu.luau) this is
-- a modern shop/stats front-end, so it lives outside the engine and can be
-- deleted at any time. The world keeps simulating while it is up (Roblox
-- multiplayer never pauses); we only drop an 80% black scrim over it.
--
-- REMOVAL: delete this file plus the two attach blocks (search "pause menu"
-- in src/client/init.client.luau and src/client/qwclient.luau) and the
-- MENU FONT toggle in src/client/tweaksui.luau.
--
-- Textures: panels are the Quake gfx/box_*.lmp nine-slice (border AND tiled
-- fill), so no new art ships. Text is the conchars bitmap font (bronze
-- high-bit glyphs = the orange in the mockups). NOTE: LibreQuake has no
-- separate scalable "plaque" font — its big menu words are baked per-label
-- images, unusable for dynamic strings — so the font toggle swaps conchars
-- between a large bronze "big" style and a smaller white "classic" style.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)

local textures = require(script.Parent.render.textures)
local confontlib = require(script.Parent.render.confont)

local pausemenu = {}

-- design canvas (menu pixels); a UIScale fits it to the viewport
local CANVAS_W = 1240
local CANVAS_H = 600
local BOXSCALE = 2 -- each box_*.lmp pixel blown up this much

-- The nine box pieces, keyed the way M_DrawTextBox names them.
local BOX_PIECES = { "box_tl", "box_tr", "box_bl", "box_br", "box_tm", "box_bm", "box_ml", "box_mr", "box_mm" }

-- The conchars glyphs are white on transparent, so ImageColor3 tints them to
-- any colour. "big" = the large orange plaque look of the mockups; "classic"
-- = smaller cool-white. (LibreQuake has no separate scalable plaque font; its
-- big menu words are baked per-label images, unusable for dynamic strings.)
export type FontStyle = {
	color: Color3,
	body: number, -- conchars scale for body text
	title: number, -- conchars scale for page titles
	head: number, -- conchars scale for panel headers
}

local ORANGE = Color3.fromRGB(255, 150, 60)
local COOL = Color3.fromRGB(210, 222, 235)
local BIG_FONT: FontStyle = { color = ORANGE, body = 3, title = 5, head = 3 }
local CLASSIC_FONT: FontStyle = { color = COOL, body = 2, title = 3, head = 2 }

export type BoxImg = { img: EditableImage?, w: number, h: number }

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
	-- fired on open/close so the boot can free the cursor / drop mouselook
	onUiToggle: ((open: boolean) -> ())?,
	-- optional hook when RETURN TO GAME is chosen (defaults to just closing)
	onReturnToGame: (() -> ())?,
}

-- Thousands separators, e.g. 4200 -> "4,200" (stats formatting).
local function commas(n: number): string
	local s = tostring(math.floor(n))
	local sign = ""
	if s:sub(1, 1) == "-" then
		sign, s = "-", s:sub(2)
	end
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return sign .. out
end

pausemenu._commas = commas

-- Load a gfx/*.lmp pic as an EditableImage (index 255 transparent).
local function loadPic(fs: vfslib.Vfs, pal: textures.Palette, name: string): BoxImg
	local buf = vfslib.loadFile(fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return { img = nil, w = 8, h = 8 }
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, pal, true)
	return { img = img, w = pic.width, h = pic.height }
end

-- One tiling/stretched slice of the nine-slice.
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

-- Build a box_*.lmp panel Frame of the given pixel size. Returns the frame
-- (children are added by the caller at panel-local offsets).
local function panel(parent: Instance, pieces: { [string]: BoxImg }, x: number, y: number, w: number, h: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Position = UDim2.fromOffset(x, y)
	f.Size = UDim2.fromOffset(w, h)
	f.Parent = parent

	local cw = pieces.box_tl.w * BOXSCALE
	local ch = pieces.box_tl.h * BOXSCALE
	-- center + edges first, corners on top so the bevel wins
	slice(f, pieces.box_mm, true, cw, ch, w - 2 * cw, h - 2 * ch)
	slice(f, pieces.box_tm, true, cw, 0, w - 2 * cw, ch)
	slice(f, pieces.box_bm, true, cw, h - ch, w - 2 * cw, ch)
	slice(f, pieces.box_ml, true, 0, ch, cw, h - 2 * ch)
	slice(f, pieces.box_mr, true, w - cw, ch, cw, h - 2 * ch)
	slice(f, pieces.box_tl, false, 0, 0, cw, ch)
	slice(f, pieces.box_tr, false, w - cw, 0, cw, ch)
	slice(f, pieces.box_bl, false, 0, h - ch, cw, ch)
	slice(f, pieces.box_br, false, w - cw, h - ch, cw, ch)
	return f
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

	local pieces: { [string]: BoxImg } = {}
	for _, name in BOX_PIECES do
		pieces[name] = loadPic(fs, pal, name)
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakePauseMenu"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 25 -- above HUD/overlay (20); tweaks (30) can layer on top
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = opts.playerGui

	-- 80% black scrim over the (still-running) world
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.BorderSizePixel = 0
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.2
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = gui

	-- fixed-proportion canvas, scaled to fit the viewport
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
		-- gui.AbsoluteSize is the viewport in pixels; scale the canvas down to
		-- fit it (with a little margin), never up past 1:1
		local sz = gui.AbsoluteSize
		if sz.X > 0 and sz.Y > 0 then
			uiScale.Scale = math.min(sz.X / (CANVAS_W + 40), sz.Y / (CANVAS_H + 40), 1)
		end
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCanvas)

	-- ---- text rendering ------------------------------------------------
	local style: FontStyle = BIG_FONT
	-- everything rebuilt on page/font change lives under `content`
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = canvas

	-- Draw one line of text at panel-local (x, y). align: 0 left, 0.5 center
	-- within [x, x+wspan]. Returns the holder frame.
	local function text(parent: Instance, x: number, y: number, str: string, scale: number, wspan: number?, align: number?)
		local f = font
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(math.max(#str, 1) * 8 * scale, 8 * scale)
		local px = x
		if wspan and align then
			px = x + (wspan - #str * 8 * scale) * align
		end
		holder.Position = UDim2.fromOffset(math.floor(px), y)
		holder.ZIndex = 2
		holder.Parent = parent
		if f then
			-- white conchars glyphs tinted to the style colour
			local row = confontlib.newRow(holder, math.max(#str, 1), scale)
			confontlib.setRow(f, row, str)
			for _, lbl in row.labels do
				lbl.ImageColor3 = style.color
			end
		else
			-- fallback when the Image API is disabled: plain Roblox text
			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = Enum.Font.Code
			lbl.TextScaled = true
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextColor3 = style.color
			lbl.Text = str
			lbl.Parent = holder
		end
		return holder
	end

	-- ---- pages ---------------------------------------------------------
	local state = "main" -- main | shop
	local showPage: () -> ()

	-- a header panel with a big label in its top-left; returns the frame so
	-- a click target can be layered over it
	local function headerPanel(x: number, y: number, w: number, h: number, label: string): Frame
		local p = panel(content, pieces, x, y, w, h)
		text(p, 22, 18, label, style.head)
		return p
	end

	-- transparent click target over a region
	local function clickable(x: number, y: number, w: number, h: number, onClick: () -> ()): TextButton
		local b = Instance.new("TextButton")
		b.BackgroundTransparency = 1
		b.Text = ""
		b.AutoButtonColor = false
		b.Position = UDim2.fromOffset(x, y)
		b.Size = UDim2.fromOffset(w, h)
		b.ZIndex = 5
		b.Parent = content
		b.Activated:Connect(onClick)
		return b
	end

	local close: () -> ()

	local function buildMain()
		text(content, 0, 24, "FRAG", style.title, CANVAS_W, 0.5)

		-- left: player card + stats
		headerPanel(40, 96, 560, 430, "SKELETANK420")
		local stats = {
			{ commas(480), "FRAGS" },
			{ commas(2490), "DEATHS" },
			{ commas(900), "WINS" },
			{ commas(4200), "LOSSES" },
			{ "#428", "GLOBALLY" },
		}
		local sy = 360
		for _, row in stats do
			text(content, 78, sy, `{row[1]} {row[2]}`, style.body)
			sy += 8 * style.body + 6
		end

		-- right column: three nav panels
		local rx, rw = 640, 560
		headerPanel(rx, 96, rw, 130, "GAMEMODES")
		headerPanel(rx, 246, rw, 130, "SHOP")
		headerPanel(rx, 396, rw, 130, "FRIENDS")
		clickable(rx, 96, rw, 130, function()
			-- gamemodes: stub
		end)
		clickable(rx, 246, rw, 130, function()
			state = "shop"
			showPage()
		end)
		clickable(rx, 396, rw, 130, function()
			-- friends: stub
		end)

		-- bottom: return to game (14 = #"RETURN TO GAME")
		text(content, 0, 548, "RETURN TO GAME", style.title, CANVAS_W, 0.5)
		clickable(math.floor((CANVAS_W - 14 * 8 * style.title) / 2), 548, 14 * 8 * style.title, 8 * style.title, function()
			close()
		end)
	end

	local function buildShop()
		text(content, 0, 20, "SHOP", style.title, CANVAS_W, 0.5)
		text(content, 0, 20 + 8 * style.title + 8, "RESETS IN 02:21", style.body, CANVAS_W, 0.5)

		-- left: featured legendary, with a buy slot along the bottom
		local lp = headerPanel(40, 120, 560, 406, "LEGENDARY")
		panel(lp, pieces, 24, 340, 512, 48) -- inner buy slot

		-- right column: three offer panels, each with an inner price slot
		local rx, rw = 640, 560
		local rows = { { 120, "MIDNIGHT LIGHTNING" }, { 270, "SHOP" }, { 420, "FRIENDS" } }
		for _, r in rows do
			local yy = r[1] :: number
			local hp = headerPanel(rx, yy, rw, 130, r[2] :: string)
			panel(hp, pieces, rw - 220, 78, 200, 40) -- inner price slot
		end

		-- bottom: back to menu
		text(content, 0, 548, "BACK TO MENU", style.title, CANVAS_W, 0.5)
		clickable(math.floor((CANVAS_W - 12 * 8 * style.title) / 2), 548, 12 * 8 * style.title, 8 * style.title, function()
			state = "main"
			showPage()
		end)
	end

	showPage = function()
		content:ClearAllChildren()
		if state == "shop" then
			buildShop()
		else
			buildMain()
		end
	end

	-- ---- open/close ----------------------------------------------------
	local open = false
	local function setOpen(on: boolean)
		if open == on then
			return
		end
		open = on
		gui.Enabled = on
		if on then
			state = "main"
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

	-- Backslash toggles. Like the engine's own hotkeys (see init.client.luau's
	-- InputBegan, which ignores gameProcessed), a raw key drives this; we only
	-- suppress it while a text field owns the keyboard (Quake console or Roblox
	-- chat), never on the gameProcessed flag.
	UserInputService.InputBegan:Connect(function(input)
		if opts.isTyping() or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.BackSlash then
			setOpen(not open)
		end
	end)

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
