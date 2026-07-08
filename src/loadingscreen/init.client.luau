--!strict
-- Boot cover screen. ReplicatedFirst runs this before the join snapshot
-- finishes replicating, so it bridges the otherwise-blank gap between
-- Roblox's default loading screen and the engine's first rendered frame —
-- a cold server is still publishing the client bundle during that gap and
-- the engine draws nothing until it arrives.
--
-- Contract with the engine clients (src/client/init.client.luau and
-- qwclient.luau), via attributes on the LocalPlayer:
--   RQ_BootStatus  (string) — milestone text mirrored into the status line
--   RQ_FirstFrame  (true)   — first engine frame rendered; fade out and die
--
-- Everything here is frames + bundled fonts: no rbxassetid content, so a
-- cold CDN cache can't slow the cover screen itself.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "RQLoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 10_000 -- above every engine gui until dismissed
gui.Parent = player:WaitForChild("PlayerGui")

local back = Instance.new("Frame")
back.Size = UDim2.fromScale(1, 1)
back.BackgroundColor3 = Color3.fromRGB(14, 10, 8)
back.BorderSizePixel = 0
back.Parent = gui

-- "FRAG PARTY" in the LibreQuake conchars font, matching the in-game
-- menus. The cover must stay free of remote assets (a cold CDN cache
-- would blank it), so the glyph pixels are BAKED here — extracted from
-- gfx.wad conchars with the gold plaque tint pre-multiplied (regenerate
-- with `lune run tools/build_title_glyphs.luau` if the text changes).
-- Each lit pixel is one Frame in a design-px holder under a UIScale.
local TITLE_COLORS = {
	Color3.fromRGB(157, 123, 85),
	Color3.fromRGB(197, 155, 107),
	Color3.fromRGB(26, 20, 14),
}
-- "x,y,colorIndex" triples per lit pixel of each 8x8 conchars glyph
local TITLE_GLYPHS: { [string]: string } = {
	["F"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,2;2,1,3;3,1,3;4,1,3;5,1,3;6,1,3;1,2,1;2,2,3;1,3,2;2,3,2;3,3,2;4,3,2;5,3,2;1,4,1;2,4,3;3,4,3;4,4,3;5,4,3;6,4,3;1,5,2;2,5,3;1,6,1;2,6,3;1,7,3;2,7,3",
	["R"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,2;2,1,3;3,1,3;4,1,3;5,1,2;6,1,3;1,2,1;2,2,3;5,2,1;6,2,3;1,3,2;2,3,2;3,3,2;4,3,2;5,3,2;6,3,3;1,4,1;2,4,3;3,4,3;4,4,1;5,4,3;6,4,3;1,5,2;2,5,3;4,5,2;5,5,3;1,6,1;2,6,3;4,6,1;5,6,1;1,7,3;2,7,3;4,7,3;5,7,3;6,7,3",
	["A"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,2;2,1,3;3,1,3;4,1,3;5,1,2;6,1,3;1,2,1;2,2,3;5,2,1;6,2,3;1,3,2;2,3,2;3,3,2;4,3,2;5,3,2;6,3,3;1,4,1;2,4,3;3,4,3;4,4,3;5,4,1;6,4,3;1,5,2;2,5,3;5,5,2;6,5,3;1,6,1;2,6,3;5,6,1;6,6,3;1,7,3;2,7,3;5,7,3;6,7,3",
	["G"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,2;2,1,3;3,1,3;4,1,3;5,1,3;6,1,3;1,2,1;2,2,3;1,3,2;2,3,3;4,3,2;5,3,2;1,4,1;2,4,3;4,4,3;5,4,1;6,4,3;1,5,2;2,5,3;5,5,2;6,5,3;1,6,1;2,6,1;3,6,1;4,6,1;5,6,1;6,6,3;1,7,3;2,7,3;3,7,3;4,7,3;5,7,3;6,7,3",
	["P"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,2;2,1,3;3,1,3;4,1,3;5,1,2;6,1,3;1,2,1;2,2,3;5,2,1;6,2,3;1,3,2;2,3,2;3,3,2;4,3,2;5,3,2;6,3,3;1,4,1;2,4,3;3,4,3;4,4,3;5,4,3;6,4,3;1,5,2;2,5,3;1,6,1;2,6,3;1,7,3;2,7,3",
	["T"] = "1,0,1;2,0,1;3,0,1;4,0,1;5,0,1;1,1,3;2,1,3;3,1,2;4,1,3;5,1,3;6,1,3;3,2,1;4,2,3;3,3,2;4,3,3;3,4,1;4,4,3;3,5,2;4,5,3;3,6,1;4,6,3;3,7,3;4,7,3",
	["Y"] = "1,0,1;5,0,1;1,1,2;2,1,3;5,1,2;6,1,3;1,2,1;2,2,3;5,2,1;6,2,3;1,3,3;2,3,2;4,3,2;5,3,3;6,3,3;2,4,3;3,4,1;4,4,3;5,4,3;3,5,2;4,5,3;3,6,1;4,6,3;3,7,3;4,7,3",
}
local TITLE_TEXT = "FRAG PARTY"

local title = Instance.new("CanvasGroup")
title.BackgroundTransparency = 1
title.AnchorPoint = Vector2.new(0.5, 1)
title.Position = UDim2.fromScale(0.5, 0.46)
title.Size = UDim2.fromOffset(#TITLE_TEXT * 8, 8)
title.Parent = back
local titleScale = Instance.new("UIScale")
titleScale.Parent = title
for i = 1, #TITLE_TEXT do
	local px = TITLE_GLYPHS[TITLE_TEXT:sub(i, i)]
	if px then
		for x, y, c in px:gmatch("(%d+),(%d+),(%d+)") do
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.BackgroundColor3 = TITLE_COLORS[tonumber(c) :: number]
			f.Position = UDim2.fromOffset((i - 1) * 8 + (tonumber(x) :: number), tonumber(y) :: number)
			f.Size = UDim2.fromOffset(1, 1)
			f.Parent = title
		end
	end
end
-- integer scale keeps the pixels crisp; ~half the screen width
local function fitTitle()
	local w = back.AbsoluteSize.X
	if w > 0 then
		titleScale.Scale = math.max(1, math.floor(w * 0.5 / (#TITLE_TEXT * 8)))
	end
end
back:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTitle)
fitTitle()

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.fromScale(0.5, 0.5)
status.Size = UDim2.fromScale(1, 0.035)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Code
status.TextScaled = true
status.TextColor3 = Color3.fromRGB(140, 128, 116)
status.Parent = back

ReplicatedFirst:RemoveDefaultLoadingScreen()

-- status line = latest milestone + marching dots (fresh servers can hold
-- the bundle wait for a long time; motion says "not hung")
local statusText = "connecting"
local function readStatus()
	local s = player:GetAttribute("RQ_BootStatus")
	if typeof(s) == "string" and s ~= "" then
		statusText = s
	end
end
readStatus()
player:GetAttributeChangedSignal("RQ_BootStatus"):Connect(readStatus)

local dismissed = false
task.spawn(function()
	while not dismissed do
		local dots = string.rep(".", math.floor(os.clock() * 2.5) % 4)
		status.Text = statusText .. dots
		task.wait(0.15)
	end
end)

-- hold until the engine's first rendered frame; the deadline is a failsafe
-- so a boot that dies pre-frame leaves the console reachable, not a
-- permanent curtain
local deadline = os.clock() + 180
while player:GetAttribute("RQ_FirstFrame") ~= true and os.clock() < deadline do
	task.wait(0.1)
end

dismissed = true
local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
TweenService:Create(back, fade, { BackgroundTransparency = 1 }):Play()
TweenService:Create(title, fade, { GroupTransparency = 1 }):Play()
local st = TweenService:Create(status, fade, { TextTransparency = 1 })
st.Completed:Connect(function()
	gui:Destroy()
end)
st:Play()
