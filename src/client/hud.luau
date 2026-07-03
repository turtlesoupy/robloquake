--!strict
-- Status bar — a compact port of sbar.c's essentials: sbar background,
-- health, armor, current ammo, and center prints, drawn from the real
-- gfx.wad pictures.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local wadlib = require(engine.gfx.wad)
local vfslib = require(engine.common.vfs)
local cllib = require(engine.client.cl)

local textures = require(script.Parent.render.textures)

local hud = {}

export type Hud = {
	gui: ScreenGui,
	healthLabel: TextLabel,
	armorLabel: TextLabel,
	ammoLabel: TextLabel,
	centerLabel: TextLabel,
	consoleLabel: TextLabel,
	centerTime: number,
	consoleLines: { string },
}

local SBAR_SCALE = 2 -- 320x24 sbar scaled up

function hud.create(fs: vfslib.Vfs, pal: textures.Palette, parent: Instance): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeHud"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.ResetOnSpawn = false

	-- sbar background
	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	if wadbuf then
		local w = wadlib.load(wadbuf)
		local sbarPic = wadlib.getPic(w, "sbar")
		local img = textures.createImage(sbarPic.pixels, sbarPic.width, sbarPic.height, pal, true)
		local sbar = Instance.new("ImageLabel")
		sbar.Name = "sbar"
		sbar.BackgroundTransparency = if img then 1 else 0.4
		sbar.BackgroundColor3 = Color3.fromRGB(60, 50, 40)
		if img then
			sbar.ImageContent = Content.fromObject(img)
		end
		sbar.ResampleMode = Enum.ResamplerMode.Pixelated
		sbar.AnchorPoint = Vector2.new(0.5, 1)
		sbar.Position = UDim2.new(0.5, 0, 1, 0)
		sbar.Size = UDim2.fromOffset(sbarPic.width * SBAR_SCALE, sbarPic.height * SBAR_SCALE)
		sbar.Parent = gui
	end

	local function numberLabel(name: string, xOffset: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Arcade
		label.TextColor3 = Color3.fromRGB(255, 180, 100)
		label.TextSize = 20 * SBAR_SCALE
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, xOffset * SBAR_SCALE, 1, -2 * SBAR_SCALE)
		label.Size = UDim2.fromOffset(70 * SBAR_SCALE, 20 * SBAR_SCALE)
		label.Text = "0"
		label.Parent = gui
		return label
	end

	-- sbar layout: armor at x~24, health at x~136, ammo at x~248 (of 320)
	local armorLabel = numberLabel("armor", 24 + 36 - 160)
	local healthLabel = numberLabel("health", 136 + 36 - 160)
	local ammoLabel = numberLabel("ammo", 248 + 36 - 160)

	local centerLabel = Instance.new("TextLabel")
	centerLabel.Name = "centerprint"
	centerLabel.BackgroundTransparency = 1
	centerLabel.Font = Enum.Font.Code
	centerLabel.TextColor3 = Color3.fromRGB(200, 160, 120)
	centerLabel.TextSize = 24
	centerLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	centerLabel.Position = UDim2.new(0.5, 0, 0.35, 0)
	centerLabel.Size = UDim2.new(0.8, 0, 0.3, 0)
	centerLabel.Text = ""
	centerLabel.TextWrapped = true
	centerLabel.Parent = gui

	local consoleLabel = Instance.new("TextLabel")
	consoleLabel.Name = "console"
	consoleLabel.BackgroundTransparency = 1
	consoleLabel.Font = Enum.Font.Code
	consoleLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	consoleLabel.TextSize = 16
	consoleLabel.TextXAlignment = Enum.TextXAlignment.Left
	consoleLabel.TextYAlignment = Enum.TextYAlignment.Top
	consoleLabel.Position = UDim2.new(0, 8, 0, 8)
	consoleLabel.Size = UDim2.new(0.7, 0, 0, 120)
	consoleLabel.Text = ""
	consoleLabel.Parent = gui

	gui.Parent = parent

	return {
		gui = gui,
		healthLabel = healthLabel,
		armorLabel = armorLabel,
		ammoLabel = ammoLabel,
		centerLabel = centerLabel,
		consoleLabel = consoleLabel,
		centerTime = 0,
		consoleLines = {},
	}
end

function hud.centerPrint(h: Hud, s: string, time: number)
	h.centerLabel.Text = (s:gsub("[\1\2]", ""))
	h.centerTime = time + 2 -- scr_centertime
end

function hud.print(h: Hud, s: string)
	-- quake uses high-bit chars for colored prints; strip them
	local clean = s:gsub("[\128-\255]", function(ch)
		return string.char(bit32.band(ch:byte(), 127))
	end)
	for line in clean:gmatch("[^\n]+") do
		table.insert(h.consoleLines, line)
	end
	while #h.consoleLines > 6 do
		table.remove(h.consoleLines, 1)
	end
	h.consoleLabel.Text = table.concat(h.consoleLines, "\n")
end

function hud.update(h: Hud, c: cllib.Client)
	h.healthLabel.Text = tostring(math.max(c.stats[cllib.STAT_HEALTH], 0))
	h.armorLabel.Text = tostring(c.stats[cllib.STAT_ARMOR])
	h.ammoLabel.Text = tostring(c.stats[cllib.STAT_AMMO])
	if h.centerTime > 0 and c.time > h.centerTime then
		h.centerLabel.Text = ""
		h.centerTime = 0
	end
end

return hud
