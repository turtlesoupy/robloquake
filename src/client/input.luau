--!strict
-- Input: the cl_input.c button model. Keys map to +commands via binds
-- (init.client's Key_Event); this module holds button states, view angles,
-- and builds usercmds (CL_BaseMove / CL_AdjustAngles).

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

-- cl_* cvars (defaults)
local cl_forwardspeed = 200
local cl_backspeed = 200
local cl_sidespeed = 350
local cl_upspeed = 200
local cl_movespeedkey = 2
local cl_yawspeed = 140
local cl_pitchspeed = 150
local cl_anglespeedkey = 1.5
local m_yaw = 0.022
local m_pitch = 0.022
local sensitivity = 3

-- kbutton_t states (down or not; edge latches for attack/jump)
local buttons: { [string]: boolean } = {}
local attackImpulse = false -- in_attack.state & 2
local jumpImpulse = false
local pendingImpulse = 0

local yaw = 0
local pitch = 0
local enabled = true

-- analog move overlay (touch thumbstick / gamepad left stick), -1..1;
-- fed by src/client/controls.luau, added into CL_BaseMove's sums
local analogForward = 0
local analogSide = 0

local function btn(name: string): number
	return if buttons[name] then 1 else 0
end

-- KeyDown/KeyUp for the +commands (in_forward, in_attack, ...)
function input.setButton(name: string, down: boolean)
	if down and not buttons[name] then
		if name == "attack" then
			attackImpulse = true
		elseif name == "jump" then
			jumpImpulse = true
		end
	end
	buttons[name] = down
end

function input.init(startYaw: number)
	yaw = startYaw
	pitch = 0

	UserInputService.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseMovement and enabled then
			-- IN_MouseMove (always-mouselook)
			yaw -= io.Delta.X * m_yaw * sensitivity
			pitch += io.Delta.Y * m_pitch * sensitivity
			pitch = math.clamp(pitch, -70, 80)
		end
	end)

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
end

-- CL_AdjustAngles: keyboard turning/looking, run once per frame
function input.updateTurn(dt: number)
	if not enabled then
		return
	end
	local speed = dt * (if buttons.speed then cl_anglespeedkey else 1)
	if not buttons.strafe then
		yaw -= speed * cl_yawspeed * btn("right")
		yaw += speed * cl_yawspeed * btn("left")
	end
	if buttons.klook then
		pitch -= speed * cl_pitchspeed * btn("forward")
		pitch += speed * cl_pitchspeed * btn("back")
	end
	pitch -= speed * cl_pitchspeed * btn("lookup")
	pitch += speed * cl_pitchspeed * btn("lookdown")
	pitch = math.clamp(pitch, -70, 80)
end

-- IN_MouseMove's `(in_mlook.state & 1) && !(in_strafe.state & 1)` gate:
-- this port is always-mouselook, so mlook is "held" whenever input owns
-- the mouse. C calls V_StopPitchDrift every frame this is true (even
-- with zero mouse delta), which is what keeps V_DriftPitch from ever
-- arming under mouselook — the drift-to-center is keyboard-look behavior.
function input.mlookActive(): boolean
	return enabled and not buttons.strafe
end

function input.centerview()
	pitch = 0
end

-- analog stick move (controls.luau): full deflection = run speed
function input.setAnalogMove(forward: number, side: number)
	analogForward = math.clamp(forward, -1, 1)
	analogSide = math.clamp(side, -1, 1)
end

-- view delta in degrees (touch drag / gamepad right stick); same
-- convention as IN_MouseMove: positive dyaw turns left, positive
-- dpitch looks down
function input.applyLook(dyaw: number, dpitch: number)
	if not enabled then
		return
	end
	yaw += dyaw
	pitch = math.clamp(pitch + dpitch, -70, 80)
end

function input.lockMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
end

-- release the cursor for clickable product UI (admin menu)
function input.freeMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

-- returns viewangles (quake pitch/yaw/roll degrees)
function input.viewangles(): vector
	return vector.create(pitch, yaw, 0)
end

-- console/menu take over the keyboard and mouse
function input.setEnabled(on: boolean)
	enabled = on
	if on then
		input.lockMouse()
	else
		-- Key_ClearStates: analog sticks clear like held keys do
		table.clear(buttons)
		analogForward = 0
		analogSide = 0
	end
end

-- console "impulse N"
function input.setImpulse(n: number)
	pendingImpulse = n
end

function input.setSensitivity(v: number)
	sensitivity = v
end

function input.setAngles(angles: vector)
	pitch = angles.x
	yaw = angles.y
end

-- scripted-test hooks (verification harness drives the real input path).
-- Cached via AttributeChanged so the 60-77Hz sample path doesn't pay 5
-- reflected GetAttribute reads per call; the harness only ever sets these
-- through SetAttribute, which fires the signal before the next Heartbeat.
local FORCE_ATTRS = { "RQ_ForceForward", "RQ_ForceUp", "RQ_ForceYaw", "RQ_ForcePitch", "RQ_ForceAttack" }
local forceValues: { [string]: any } = {}
for _, name in FORCE_ATTRS do
	forceValues[name] = workspace:GetAttribute(name)
	workspace:GetAttributeChangedSignal(name):Connect(function()
		forceValues[name] = workspace:GetAttribute(name)
	end)
end

-- CL_BaseMove
function input.sample(): InputState
	if not enabled then
		local imp = pendingImpulse
		pendingImpulse = 0
		return { forwardmove = 0, sidemove = 0, upmove = 0, attack = false, jump = false, impulse = imp }
	end
	local forceForward = forceValues.RQ_ForceForward
	local forceUp = forceValues.RQ_ForceUp
	local forceYaw = forceValues.RQ_ForceYaw
	local forcePitch = forceValues.RQ_ForcePitch
	local forceAttack = forceValues.RQ_ForceAttack
	if forceYaw then
		yaw = forceYaw
	end
	if forcePitch then
		pitch = forcePitch
	end
	if forceForward or forceAttack or forceUp then
		return {
			forwardmove = forceForward or 0,
			sidemove = 0,
			upmove = forceUp or 0,
			attack = forceAttack == true,
			jump = false,
			impulse = 0,
		}
	end

	local sidemove = 0
	if buttons.strafe then
		sidemove += cl_sidespeed * btn("right")
		sidemove -= cl_sidespeed * btn("left")
	end
	sidemove += cl_sidespeed * btn("moveright")
	sidemove -= cl_sidespeed * btn("moveleft")

	local upmove = cl_upspeed * (btn("moveup") - btn("movedown"))

	local forwardmove = 0
	if not buttons.klook then
		forwardmove += cl_forwardspeed * btn("forward")
		forwardmove -= cl_backspeed * btn("back")
	end

	-- +speed
	if buttons.speed then
		forwardmove *= cl_movespeedkey
		sidemove *= cl_movespeedkey
		upmove *= cl_movespeedkey
	end

	-- analog sticks: full deflection = run speed (the server's
	-- sv_maxspeed clamp evens out the fwd/side asymmetry), partial
	-- deflection walks — the precision keyboards get from +speed
	forwardmove += cl_forwardspeed * cl_movespeedkey * analogForward
	sidemove += cl_sidespeed * cl_movespeedkey * analogSide

	local state: InputState = {
		forwardmove = forwardmove,
		sidemove = sidemove,
		upmove = upmove,
		attack = buttons.attack == true or attackImpulse,
		jump = buttons.jump == true or jumpImpulse,
		impulse = pendingImpulse,
	}
	attackImpulse = false
	jumpImpulse = false
	pendingImpulse = 0
	return state
end

return input
