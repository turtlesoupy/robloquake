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
local confontlib = require(script.Parent.render.confont)

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
	-- the LibreQuake conchars font (shared with hud/menu) for button
	-- labels; nil falls back to a stock TextLabel
	font: confontlib.Font?,
}

-- tuning defaults
local TOUCH_LOOK_SENS = 0.28 -- degrees per pixel of drag
local PAD_YAW_SPEED = 240 -- degrees/second at full right-stick
local PAD_PITCH_FRACTION = 0.62 -- pitch speed relative to yaw
local PAD_DEADZONE = 0.24
local STICK_RADIUS = 55 -- px of knob travel on the touch stick
local STICK_DEADZONE = 0.12

-- palette shared with directorui (the modern product-UI look)
local TEXT = Color3.fromRGB(235, 235, 235)

-- hand-drawn button/joystick art (Document/Buttons: joystick.png,
-- button-up.png, button-pressed.png)
local BUTTON_UP = "rbxassetid://125568994803314"
local BUTTON_PRESSED = "rbxassetid://87094120696594"
local JOYSTICK_IMG = "rbxassetid://74482359771899"

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
		b.BackgroundTransparency = 1
		b.Text = ""

		local art = Instance.new("ImageLabel")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.Size = UDim2.fromScale(1, 1)
		art.Image = BUTTON_UP
		art.ScaleType = Enum.ScaleType.Fit
		art.Parent = b

		-- plain uppercase/space labels (FIRE, JUMP, SCORES) render in the
		-- LibreQuake conchars font, matching the menu/hud; anything else
		-- (the "»" weapon-cycle glyph isn't in that charset) falls back
		if deps.font and label:match("^[%u ]+$") then
			local scale = textSize / 8
			local holder = Instance.new("Frame")
			holder.BackgroundTransparency = 1
			holder.AnchorPoint = Vector2.new(0.5, 0.5)
			holder.Position = UDim2.fromScale(0.5, 0.5)
			holder.Size = UDim2.fromOffset(#label * 8 * scale, 8 * scale)
			holder.Parent = b
			local row = confontlib.newRow(holder, #label, scale)
			confontlib.setRow(deps.font, row, label)
		else
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Size = UDim2.fromScale(1, 1)
			l.Font = Enum.Font.GothamBold
			l.TextSize = textSize
			l.TextColor3 = TEXT
			l.TextTransparency = 0.1
			l.Text = label
			l.Parent = b
		end

		local hooks: ButtonHooks = {
			down = function()
				art.Image = BUTTON_PRESSED
				onDown()
			end,
			up = function()
				art.Image = BUTTON_UP
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

	-- right-hand cluster: two equal thumb buttons stacked against the
	-- right edge and lifted clear of the 96px HUD strip along the bottom
	-- (hud.luau's sbarStrip). FIRE sits just above the HUD, JUMP stacks
	-- above FIRE. Weapon switching is the tap-on-the-HUD-icon path, so
	-- there's no on-screen switch button. Offsets are from the bottom
	-- edge, so the whole cluster tracks the HUD regardless of screen size.
	makeButton("Jump", "JUMP", 24, Vector2.new(140, 140), Vector2.new(1, 1), UDim2.new(1, -40, 1, -280), function()
		deps.exec("+jump")
	end, function()
		deps.exec("-jump")
	end)
	makeButton("Fire", "FIRE", 24, Vector2.new(140, 140), Vector2.new(1, 1), UDim2.new(1, -40, 1, -116), function()
		deps.exec("+attack")
	end, function()
		deps.exec("-attack")
	end)

	-- dynamic thumbstick: rests at the same height as the FIRE button on
	-- the left edge (its center matches FIRE's center, 186px above the
	-- bottom), re-centers to wherever the thumb lands in the left half of
	-- the screen (see the InputBegan handler below), and hides while a
	-- movement touch is active
	local stickRest = UDim2.new(0, 115, 1, -186)
	local stickBase = Instance.new("ImageLabel")
	stickBase.Name = "Stick"
	stickBase.BackgroundTransparency = 1
	stickBase.Image = JOYSTICK_IMG
	stickBase.ScaleType = Enum.ScaleType.Fit
	stickBase.AnchorPoint = Vector2.new(0.5, 0.5)
	stickBase.Position = stickRest
	stickBase.Size = UDim2.fromOffset(150, 150)
	stickBase.Parent = gui
	-- knob is never seen (stickBase itself hides on touch-down); it just
	-- carries setStickOffset's position math
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(1, 1)
	knob.BackgroundTransparency = 1
	knob.BorderSizePixel = 0
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
		stickBase.Visible = true
		knob.Position = UDim2.fromScale(0.5, 0.5)
		input.setAnalogMove(0, 0)
	end

	-- any touch starting in the left half of the screen drives movement,
	-- exactly like the resting stick would; the visual hides on touch
	-- down (the thumb is over it anyway) and reappears on release. Any
	-- other touch not consumed by a button (see `processed` above) is
	-- camera look.
	UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if io.UserInputType ~= Enum.UserInputType.Touch or processed or not gui.Enabled then
			return
		end
		local pos = Vector2.new(io.Position.X, io.Position.Y)
		local vp = gui.AbsoluteSize
		if stickTouch == nil and pos.X < vp.X * 0.5 then
			stickTouch = io
			stickCenter = pos
			stickBase.Visible = false
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
