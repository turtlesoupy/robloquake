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

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 1)
title.Position = UDim2.fromScale(0.5, 0.46)
title.Size = UDim2.fromScale(1, 0.1)
title.BackgroundTransparency = 1
title.Font = Enum.Font.Arcade
title.TextScaled = true
title.TextColor3 = Color3.fromRGB(214, 168, 116)
title.Text = "FRAG PARTY"
title.Parent = back

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
TweenService:Create(title, fade, { TextTransparency = 1 }):Play()
local st = TweenService:Create(status, fade, { TextTransparency = 1 })
st.Completed:Connect(function()
	gui:Destroy()
end)
st:Play()
