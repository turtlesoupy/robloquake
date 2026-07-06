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
	state: string, -- "none" | "main" | "help"
	cursor: number,
	helpIndex: number,
	-- item actions wired by the client
	onNewGame: () -> (),
	onQuit: () -> (),
	-- S_LocalSound hook (menu1/menu2 beeps); the boot wires soundlib
	onBeep: (name: string) -> (),
	print: (s: string) -> (),
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

function menu.toggle(m: Menu)
	m.onBeep("misc/menu1.wav") -- M_ToggleMenu_f's S_LocalSound
	if m.state == "none" then
		m.state = "main"
		m.cursor = 0
		m.gui.Visible = true
		setMainVisible(m, true)
		m.helpPage.Visible = false
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
			-- Single Player: new game
			menu.toggle(m)
			m.onNewGame()
		elseif m.cursor == 1 then
			m.print("Multiplayer: other Roblox players join your server automatically")
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
	if m.state ~= "main" then
		return
	end
	-- menudot animation: frame (int)(time*10)%6 at (54, 32 + cursor*20)
	local frame = math.floor(time * 10) % 6 + 1
	for i, dot in m.dots do
		dot.Visible = i == frame
		if i == frame then
			dot.Position = UDim2.fromOffset(54 * SCALE, (32 + m.cursor * 20) * SCALE)
		end
	end
end

return menu
