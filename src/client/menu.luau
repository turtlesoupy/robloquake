--!strict
-- The Quake menu — port of menu.c's M_Main / M_Help visuals: qplaque,
-- ttl_main, mainmenu.lmp with the animated menudot cursor, and the
-- gfx/help0-5.lmp pages, drawn on a 320x200 canvas.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)

local textures = require(script.Parent.render.textures)
local confontlib = require(script.Parent.render.confont)

local menu = {}

local SCALE = 2
local MAIN_ITEMS = 5
local NUM_HELP_PAGES = 6

export type Menu = {
	gui: Frame,
	fs: vfslib.Vfs,
	pal: textures.Palette,
	pics: { [string]: ImageLabel },
	dots: { ImageLabel },
	helpPage: ImageLabel,
	state: string, -- none | main | help | singleplayer | load | save | setup
	cursor: number,
	helpIndex: number,
	subFrame: Frame,
	fade: Frame,
	font: confontlib.Font?,
	saves: { { name: string, comment: string } },
	setupTop: number,
	setupBottom: number,
	-- item actions wired by the client
	onNewGame: () -> (),
	onQuit: () -> (),
	-- S_LocalSound hook (menu1/menu2 beeps); the boot wires soundlib
	onBeep: (name: string) -> (),
	print: (s: string) -> (),
	-- save/load menu hooks (M_ScanSaves reads the platform save store)
	getSaves: () -> { { name: string, comment: string } },
	onLoad: (name: string) -> (),
	onSave: (name: string) -> (),
	-- setup menu (color command)
	onColor: (top: number, bottom: number) -> (),
	-- QW: single/multiplayer are "use the console" stubs like C's QW menu
	qwMode: boolean,
}

local function addPic(m: Menu, name: string, x: number, y: number, centered: boolean?): ImageLabel?
	local buf = vfslib.loadFile(m.fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return nil
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, m.pal, true)
	if not img then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(img)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	local px = if centered then math.floor((320 - pic.width) / 2) else x
	label.Position = UDim2.fromOffset(px * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
	label.Parent = m.gui
	m.pics[name] = label
	return label
end

function menu.create(fs: vfslib.Vfs, pal: textures.Palette, parent: Instance): Menu
	local gui = Instance.new("Frame")
	gui.Name = "QuakeMenu"
	gui.BackgroundTransparency = 1
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.new(0.5, 0, 0.5, 0)
	gui.Size = UDim2.fromOffset(320 * SCALE, 200 * SCALE)
	gui.Visible = false
	gui.ZIndex = 30

	local m = {} :: Menu
	m.gui = gui
	m.fs = fs
	m.pal = pal
	m.pics = {}
	m.dots = {}
	m.state = "none"
	m.cursor = 0
	m.helpIndex = 0
	m.onNewGame = function() end
	m.onQuit = function() end
	m.onBeep = function(_n: string) end
	m.print = print
	m.getSaves = function()
		return {}
	end
	m.onLoad = function(_n: string) end
	m.onSave = function(_n: string) end
	m.onColor = function(_t: number, _b: number) end
	m.saves = {}
	m.setupTop = 0
	m.setupBottom = 0
	m.qwMode = false

	-- Draw_FadeScreen: the dimmed world behind every menu page (C dithers
	-- 8x8 at half density; a half-transparent black frame is the GUI twin)
	local fade = Instance.new("Frame")
	fade.Name = "fade"
	fade.BorderSizePixel = 0
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 0.5
	fade.AnchorPoint = Vector2.new(0.5, 0.5)
	fade.Position = UDim2.new(0.5, 0, 0.5, 0)
	fade.Size = UDim2.fromScale(4, 4) -- covers any window from the canvas centre
	fade.ZIndex = -1
	fade.Parent = gui
	m.fade = fade

	-- submenus (single player / load / save / setup) rebuild into this
	local subFrame = Instance.new("Frame")
	subFrame.Name = "submenu"
	subFrame.BackgroundTransparency = 1
	subFrame.Size = UDim2.fromOffset(320 * SCALE, 200 * SCALE)
	subFrame.Visible = false
	subFrame.Parent = gui
	m.subFrame = subFrame

	-- conchars text for the load/save/setup pages
	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	if wadbuf then
		local w = wadlib.load(wadbuf)
		local ok, conchars = pcall(wadlib.getRaw, w, "conchars")
		if ok then
			m.font = confontlib.new(conchars, pal)
		end
	end

	-- M_Main_Draw: qplaque at (16,4), title centered at y=4, menu at (72,32)
	addPic(m, "qplaque", 16, 4)
	addPic(m, "ttl_main", 0, 4, true)
	addPic(m, "mainmenu", 72, 32)

	-- animated cursor frames (menudot1..6) at (54, 32 + cursor*20)
	for i = 1, 6 do
		local dot = addPic(m, "menudot" .. i, 54, 32)
		if dot then
			dot.Visible = false
			m.dots[i] = dot
		end
	end

	-- help pages are full 320x200 screens
	local help = Instance.new("ImageLabel")
	help.Name = "helpPage"
	help.BackgroundTransparency = 1
	help.ResampleMode = Enum.ResamplerMode.Pixelated
	help.Size = UDim2.fromOffset(320 * SCALE, 200 * SCALE)
	help.Visible = false
	help.Parent = gui
	m.helpPage = help

	gui.Parent = parent
	return m
end

local function setMainVisible(m: Menu, on: boolean)
	for name, pic in m.pics do
		if name:sub(1, 7) ~= "menudot" then
			pic.Visible = on
		end
	end
	if not on then
		for _, dot in m.dots do
			dot.Visible = false
		end
	end
end

local function showHelp(m: Menu)
	local buf = vfslib.loadFile(m.fs, ("gfx/help%d.lmp"):format(m.helpIndex))
	if not buf then
		return
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, m.pal, false)
	if img then
		m.helpPage.ImageContent = Content.fromObject(img)
		m.helpPage.Visible = true
	end
end

-- helpers targeting the submenu frame -----------------------------------
local function subPic(m: Menu, name: string, x: number, y: number, centered: boolean?)
	local buf = vfslib.loadFile(m.fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, m.pal, true)
	if not img then
		return
	end
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(img)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	local px = if centered then math.floor((320 - pic.width) / 2) else x
	label.Position = UDim2.fromOffset(px * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
	label.Parent = m.subFrame
	return label
end

local function subText(m: Menu, x: number, y: number, text: string)
	local font = m.font
	if not font then
		return
	end
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	holder.Size = UDim2.fromOffset(#text * 8 * SCALE, 8 * SCALE)
	holder.Parent = m.subFrame
	local row = confontlib.newRow(holder, math.max(#text, 1), SCALE)
	confontlib.setRow(font, row, text)
end

-- M_DrawTextBox: bordered box tiled from the gfx/box_*.lmp pieces
-- (width in 8px columns, height in 8px lines, like C)
function menu.drawTextBox(m: Menu, x: number, y: number, cols: number, lines: number)
	subPic(m, "box_tl", x, y)
	subPic(m, "box_bl", x, y + 8 * (lines + 1))
	for i = 0, lines - 1 do
		subPic(m, "box_ml", x, y + 8 * (i + 1))
	end
	local cx = x + 8
	for cw = 0, cols - 1, 2 do
		subPic(m, "box_tm", cx, y)
		subPic(m, "box_bm", cx, y + 8 * (lines + 1))
		for i = 0, lines - 1 do
			subPic(m, "box_mm2", cx, y + 8 * (i + 1))
		end
		cx += 16
	end
	subPic(m, "box_tr", cx, y)
	subPic(m, "box_br", cx, y + 8 * (lines + 1))
	for i = 0, lines - 1 do
		subPic(m, "box_mr", cx, y + 8 * (i + 1))
	end
end

-- M_BuildTranslationTable / M_DrawTransPicTranslate: menuplyr.lmp with
-- the shirt/pants rows remapped through the shared translatePixels
local function drawTranslatedPlayer(m: Menu, x: number, y: number)
	local buf = vfslib.loadFile(m.fs, "gfx/menuplyr.lmp")
	if not buf then
		return
	end
	local pic = wadlib.parseQPic(buf)
	local translated = textures.translatePixels(pic.pixels, pic.width * pic.height, m.setupTop * 16 + m.setupBottom)
	local img = textures.createImage(translated, pic.width, pic.height, m.pal, true)
	if not img then
		return
	end
	local label = Instance.new("ImageLabel")
	label.Name = "menuplyr"
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(img)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
	label.Parent = m.subFrame
end

local SP_ITEMS = 3
local MAX_SAVEGAMES = 12 -- MAX_SAVEGAMES in C

-- rebuild whichever submenu the state names
local function rebuildSub(m: Menu)
	m.subFrame:ClearAllChildren()
	if m.state == "singleplayer" then
		-- M_SinglePlayer_Draw: ttl_sgl + sp_menu with the big cursor
		subPic(m, "qplaque", 16, 4)
		subPic(m, "ttl_sgl", 0, 4, true)
		subPic(m, "sp_menu", 72, 32)
	elseif m.state == "load" or m.state == "save" then
		-- M_Load_Draw / M_Save_Draw: title + the 12 slot lines
		subPic(m, if m.state == "load" then "p_load" else "p_save", 0, 4, true)
		m.saves = m.getSaves()
		for i = 0, MAX_SAVEGAMES - 1 do
			local sv = m.saves[i + 1]
			subText(m, 16, 32 + i * 8, if sv then sv.comment else "--- UNUSED SLOT ---")
		end
		if m.state == "load" and #m.saves == 0 then
			menu.drawTextBox(m, 60, 140, 24, 1)
			subText(m, 76, 152, "No saved games.")
		end
	elseif m.state == "setup" then
		-- M_Setup_Draw subset: shirt/pants colors + the translated player
		-- pic in a text box (name/hostname fields are platform-owned)
		subPic(m, "qplaque", 16, 4)
		subPic(m, "p_multi", 0, 4, true)
		subText(m, 64, 80, "Shirt color")
		subText(m, 200, 80, ("%2i"):format(m.setupTop))
		subText(m, 64, 104, "Pants color")
		subText(m, 200, 104, ("%2i"):format(m.setupBottom))
		subText(m, 72, 140, "Accept Changes")
		menu.drawTextBox(m, 160, 32, 8, 4)
		drawTranslatedPlayer(m, 172, 40)
	end
end

-- cursor rows per submenu (the update loop places the animated dot)
function menu.subCursorPos(m: Menu): (number?, number?)
	if m.state == "singleplayer" then
		return 54, 32 + m.cursor * 20
	end
	return nil
end

function menu.toggle(m: Menu)
	m.onBeep("misc/menu1.wav") -- M_ToggleMenu_f's S_LocalSound
	if m.state == "none" then
		m.state = "main"
		m.cursor = 0
		m.gui.Visible = true
		setMainVisible(m, true)
		m.helpPage.Visible = false
		m.subFrame.Visible = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		m.state = "none"
		m.gui.Visible = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

function menu.isOpen(m: Menu): boolean
	return m.state ~= "none"
end

-- returns true if the key was consumed
function menu.handleKey(m: Menu, input: InputObject): boolean
	if m.state == "none" then
		return false
	end
	local key = input.KeyCode

	if m.state == "help" then
		if key == Enum.KeyCode.Backspace or key == Enum.KeyCode.M then
			m.state = "main"
			m.helpPage.Visible = false
			setMainVisible(m, true)
		elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.Left then
			m.helpIndex = (m.helpIndex + NUM_HELP_PAGES - 1) % NUM_HELP_PAGES
			showHelp(m)
		else
			m.helpIndex = (m.helpIndex + 1) % NUM_HELP_PAGES
			showHelp(m)
		end
		return true
	end

	-- submenu states -----------------------------------------------------
	local function enterState(state: string, cursor: number)
		m.state = state
		m.cursor = cursor
		setMainVisible(m, false)
		rebuildSub(m)
		m.subFrame.Visible = true
	end

	local function backToMain()
		m.state = "main"
		m.cursor = 0
		m.subFrame.Visible = false
		setMainVisible(m, true)
	end

	if m.state == "singleplayer" then
		-- M_SinglePlayer_Key: New Game / Load / Save
		if key == Enum.KeyCode.M or key == Enum.KeyCode.Backspace then
			backToMain()
		elseif key == Enum.KeyCode.Up then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + SP_ITEMS - 1) % SP_ITEMS
		elseif key == Enum.KeyCode.Down then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + 1) % SP_ITEMS
		elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			m.onBeep("misc/menu2.wav")
			if m.cursor == 0 then
				menu.toggle(m)
				m.onNewGame()
			elseif m.cursor == 1 then
				enterState("load", 0)
			else
				enterState("save", 0)
			end
		end
		return true
	elseif m.state == "load" or m.state == "save" then
		-- M_Load_Key / M_Save_Key over the 12 slots
		if key == Enum.KeyCode.M or key == Enum.KeyCode.Backspace then
			enterState("singleplayer", if m.state == "load" then 1 else 2)
		elseif key == Enum.KeyCode.Up then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + MAX_SAVEGAMES - 1) % MAX_SAVEGAMES
		elseif key == Enum.KeyCode.Down then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + 1) % MAX_SAVEGAMES
		elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			m.onBeep("misc/menu2.wav")
			if m.state == "save" then
				-- slot name s0..s11 like C's s%i.sav
				menu.toggle(m)
				m.onSave(`s{m.cursor}`)
			else
				local sv = m.saves[m.cursor + 1]
				if sv then
					menu.toggle(m)
					m.onLoad(sv.name)
				end
			end
		end
		return true
	elseif m.state == "setup" then
		-- M_Setup_Key subset: shirt (0), pants (1), accept (2)
		local items = 3
		if key == Enum.KeyCode.M or key == Enum.KeyCode.Backspace then
			backToMain()
		elseif key == Enum.KeyCode.Up then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + items - 1) % items
		elseif key == Enum.KeyCode.Down then
			m.onBeep("misc/menu1.wav")
			m.cursor = (m.cursor + 1) % items
		elseif key == Enum.KeyCode.Left or key == Enum.KeyCode.Right then
			local d = if key == Enum.KeyCode.Left then -1 else 1
			m.onBeep("misc/menu3.wav")
			if m.cursor == 0 then
				m.setupTop = (m.setupTop + d) % 14
			elseif m.cursor == 1 then
				m.setupBottom = (m.setupBottom + d) % 14
			end
			rebuildSub(m)
		elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			if m.cursor == 2 then
				m.onBeep("misc/menu2.wav")
				m.onColor(m.setupTop, m.setupBottom)
				backToMain()
			end
		end
		return true
	end

	-- main menu (M toggles; Escape is reserved by Roblox)
	if key == Enum.KeyCode.M or key == Enum.KeyCode.Backspace then
		menu.toggle(m)
	elseif key == Enum.KeyCode.Up then
		m.onBeep("misc/menu1.wav")
		m.cursor = (m.cursor + MAIN_ITEMS - 1) % MAIN_ITEMS
	elseif key == Enum.KeyCode.Down then
		m.onBeep("misc/menu1.wav")
		m.cursor = (m.cursor + 1) % MAIN_ITEMS
	elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		m.onBeep("misc/menu2.wav")
		if m.cursor == 0 then
			if m.qwMode then
				-- C's QW menu: single player is a network-only notice
				m.print("QuakeWorld is network play only — other Roblox players join automatically")
			else
				-- Single Player submenu (New Game / Load / Save)
				enterState("singleplayer", 0)
			end
		elseif m.cursor == 1 then
			-- Multiplayer: the setup page (colors + translated player)
			enterState("setup", 0)
		elseif m.cursor == 2 then
			m.print("Options: use the console (~): sensitivity <n>")
		elseif m.cursor == 3 then
			m.state = "help"
			m.helpIndex = 0
			setMainVisible(m, false)
			showHelp(m)
		else
			menu.toggle(m)
			m.onQuit()
		end
	end
	return true
end

function menu.update(m: Menu, time: number)
	local dotY: number? = nil
	if m.state == "main" then
		dotY = 32 + m.cursor * 20
	elseif m.state == "singleplayer" then
		dotY = 32 + m.cursor * 20
	end
	if dotY then
		-- menudot animation: frame (int)(time*10)%6 at (54, y)
		local frame = math.floor(time * 10) % 6 + 1
		for i, dot in m.dots do
			dot.Visible = i == frame
			if i == frame then
				dot.Position = UDim2.fromOffset(54 * SCALE, dotY * SCALE)
				dot.ZIndex = 31
			end
		end
		return
	end
	for _, dot in m.dots do
		dot.Visible = false
	end
	-- load/save slot cursor + setup item cursor via a text '>' marker
	local marker = m.subFrame:FindFirstChild("cursorMark") :: TextLabel?
	if m.state == "load" or m.state == "save" or m.state == "setup" then
		if not marker then
			marker = Instance.new("TextLabel")
			local mk = marker :: TextLabel
			mk.Name = "cursorMark"
			mk.BackgroundTransparency = 1
			mk.Font = Enum.Font.Code
			mk.TextSize = 8 * SCALE
			mk.TextColor3 = Color3.fromRGB(255, 170, 60)
			mk.Size = UDim2.fromOffset(8 * SCALE, 8 * SCALE)
			mk.Parent = m.subFrame
		end
		local mk = marker :: TextLabel
		-- blink like C's 12+((int)(realtime*4)&1)
		mk.Text = if math.floor(time * 4) % 2 == 0 then ">" else " "
		if m.state == "setup" then
			local ys = { 80, 104, 140 }
			mk.Position = UDim2.fromOffset(56 * SCALE, ys[m.cursor + 1] * SCALE)
		else
			mk.Position = UDim2.fromOffset(8 * SCALE, (32 + m.cursor * 8) * SCALE)
		end
	end
end

return menu
