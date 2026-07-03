--!strict
-- Input: keyboard/mouse to Quake usercmds and view angles. Mirrors the
-- default Quake bindings (always mouselook, always run off).

local UserInputService = game:GetService("UserInputService")

local input = {}

export type InputState = {
	forwardmove: number,
	sidemove: number,
	upmove: number,
	attack: boolean,
	jump: boolean,
	impulse: number,
}

-- cl_forwardspeed etc.; +speed doubles via cl_movespeedkey
local cl_forwardspeed = 200
local cl_backspeed = 200
local cl_sidespeed = 350
local cl_upspeed = 200
local cl_movespeedkey = 2
local m_yaw = 0.022
local m_pitch = 0.022
local sensitivity = 3

local keysDown: { [Enum.KeyCode]: boolean } = {}
local attackDown = false
local attackImpulse = false -- edge-trigger latch (in_attack.state & 2)
local jumpImpulse = false
local pendingImpulse = 0

local yaw = 0
local pitch = 0

function input.init(startYaw: number)
	yaw = startYaw
	pitch = 0

	UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
		if processed then
			return
		end
		if io.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[io.KeyCode] = true
			if io.KeyCode == Enum.KeyCode.Space then
				jumpImpulse = true
			end
			-- weapon impulses
			local n = io.KeyCode.Value - Enum.KeyCode.Zero.Value
			if n >= 1 and n <= 8 then
				pendingImpulse = n
			end
		elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
			attackDown = true
			attackImpulse = true
		end
	end)

	UserInputService.InputEnded:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[io.KeyCode] = nil
		elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
			attackDown = false
		end
	end)

	UserInputService.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseMovement then
			yaw -= io.Delta.X * m_yaw * sensitivity
			pitch += io.Delta.Y * m_pitch * sensitivity
			pitch = math.clamp(pitch, -70, 80)
		end
	end)

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
end

function input.lockMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
end

-- returns viewangles (quake pitch/yaw/roll degrees)
function input.viewangles(): vector
	return vector.create(pitch, yaw, 0)
end

-- svc_setangle: the server takes control of the view direction
function input.setAngles(angles: vector)
	pitch = angles.x
	yaw = angles.y
end

local function key(k: Enum.KeyCode): number
	return if keysDown[k] then 1 else 0
end

-- CL_BaseMove
function input.sample(): InputState
	local fwd = key(Enum.KeyCode.W) + key(Enum.KeyCode.Up)
	local back = key(Enum.KeyCode.S) + key(Enum.KeyCode.Down)
	local right = key(Enum.KeyCode.D)
	local left = key(Enum.KeyCode.A)

	local forwardmove = cl_forwardspeed * math.min(fwd, 1) - cl_backspeed * math.min(back, 1)
	local sidemove = cl_sidespeed * math.min(right, 1) - cl_sidespeed * math.min(left, 1)
	local upmove = cl_upspeed * (key(Enum.KeyCode.E) - key(Enum.KeyCode.C))

	-- +speed
	if keysDown[Enum.KeyCode.LeftShift] then
		forwardmove *= cl_movespeedkey
		sidemove *= cl_movespeedkey
		upmove *= cl_movespeedkey
	end

	local state: InputState = {
		forwardmove = forwardmove,
		sidemove = sidemove,
		upmove = upmove,
		attack = attackDown or attackImpulse,
		jump = keysDown[Enum.KeyCode.Space] == true or jumpImpulse,
		impulse = pendingImpulse,
	}
	attackImpulse = false
	jumpImpulse = false
	pendingImpulse = 0
	return state
end

return input
