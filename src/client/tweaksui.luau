--!strict
-- Tweaks menu (PRODUCT layer, NOT engine): client-side visual tweaks,
-- currently procedural weapon skins per weapon. Toggled with T (Quake
-- talk sits on Y in the QW boot, and Roblox core scripts reserve keys
-- like I/O/Esc), built with plain Roblox UI like directorui.luau so the
-- Quake renderer/HUD stay untouched and this file can be deleted at any
-- time. Selections are local to this client and session.

local UserInputService = game:GetService("UserInputService")

local tweaksui = {}

local ACCENT = Color3.fromRGB(255, 178, 60)
local BG = Color3.fromRGB(16, 16, 20)
local CARD = Color3.fromRGB(34, 34, 40)
local TEXT = Color3.fromRGB(235, 235, 235)
local DIM = Color3.fromRGB(150, 150, 155)

local WEAPONS: { { name: string, mdl: string } } = {
	{ name = "Axe", mdl = "progs/v_axe.mdl" },
	{ name = "Shotgun", mdl = "progs/v_shot.mdl" },
	{ name = "Double-barreled Shotgun", mdl = "progs/v_shot2.mdl" },
	{ name = "Nailgun", mdl = "progs/v_nail.mdl" },
	{ name = "Super Nailgun", mdl = "progs/v_nail2.mdl" },
	{ name = "Grenade Launcher", mdl = "progs/v_rock.mdl" },
	{ name = "Rocket Launcher", mdl = "progs/v_rock2.mdl" },
	{ name = "Thunderbolt", mdl = "progs/v_light.mdl" },
}

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: Instance, color: Color3, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.Parent = inst
	return s
end

local function label(parent: Instance, text: string, size: number, color: Color3, bold: boolean): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.GothamMedium
	l.TextSize = size
	l.TextColor3 = color
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = CARD
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = TEXT
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 8)
	return b
end

export type Opts = {
	playerGui: Instance,
	isTyping: () -> boolean,
	-- fired when the menu opens/closes so the boot can free the cursor
	onUiToggle: ((open: boolean) -> ())?,
	-- nil spec restores the weapon's authentic skin
	setWeaponSkin: (mdlName: string, spec: string?) -> (),
	-- grant every weapon (+ ammo); omitted when the engine has no
	-- client-reachable give (QW gates cheats behind the host console)
	giveAll: (() -> ())?,
	-- flip the chase camera (chase_active) and return the new state;
	-- omitted when the engine has no self chase cam (QW)
	toggleThirdPerson: (() -> boolean)?,
	-- pause-menu (E) font style: big bronze plaque vs small classic
	menuFont: { isBig: () -> boolean, setBig: (on: boolean) -> () }?,
}

function tweaksui.attach(opts: Opts)
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeTweaks"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.IgnoreGuiInset = true
	gui.Parent = opts.playerGui

	-- left side, mirroring the admin menu's right-side placement so both
	-- can be open at once
	local menu = Instance.new("Frame")
	menu.Name = "Panel"
	menu.AnchorPoint = Vector2.new(0, 0.5)
	menu.Position = UDim2.new(0, 12, 0.5, 0)
	menu.Size = UDim2.new(0, 360, 0.86, 0)
	menu.BackgroundColor3 = BG
	menu.BackgroundTransparency = 0.06
	menu.Visible = false
	menu.Parent = gui
	corner(menu, 12)
	stroke(menu, Color3.new(1, 1, 1), 0.85)
	local menuSize = Instance.new("UISizeConstraint")
	menuSize.MaxSize = Vector2.new(360, 720)
	menuSize.MinSize = Vector2.new(300, 320)
	menuSize.Parent = menu

	local function setMenuVisible(open: boolean)
		if menu.Visible == open then
			return
		end
		menu.Visible = open
		if opts.onUiToggle then
			opts.onUiToggle(open)
		end
	end

	local title = label(menu, "TWEAKS", 16, ACCENT, true)
	title.Position = UDim2.new(0, 16, 0, 12)
	title.Size = UDim2.new(1, -70, 0, 20)
	title.TextXAlignment = Enum.TextXAlignment.Left

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.Size = UDim2.fromOffset(32, 32)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 18
	closeBtn.TextColor3 = DIM
	closeBtn.Text = "X"
	closeBtn.Parent = menu

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.Position = UDim2.new(0, 12, 0, 44)
	scroll.Size = UDim2.new(1, -24, 1, -56)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Parent = menu
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	local order = 0
	if opts.giveAll or opts.toggleThirdPerson then
		local loadoutLabel = label(scroll, "LOADOUT", 12, DIM, true)
		loadoutLabel.Size = UDim2.new(1, 0, 0, 16)
		loadoutLabel.TextXAlignment = Enum.TextXAlignment.Left
		loadoutLabel.LayoutOrder = order
		order += 1

		local loadoutRow = Instance.new("Frame")
		loadoutRow.Name = "Loadout"
		loadoutRow.BackgroundTransparency = 1
		loadoutRow.Size = UDim2.new(1, 0, 0, 44)
		loadoutRow.LayoutOrder = order
		loadoutRow.Parent = scroll
		order += 1
		local loadoutLayout = Instance.new("UIListLayout")
		loadoutLayout.FillDirection = Enum.FillDirection.Horizontal
		loadoutLayout.SortOrder = Enum.SortOrder.LayoutOrder
		loadoutLayout.Padding = UDim.new(0, 6)
		loadoutLayout.Parent = loadoutRow

		if opts.giveAll then
			local giveBtn = button(loadoutRow, "GIVE ALL WEAPONS")
			giveBtn.Name = "GiveAll"
			giveBtn.TextColor3 = ACCENT
			giveBtn.LayoutOrder = 1
			giveBtn.Size = if opts.toggleThirdPerson then UDim2.new(0.55, -3, 1, 0) else UDim2.new(1, 0, 1, 0)
			giveBtn.Activated:Connect(function()
				(opts.giveAll :: () -> ())()
			end)
		end

		if opts.toggleThirdPerson then
			local chaseBtn = button(loadoutRow, "3RD PERSON: OFF")
			chaseBtn.Name = "ThirdPerson"
			chaseBtn.LayoutOrder = 2
			chaseBtn.Size = if opts.giveAll then UDim2.new(0.45, -3, 1, 0) else UDim2.new(1, 0, 1, 0)
			chaseBtn.Activated:Connect(function()
				local on = (opts.toggleThirdPerson :: () -> boolean)()
				chaseBtn.Text = `3RD PERSON: {if on then "ON" else "OFF"}`
				chaseBtn.TextColor3 = if on then ACCENT else TEXT
			end)
		end
	end

	if opts.menuFont then
		local mf = opts.menuFont
		local fontLabel = label(scroll, "PAUSE MENU (\\)", 12, DIM, true)
		fontLabel.Size = UDim2.new(1, 0, 0, 16)
		fontLabel.TextXAlignment = Enum.TextXAlignment.Left
		fontLabel.LayoutOrder = order
		order += 1

		local fontBtn = button(scroll, "")
		fontBtn.Name = "MenuFont"
		fontBtn.Size = UDim2.new(1, 0, 0, 44)
		fontBtn.LayoutOrder = order
		order += 1
		local function refresh()
			local big = mf.isBig()
			fontBtn.Text = `MENU FONT: {if big then "BIG PLAQUE" else "CLASSIC"}`
			fontBtn.TextColor3 = if big then ACCENT else TEXT
		end
		refresh()
		fontBtn.Activated:Connect(function()
			mf.setBig(not mf.isBig())
			refresh()
		end)
	end

	local sectionLabel = label(scroll, "WEAPON SKINS", 12, DIM, true)
	sectionLabel.Size = UDim2.new(1, 0, 0, 16)
	sectionLabel.TextXAlignment = Enum.TextXAlignment.Left
	sectionLabel.LayoutOrder = order
	order += 1

	-- one skin list for ALL weapons: clicking a skin applies it to every
	-- viewmodel at once (procedural skins forge per-model from the recipe,
	-- so one spec fits all guns). REROLL rolls a fresh seed for that skin.
	local SKINS: { { key: string, name: string } } = {
		{ key = "camo", name = "CAMO" },
		{ key = "zebra", name = "ZEBRA" },
		{ key = "lightning", name = "LIGHTNING" },
		{ key = "leopard", name = "LEOPARD" },
		{ key = "cottoncandy", name = "COTTON CANDY" },
		{ key = "tortoise", name = "TORTOISE SHELL" },
		{ key = "matteblack", name = "MATTE BLACK" },
		{ key = "ghostwhite", name = "GHOST WHITE" },
		{ key = "deeppurple", name = "DEEP PURPLE" },
		{ key = "grass", name = "GRASS" },
		{ key = "clouds", name = "CLOUDS" },
		{ key = "stone", name = "STONE" },
		{ key = "herringbone", name = "HERRINGBONE" },
		{ key = "checkered", name = "CHECKERED" },
		{ key = "pinstripe", name = "PINSTRIPE" },
		{ key = "argyle", name = "ARGYLE" },
		{ key = "dragon", name = "DRAGON" },
		{ key = "lava", name = "LAVA" },
		{ key = "ocean", name = "OCEAN" },
		{ key = "circuit", name = "CIRCUIT BOARD" },
		{ key = "rust", name = "RUST" },
		{ key = "galaxy", name = "GALAXY" },
		{ key = "honeycomb", name = "HONEYCOMB" },
		{ key = "tiger", name = "TIGER" },
		{ key = "snakeskin", name = "SNAKESKIN" },
		{ key = "blueprint", name = "BLUEPRINT" },
		{ key = "glitch", name = "GLITCH" },
		{ key = "wood", name = "WOOD" },
		{ key = "candycane", name = "CANDY CANE" },
		{ key = "hazard", name = "HAZARD" },
		{ key = "oilslick", name = "OIL SLICK" },
		{ key = "mossystone", name = "MOSSY STONE" },
	}

	local specLbl = label(scroll, "current: default", 11, DIM, false)
	specLbl.Size = UDim2.new(1, 0, 0, 14)
	specLbl.TextXAlignment = Enum.TextXAlignment.Left
	specLbl.LayoutOrder = order
	order += 1

	local rowStrokes: { [string]: UIStroke } = {}
	local function applyAll(key: string, spec: string?)
		for _, w in WEAPONS do
			opts.setWeaponSkin(w.mdl, spec)
		end
		specLbl.Text = `current: {spec or "default"}`
		specLbl.TextColor3 = if spec then ACCENT else DIM
		for k, st in rowStrokes do
			st.Transparency = if k == key then 0.1 else 1
		end
	end

	local defBtn = button(scroll, "DEFAULT")
	defBtn.Name = "SkinDefault"
	defBtn.Size = UDim2.new(1, 0, 0, 44)
	defBtn.LayoutOrder = order
	order += 1
	rowStrokes.default = stroke(defBtn, ACCENT, 0.1)
	defBtn.Activated:Connect(function()
		applyAll("default", nil)
	end)

	for _, skin in SKINS do
		local row = Instance.new("Frame")
		row.Name = "Skin" .. skin.name:gsub("%W", "")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 44)
		row.LayoutOrder = order
		row.Parent = scroll
		order += 1
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 6)
		rowLayout.Parent = row

		local nameBtn = button(row, skin.name)
		nameBtn.Name = "Apply"
		nameBtn.LayoutOrder = 1
		nameBtn.Size = UDim2.new(0.7, -3, 1, 0)
		rowStrokes[skin.key] = stroke(nameBtn, ACCENT, 1)
		local rollBtn = button(row, "REROLL \u{1F3B2}")
		rollBtn.Name = "Reroll"
		rollBtn.LayoutOrder = 2
		rollBtn.Size = UDim2.new(0.3, -3, 1, 0)

		nameBtn.Activated:Connect(function()
			applyAll(skin.key, `{skin.key}:7`)
		end)
		rollBtn.Activated:Connect(function()
			applyAll(skin.key, `{skin.key}:{math.random(0, 999999)}`)
		end)
	end

	local footer = label(scroll, "skins are client-side  ·  applies to all weapons  ·  reroll for a fresh pattern", 11, DIM, false)
	footer.Size = UDim2.new(1, 0, 0, 24)
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.TextWrapped = true
	footer.LayoutOrder = order

	closeBtn.Activated:Connect(function()
		setMenuVisible(false)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or opts.isTyping() then
			return
		end
		if input.KeyCode == Enum.KeyCode.T then
			setMenuVisible(not menu.Visible)
		end
	end)
end

return tweaksui
