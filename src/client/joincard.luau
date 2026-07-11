--!strict
-- Join card (PRODUCT layer, NOT engine): one-time "how to play" overlay
-- for first-time players — paid-ads arrivals land in a fast FPS with no
-- explanation, and the funnel says they bounce early. The server side
-- (src/server/onboarding.luau) decides whether to show it (never
-- dismissed before) and persists the dismissal; this module also pings
-- the client platform so the onboarding funnel can split touch/desktop/
-- gamepad from its first step.
--
-- Boot-agnostic: talks only to the Onboard remote and the LocalPlayer
-- RQ_FirstFrame attribute (set by both engine clients when the world
-- first renders), so one require in init.client.luau covers NQ and QW.
--
-- REMOVAL: see src/server/onboarding.luau.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local input = require(script.Parent.input)

local joincard = {}

local GOLD = Color3.fromRGB(231, 183, 86)
local PARCHMENT = Color3.fromRGB(222, 205, 164)
local PANEL = Color3.fromRGB(24, 17, 12)
local PANEL_EDGE = Color3.fromRGB(94, 70, 34)

local function platformName(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	elseif UserInputService.GamepadEnabled then
		return "gamepad"
	end
	return "desktop"
end

-- control lines per platform (touch scheme: controls.luau — left half
-- moves, right half drags to aim, FIRE/JUMP buttons bottom right)
local CONTROLS: { [string]: { string } } = {
	touch = {
		"LEFT SIDE — MOVE",
		"RIGHT SIDE — DRAG TO AIM",
		"FIRE / JUMP — BOTTOM RIGHT",
	},
	gamepad = {
		"STICKS — MOVE + AIM",
		"R2 — SHOOT      A — JUMP",
	},
	desktop = {
		"WASD — MOVE      MOUSE — AIM",
		"CLICK — SHOOT      SPACE — JUMP",
	},
}

local function makeLabel(parent: Instance, text: string, size: number, color: Color3, bold: boolean): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size + 8)
	l.Font = if bold then Enum.Font.GothamBlack else Enum.Font.GothamMedium
	l.TextSize = size
	l.TextColor3 = color
	l.Text = text
	l.Parent = parent
	return l
end

local function showCard(onDone: () -> ())
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "RQJoinCard"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9_000 -- above the HUD, below the boot cover

	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.4
	dim.BorderSizePixel = 0
	dim.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.Size = UDim2.fromOffset(440, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = PANEL
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = PANEL_EDGE
	stroke.Thickness = 2
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 22)
	pad.PaddingBottom = UDim.new(0, 22)
	pad.PaddingLeft = UDim.new(0, 24)
	pad.PaddingRight = UDim.new(0, 24)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.Parent = panel
	-- phones: never wider than the screen
	local cam = workspace.CurrentCamera
	local vpw = if cam then cam.ViewportSize.X else 440
	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MaxSize = Vector2.new(math.min(440, vpw - 24), math.huge)
	sizeCap.Parent = panel

	local platform = platformName()
	makeLabel(panel, "WELCOME TO FRAG PARTY", 26, GOLD, true)
	makeLabel(panel, "MOST FRAGS WINS", 20, PARCHMENT, true)
	makeLabel(panel, "Grab weapons and armor around the map.", 16, PARCHMENT, false)
	makeLabel(panel, "Death is part of the party — you respawn instantly.", 16, PARCHMENT, false)
	makeLabel(panel, "", 6, PARCHMENT, false)
	for _, line in CONTROLS[platform] do
		makeLabel(panel, line, 16, GOLD, true)
	end
	makeLabel(panel, "", 6, PARCHMENT, false)

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.8, 0, 0, 52)
	btn.BackgroundColor3 = GOLD
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 22
	btn.TextColor3 = PANEL
	btn.Text = if platform == "desktop" then "LET'S GO  [ENTER]" else "LET'S GO"
	btn.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 8)
	bc.Parent = btn

	-- the engine owns the pointer (LockCenter) and the camera; hand the
	-- cursor back and freeze look while the card is up
	input.freeMouse()
	input.setLookLocked(true)

	local conns: { RBXScriptConnection } = {}
	local done = false
	local function dismiss()
		if done then
			return
		end
		done = true
		for _, c in conns do
			c:Disconnect()
		end
		gui:Destroy()
		input.setLookLocked(false)
		if platform ~= "touch" then
			input.lockMouse()
		end
		onDone()
	end
	table.insert(conns, btn.Activated:Connect(dismiss))
	table.insert(
		conns,
		UserInputService.InputBegan:Connect(function(io: InputObject)
			if io.KeyCode == Enum.KeyCode.Return or io.KeyCode == Enum.KeyCode.ButtonA then
				dismiss()
			end
		end)
	)
	gui.Parent = player:WaitForChild("PlayerGui")
end

function joincard.start()
	task.spawn(function()
		local net = ReplicatedStorage:WaitForChild("QuakeNet", 30)
		local remote = if net then net:WaitForChild("Onboard", 30) else nil
		if not remote or not remote:IsA("RemoteEvent") then
			return
		end
		-- platform ping: step 1 of the onboarding funnel carries this
		remote:FireServer("platform", platformName())
		remote.OnClientEvent:Connect(function(msg: unknown)
			if msg ~= "showIntro" then
				return
			end
			task.spawn(function()
				-- wait for the first rendered frame so the card sits over
				-- the world, not the boot cover
				local player = Players.LocalPlayer
				local deadline = os.clock() + 120
				while player:GetAttribute("RQ_FirstFrame") ~= true and os.clock() < deadline do
					task.wait(0.25)
				end
				task.wait(0.6) -- let the first frame land before overlaying
				showCard(function()
					remote:FireServer("introDone")
				end)
			end)
		end)
	end)
end

return joincard
