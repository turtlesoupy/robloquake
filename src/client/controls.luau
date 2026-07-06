--!strict
-- PRODUCT layer: touch + gamepad controls (phones/tablets, console,
-- and PC controllers). Pure input frontend over the exact same paths
-- keyboard and mouse use: buttons run console lines through the boot's
-- exec (+attack, impulse 10, togglemenu, ...) and sticks feed the input
-- module's analog-move / look-delta hooks, so the engine below never
-- learns what device produced a usercmd.
-- REMOVAL: delete this file, the controls.attach block in each boot,
-- and input.setAnalogMove/applyLook.
--
-- Live tuning (workspace attributes): RQ_TouchLookSens (deg/px, 0.28),
-- RQ_PadLookSens (deg/s at full stick, 240). Testing hooks:
-- RQDBG_ForceTouchUI (bool attr) forces the touch UI on/off;
-- RQDBG_Controls BindableFunction drives every code path without
-- hardware (see the dispatcher at the bottom).

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local input = require(script.Parent.input)

local controls = {}

export type Deps = {
	playerGui: PlayerGui,
	-- run a console line exactly as a bound key would
	exec: (line: string) -> (),
	-- console/menu/chat/vote UI is up: game buttons should not fire
	isUiOpen: () -> boolean,
	-- feed a synthesized key to the boot's menu (gamepad navigation);
	-- returns true when the menu was open and consumed it
	menuKey: (key: Enum.KeyCode) -> boolean,
}

-- tuning defaults
local TOUCH_LOOK_SENS = 0.28 -- degrees per pixel of drag
local PAD_YAW_SPEED = 240 -- degrees/second at full right-stick
local PAD_PITCH_FRACTION = 0.62 -- pitch speed relative to yaw
local PAD_DEADZONE = 0.24
local STICK_RADIUS = 55 -- px of knob travel on the touch stick
local STICK_DEADZONE = 0.12

-- palette shared with directorui (the modern product-UI look)
local ACCENT = Color3.fromRGB(255, 178, 60)
local BG = Color3.fromRGB(16, 16, 20)
local TEXT = Color3.fromRGB(235, 235, 235)

-- gamepad layout (standard console-FPS): R2 fire, A/L2 jump, R1/Y next
-- weapon, L1/DPad-down previous, Select hold = scores, Start = menu.
-- Hold entries are kbutton names (+x on down, -x on up); taps are lines.
local PAD_HOLD: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonR2] = "attack",
	[Enum.KeyCode.ButtonL2] = "jump",
	[Enum.KeyCode.ButtonA] = "jump",
	[Enum.KeyCode.ButtonSelect] = "showscores",
}
local PAD_TAP: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonR1] = "impulse 10",
	[Enum.KeyCode.ButtonY] = "impulse 10",
	[Enum.KeyCode.ButtonL1] = "impulse 12",
	[Enum.KeyCode.DPadUp] = "impulse 10",
	[Enum.KeyCode.DPadDown] = "impulse 12",
	[Enum.KeyCode.ButtonStart] = "togglemenu",
}
-- gamepad → Quake menu navigation while the menu is open
local PAD_MENU: { [Enum.KeyCode]: Enum.KeyCode } = {
	[Enum.KeyCode.ButtonA] = Enum.KeyCode.Return,
	[Enum.KeyCode.ButtonB] = Enum.KeyCode.Backspace,
	[Enum.KeyCode.ButtonStart] = Enum.KeyCode.M,
	[Enum.KeyCode.DPadUp] = Enum.KeyCode.Up,
	[Enum.KeyCode.DPadDown] = Enum.KeyCode.Down,
	[Enum.KeyCode.DPadLeft] = Enum.KeyCode.Left,
	[Enum.KeyCode.DPadRight] = Enum.KeyCode.Right,
}

local function attrNumber(name: string, default: number): number
	local v = workspace:GetAttribute(name)
	return if type(v) == "number" then v else default
end

-- rescale a stick vector past its deadzone to 0..1 magnitude
local function pastDeadzone(v: Vector2, deadzone: number): Vector2
	local m = v.Magnitude
	if m < deadzone then
		return Vector2.zero
	end
	return v.Unit * math.min((m - deadzone) / (1 - deadzone), 1)
end

function controls.attach(deps: Deps)
	----------------------------------------------------------------
	-- gamepad

	local heldPad: { [Enum.KeyCode]: string } = {}
	local rightStick = Vector2.zero

	local function padDown(key: Enum.KeyCode)
		local nav = PAD_MENU[key]
		if nav and deps.menuKey(nav) then
			return
		end
		local hold = PAD_HOLD[key]
		if hold then
			heldPad[key] = hold
			deps.exec("+" .. hold)
			return
		end
		local tap = PAD_TAP[key]
		if tap and (tap == "togglemenu" or not deps.isUiOpen()) then
			deps.exec(tap)
		end
	end

	local function padUp(key: Enum.KeyCode)
		local hold = heldPad[key]
		if hold then
			heldPad[key] = nil
			deps.exec("-" .. hold)
		end
	end

	local function padReset()
		input.setAnalogMove(0, 0)
		rightStick = Vector2.zero
		for key in heldPad do
			padUp(key)
		end
	end

	UserInputService.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType ~= Enum.UserInputType.Gamepad1 then
			return
		end
		if io.KeyCode == Enum.KeyCode.Thumbstick1 then
			local v = pastDeadzone(Vector2.new(io.Position.X, io.Position.Y), PAD_DEADZONE)
			input.setAnalogMove(v.Y, v.X)
		elseif io.KeyCode == Enum.KeyCode.Thumbstick2 then
			rightStick = Vector2.new(io.Position.X, io.Position.Y)
		end
	end)

	UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if io.UserInputType == Enum.UserInputType.Gamepad1 and not processed then
			padDown(io.KeyCode)
		end
	end)
	UserInputService.InputEnded:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.Gamepad1 then
			padUp(io.KeyCode)
		end
	end)
	UserInputService.GamepadDisconnected:Connect(function(pad: Enum.UserInputType)
		if pad == Enum.UserInputType.Gamepad1 then
			padReset()
		end
	end)

	-- right stick → view angles, integrated per frame with a squared
	-- response curve (fine aim near center, fast flicks at the rim)
	RunService.Heartbeat:Connect(function(dt: number)
		local v = pastDeadzone(rightStick, PAD_DEADZONE)
		if v == Vector2.zero then
			return
		end
		local curved = v * v.Magnitude
		local yawSpeed = attrNumber("RQ_PadLookSens", PAD_YAW_SPEED)
		-- stick right turns right (negative quake yaw), stick up looks
		-- up (negative quake pitch)
		input.applyLook(-curved.X * yawSpeed * dt, -curved.Y * yawSpeed * PAD_PITCH_FRACTION * dt)
	end)

	----------------------------------------------------------------
	-- touch UI

	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeTouchControls"
	gui.ResetOnSpawn = false
	-- above the HUD (10, its letterbox wings would swallow the corner
	-- buttons) but under the console overlay (20) and director UI (30)
	gui.DisplayOrder = 15
	gui.IgnoreGuiInset = true -- align gui space with InputObject.Position
	gui.Enabled = false
	gui.Parent = deps.playerGui

	local function styleCircle(f: GuiObject): UIStroke
		f.BackgroundColor3 = BG
		f.BackgroundTransparency = 0.4
		f.BorderSizePixel = 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = f
		local s = Instance.new("UIStroke")
		-- Contextual mode would outline the (empty) text on TextButtons;
		-- Border rings the circle on Frames and buttons alike
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Color = ACCENT
		s.Thickness = 2
		s.Transparency = 0.25
		s.Parent = f
		return s
	end

	type ButtonHooks = { down: () -> (), up: () -> () }
	local namedButtons: { [string]: ButtonHooks } = {}

	local function makeButton(
		name: string,
		label: string,
		textSize: number,
		size: Vector2,
		anchor: Vector2,
		pos: UDim2,
		onDown: () -> (),
		onUp: (() -> ())?
	): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.AnchorPoint = anchor
		b.Position = pos
		b.Size = UDim2.fromOffset(size.X, size.Y)
		b.AutoButtonColor = false
		b.Text = ""
		local strokeObj = styleCircle(b)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.fromScale(1, 1)
		l.Font = Enum.Font.GothamBold
		l.TextSize = textSize
		l.TextColor3 = TEXT
		l.TextTransparency = 0.1
		l.Text = label
		l.Parent = b

		local hooks: ButtonHooks = {
			down = function()
				b.BackgroundTransparency = 0.12
				strokeObj.Transparency = 0
				onDown()
			end,
			up = function()
				b.BackgroundTransparency = 0.4
				strokeObj.Transparency = 0.25
				if onUp then
					onUp()
				end
			end,
		}
		namedButtons[name] = hooks

		b.InputBegan:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				hooks.down()
			end
		end)
		b.InputEnded:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				hooks.up()
			end
		end)
		b.Parent = gui
		return b
	end

	-- right-hand cluster: big FIRE under the thumb, JUMP in the corner,
	-- next-weapon above it
	makeButton("Fire", "FIRE", 18, Vector2.new(100, 100), Vector2.new(1, 1), UDim2.new(1, -128, 1, -104), function()
		deps.exec("+attack")
	end, function()
		deps.exec("-attack")
	end)
	makeButton("Jump", "JUMP", 15, Vector2.new(74, 74), Vector2.new(1, 1), UDim2.new(1, -28, 1, -28), function()
		deps.exec("+jump")
	end, function()
		deps.exec("-jump")
	end)
	makeButton("Weapon", "»", 30, Vector2.new(56, 56), Vector2.new(1, 1), UDim2.new(1, -36, 1, -128), function()
		if not deps.isUiOpen() then
			deps.exec("impulse 10")
		end
	end)

	-- scoreboard is a toggle on touch (holding is awkward mid-fight);
	-- top-center keeps clear of Roblox's corner chrome
	local scoresOn = false
	makeButton("Scores", "SCORES", 13, Vector2.new(92, 38), Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 12), function()
		scoresOn = not scoresOn
		deps.exec(if scoresOn then "+showscores" else "-showscores")
	end)

	-- dynamic thumbstick: rests bottom-left, re-centers to wherever the
	-- thumb lands in the left 45% of the screen
	local stickRest = UDim2.new(0, 128, 1, -140)
	local stickBase = Instance.new("Frame")
	stickBase.Name = "Stick"
	stickBase.AnchorPoint = Vector2.new(0.5, 0.5)
	stickBase.Position = stickRest
	stickBase.Size = UDim2.fromOffset(150, 150)
	local baseStroke = styleCircle(stickBase)
	stickBase.BackgroundTransparency = 0.55
	stickBase.Parent = gui
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(62, 62)
	knob.BackgroundColor3 = TEXT
	knob.BackgroundTransparency = 0.45
	knob.BorderSizePixel = 0
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob
	knob.Parent = stickBase

	local stickTouch: InputObject? = nil
	local stickCenter = Vector2.zero
	local lookTouches: { [InputObject]: boolean } = {}

	local function setStickOffset(offset: Vector2)
		if offset.Magnitude > STICK_RADIUS then
			offset = offset.Unit * STICK_RADIUS
		end
		knob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		local v = pastDeadzone(offset / STICK_RADIUS, STICK_DEADZONE)
		-- screen Y grows downward: up-drag = forward
		input.setAnalogMove(-v.Y, v.X)
	end

	local function releaseStick()
		stickTouch = nil
		stickBase.Position = stickRest
		stickBase.BackgroundTransparency = 0.55
		baseStroke.Transparency = 0.25
		knob.Position = UDim2.fromScale(0.5, 0.5)
		input.setAnalogMove(0, 0)
	end

	UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if io.UserInputType ~= Enum.UserInputType.Touch or processed or not gui.Enabled then
			return
		end
		local pos = Vector2.new(io.Position.X, io.Position.Y)
		local vp = gui.AbsoluteSize
		if stickTouch == nil and pos.X < vp.X * 0.45 and pos.Y > vp.Y * 0.25 then
			stickTouch = io
			stickCenter = pos
			stickBase.Position = UDim2.fromOffset(pos.X, pos.Y)
			stickBase.BackgroundTransparency = 0.4
			baseStroke.Transparency = 0.15
			setStickOffset(Vector2.zero)
		else
			lookTouches[io] = true
		end
	end)

	UserInputService.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if io == stickTouch then
			setStickOffset(Vector2.new(io.Position.X, io.Position.Y) - stickCenter)
		elseif lookTouches[io] then
			local sens = attrNumber("RQ_TouchLookSens", TOUCH_LOOK_SENS)
			-- same directions as IN_MouseMove: drag left turns left,
			-- drag down looks down
			input.applyLook(-io.Delta.X * sens, io.Delta.Y * sens)
		end
	end)

	UserInputService.InputEnded:Connect(function(io: InputObject)
		if io.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if io == stickTouch then
			releaseStick()
		else
			lookTouches[io] = nil
		end
	end)

	----------------------------------------------------------------
	-- device detection: the touch UI shows on touch-first devices and
	-- steps aside while a controller is the active input

	local function touchWanted(): boolean
		local force = workspace:GetAttribute("RQDBG_ForceTouchUI")
		if type(force) == "boolean" then
			return force
		end
		if not UserInputService.TouchEnabled then
			return false
		end
		-- desktop touchscreens keep keyboard+mouse controls
		if UserInputService.KeyboardEnabled and UserInputService.MouseEnabled then
			return false
		end
		if UserInputService:GetLastInputType() == Enum.UserInputType.Gamepad1 then
			return false
		end
		return true
	end

	local function refreshTouchUi()
		local want = touchWanted()
		if gui.Enabled and not want and stickTouch ~= nil then
			releaseStick()
		end
		gui.Enabled = want
	end
	UserInputService.LastInputTypeChanged:Connect(refreshTouchUi)
	workspace:GetAttributeChangedSignal("RQDBG_ForceTouchUI"):Connect(refreshTouchUi)
	refreshTouchUi()

	----------------------------------------------------------------
	-- verification hook: drive every path without hardware

	local dbg = Instance.new("BindableFunction")
	dbg.Name = "RQDBG_Controls"
	dbg.Parent = workspace
	dbg.OnInvoke = function(action: string, a: string?, b: string?): string
		if action == "info" then
			return ("touch=%s stick=%.2f,%.2f pads=%d"):format(
				tostring(gui.Enabled),
				rightStick.X,
				rightStick.Y,
				#UserInputService:GetConnectedGamepads()
			)
		elseif action == "stick" then
			-- left-stick deflection: stick <forward> <side>
			input.setAnalogMove(tonumber(a) or 0, tonumber(b) or 0)
			return "ok"
		elseif action == "rightstick" then
			-- held right-stick deflection: rightstick <x> <y>
			rightStick = Vector2.new(tonumber(a) or 0, tonumber(b) or 0)
			return "ok"
		elseif action == "look" then
			input.applyLook(tonumber(a) or 0, tonumber(b) or 0)
			return "ok"
		elseif action == "pad" then
			-- pad <KeyCodeName> <down|up>
			local key = (Enum.KeyCode :: any)[a]
			if not key then
				return "unknown keycode"
			end
			if b == "down" then
				padDown(key)
			else
				padUp(key)
			end
			return "ok"
		elseif action == "press" or action == "release" then
			local hooks = namedButtons[a :: string]
			if not hooks then
				return "unknown button"
			end
			if action == "press" then
				hooks.down()
			else
				hooks.up()
			end
			return "ok"
		end
		return ""
	end
end

return controls
