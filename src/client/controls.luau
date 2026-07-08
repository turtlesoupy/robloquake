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
	-- score screen is up or the player is dead: any screen tap presses
	-- fire (advance the intermission / respawn)
	tapFires: (() -> boolean)?,
}

-- tuning defaults
local TOUCH_LOOK_SENS = 0.28 -- degrees per pixel of drag
local PAD_YAW_SPEED = 240 -- degrees/second at full right-stick
local PAD_PITCH_FRACTION = 0.62 -- pitch speed relative to yaw
local PAD_DEADZONE = 0.24
local STICK_RADIUS = 55 -- px of knob travel on the touch stick
local STICK_DEADZONE = 0.12

-- hand-drawn button/joystick art (source PNGs: art/buttons/; re-upload
-- via Studio MCP upload_image and paste the new ids here if these ever
-- 404 — they must be image assets owned by the publishing account).
-- Icons are baked into the art (chevron = jump, crosshair = fire), so
-- buttons carry no text label; pressed feedback is an ImageColor3 tint.
local BTN_JUMP = "rbxassetid://128706151168029"
local BTN_FIRE = "rbxassetid://120257988469430"
local JOYSTICK_IMG = "rbxassetid://116090970539726"
local PRESSED_TINT = Color3.fromRGB(140, 140, 140)

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
		image: string,
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
		art.Image = image
		art.ScaleType = Enum.ScaleType.Fit
		art.Parent = b

		local hooks: ButtonHooks = {
			down = function()
				art.ImageColor3 = PRESSED_TINT
				onDown()
			end,
			up = function()
				art.ImageColor3 = Color3.new(1, 1, 1)
				if onUp then
					onUp()
				end
			end,
		}
		namedButtons[name] = hooks

		-- touch presses must be DISTINCT: a look-drag sliding over the button
		-- also delivers InputBegan (state Change, not Begin) and is ignored.
		-- Once pressed, the SAME finger drags the camera while the button
		-- stays held (press fire, then aim while it repeats) — one-way only:
		-- press->look works, look->press doesn't.
		local pressing: InputObject? = nil
		b.InputBegan:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.Touch then
				if io.UserInputState ~= Enum.UserInputState.Begin or pressing ~= nil then
					return
				end
				pressing = io
				hooks.down()
			elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
				hooks.down()
			end
		end)
		b.InputEnded:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.MouseButton1 then
				hooks.up()
			end
		end)
		UserInputService.InputChanged:Connect(function(io: InputObject)
			if io == pressing then
				local sens = attrNumber("RQ_TouchLookSens", TOUCH_LOOK_SENS)
				input.applyLook(-io.Delta.X * sens, io.Delta.Y * sens)
			end
		end)
		-- touch release rides UserInputService: GuiObject.InputEnded misses
		-- touches that end after sliding OFF the button, sticking it down
		UserInputService.InputEnded:Connect(function(io: InputObject)
			if io == pressing then
				pressing = nil
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
	local jumpBtn = makeButton("Jump", BTN_JUMP, Vector2.new(140, 140), Vector2.new(1, 1), UDim2.new(1, -40, 1, -280), function()
		deps.exec("+jump")
	end, function()
		deps.exec("-jump")
	end)
	local fireBtn = makeButton("Fire", BTN_FIRE, Vector2.new(140, 140), Vector2.new(1, 1), UDim2.new(1, -40, 1, -116), function()
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
	local intermissionTouches: { [InputObject]: boolean } = {}

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
		knob.Position = UDim2.fromScale(0.5, 0.5)
		input.setAnalogMove(0, 0)
	end

	-- any touch starting in the left half of the screen drives movement,
	-- exactly like the resting stick would; the visual stays put under
	-- the thumb (re-centered to the touch point) so the stick doesn't
	-- vanish mid-drag. Any other touch not consumed by a button (see
	-- `processed` above) is camera look.
	UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if io.UserInputType ~= Enum.UserInputType.Touch or processed or not gui.Enabled then
			return
		end
		-- score screen / death: any tap presses fire to advance the
		-- intermission or respawn, same as the desktop attack bind
		-- (released in InputEnded below)
		if deps.tapFires and deps.tapFires() and not deps.isUiOpen() then
			intermissionTouches[io] = true
			deps.exec("+attack")
			return
		end
		local pos = Vector2.new(io.Position.X, io.Position.Y)
		local vp = gui.AbsoluteSize
		if stickTouch == nil and pos.X < vp.X * 0.5 then
			stickTouch = io
			stickCenter = pos
			stickBase.Position = UDim2.fromOffset(pos.X, pos.Y)
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
			if intermissionTouches[io] then
				intermissionTouches[io] = nil
				deps.exec("-attack")
			end
		end
	end)

	-- responsive layout: fixed 140px buttons are enormous on small phones.
	-- Scale with viewport height (~80% of the first pass after playtest
	-- feedback), flush against the screen edges (no inset), clear of the
	-- HUD strip (whose height now shrinks on phones — read it live, don't
	-- assume 96px). FIRE takes the top slot, JUMP the bottom; the stick's
	-- rest pose mirrors the bottom button.
	local hudStrip: Frame? = nil
	local function layoutTouch()
		local vs = gui.AbsoluteSize
		if vs.X <= 0 or vs.Y <= 0 then
			return
		end
		local stripH = if hudStrip then math.floor(hudStrip.AbsoluteSize.Y) else 96
		local btn = math.clamp(math.floor(vs.Y * 0.21), 52, 112)
		local bottom = math.max(stripH, 24) + 10 -- HUD strip + a thumb gap
		fireBtn.Size = UDim2.fromOffset(btn, btn)
		jumpBtn.Size = UDim2.fromOffset(btn, btn)
		jumpBtn.Position = UDim2.new(1, 0, 1, -bottom)
		fireBtn.Position = UDim2.new(1, 0, 1, -(bottom + btn + 10))
		local stickSize = math.clamp(math.floor(vs.Y * 0.24), 64, 120)
		stickBase.Size = UDim2.fromOffset(stickSize, stickSize)
		stickRest = UDim2.new(0, stickSize // 2, 1, -(bottom + btn // 2))
		if stickTouch == nil then
			stickBase.Position = stickRest
		end
	end
	do
		-- both boots create the HUD before attaching controls
		local hudGui = deps.playerGui:FindFirstChild("QuakeHud")
		local s = if hudGui then hudGui:FindFirstChild("sbarStrip") else nil
		if s and s:IsA("Frame") then
			hudStrip = s
			s:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutTouch)
		end
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutTouch)
	layoutTouch()

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
