--!strict
--!optimize 2
-- Roblox avatars mode (product layer, NOT engine): player entities
-- render as the player's own Roblox avatar rig instead of player.mdl.
-- The server publishes one neutralized R15 rig per connected player
-- under ReplicatedStorage.QuakeAvatars/<userId>; this module clones it,
-- anchors the root, drives position/yaw from the Quake entity, and
-- plays idle/run animation tracks by measured speed. Everything here is
-- client-local visuals — the Quake simulation still owns physics, and
-- the engine's alias renderer remains the fallback (rig loading, death
-- frames, toggle off).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local avatarrender = {}

-- standard R15 animation pack fallbacks (rig attributes override with
-- the player's own equipped animation pack)
local DEFAULT_IDLE = 507766666
local DEFAULT_RUN = 507767714
-- standard R15 tool-hold: raises the right forearm so the attached
-- weapon reads as carried (same track the stock Animate script plays)
local TOOL_HOLD = 507768375

-- Quake player origin is mid-body: mins z = -24, so feet are 24 units
-- (2.4 studs) below the entity origin
local FEET_BELOW_ORIGIN = 24 * qcoords.SCALE

export type AvatarEnt = {
	userId: number,
	model: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,
	idleTrack: AnimationTrack?,
	runTrack: AnimationTrack?,
	toolTrack: AnimationTrack?,
	loading: boolean,
	visible: boolean,
	lastOrigin: vector?,
	lastMoveTime: number,
	speed: number,
}

function avatarrender.create(userId: number, parent: Instance): AvatarEnt
	local ae: AvatarEnt = {
		userId = userId,
		model = nil,
		humanoid = nil,
		rootPart = nil,
		idleTrack = nil,
		runTrack = nil,
		toolTrack = nil,
		loading = true,
		visible = false,
		lastOrigin = nil,
		lastMoveTime = 0,
		speed = 0,
	}
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("QuakeAvatars", 15)
		local rigTemplate = if folder then folder:WaitForChild(tostring(userId), 20) else nil
		if not rigTemplate or not rigTemplate:IsA("Model") then
			ae.loading = false -- rig unavailable: alias fallback stays
			return
		end
		local rig = rigTemplate:Clone()
		rig.Name = `avatar_{userId}`
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local root = rig:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then
			ae.loading = false
			return
		end
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.EvaluateStateMachine = false
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
		rig:PivotTo(CFrame.new(0, -100000, 0))
		rig.Parent = parent

		local function loadTrack(attr: string, fallback: number): AnimationTrack?
			local id = rigTemplate:GetAttribute(attr)
			local n = if typeof(id) == "number" and id ~= 0 then id else fallback
			local anim = Instance.new("Animation")
			anim.AnimationId = `rbxassetid://{n}`
			local ok, track = pcall(function()
				return animator:LoadAnimationTrack(anim)
			end)
			return if ok then track else nil
		end
		ae.idleTrack = loadTrack("IdleAnim", DEFAULT_IDLE)
		ae.runTrack = loadTrack("RunAnim", DEFAULT_RUN)
		ae.toolTrack = loadTrack("ToolHoldAnim", TOOL_HOLD)
		ae.model = rig
		ae.humanoid = humanoid
		ae.rootPart = root
		ae.loading = false
	end)
	return ae
end

function avatarrender.ready(ae: AvatarEnt): boolean
	return ae.model ~= nil
end

-- position + yaw from the Quake entity; anim by measured speed
function avatarrender.update(ae: AvatarEnt, origin: vector, angles: vector, time: number)
	local model = ae.model
	local root = ae.rootPart
	local humanoid = ae.humanoid
	if not model or not root or not humanoid then
		return
	end
	-- measured speed (NQ does not replicate velocity)
	local last = ae.lastOrigin
	if last and time > ae.lastMoveTime then
		local dt = time - ae.lastMoveTime
		if dt < 0.5 then
			local d = origin - last
			local horiz = math.sqrt(d.x * d.x + d.y * d.y)
			ae.speed = ae.speed * 0.6 + (horiz / dt) * 0.4
		end
	end
	ae.lastOrigin = origin
	ae.lastMoveTime = time

	local feet = qcoords.toRoblox(origin) - Vector3.new(0, FEET_BELOW_ORIGIN, 0)
	local rootY = feet.Y + humanoid.HipHeight + root.Size.Y / 2
	-- quake yaw: 0 = +x; roblox -Z forward
	local yaw = math.rad(angles.y)
	model:PivotTo(CFrame.new(feet.X, rootY, feet.Z) * CFrame.Angles(0, yaw - math.pi / 2, 0))

	local running = ae.speed > 40 -- quake units/s
	local runTrack, idleTrack = ae.runTrack, ae.idleTrack
	if runTrack then
		if running and not runTrack.IsPlaying then
			runTrack:Play(0.15)
		elseif not running and runTrack.IsPlaying then
			runTrack:Stop(0.15)
		end
	end
	if idleTrack then
		if not running and not idleTrack.IsPlaying then
			idleTrack:Play(0.15)
		elseif running and idleTrack.IsPlaying then
			idleTrack:Stop(0.15)
		end
	end
	local toolTrack = ae.toolTrack
	if toolTrack and not toolTrack.IsPlaying then
		toolTrack:Play(0.15) -- right forearm raised: weapon reads as held
	end
end

-- world CFrame of the right hand (weapon attach point); nil until loaded
function avatarrender.rightHandCFrame(ae: AvatarEnt): CFrame?
	local model = ae.model
	if not model then
		return nil
	end
	local hand = model:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		return hand.CFrame
	end
	return nil
end

function avatarrender.setVisible(ae: AvatarEnt, on: boolean)
	if ae.visible == on then
		return
	end
	ae.visible = on
	local model = ae.model
	if model and not on then
		model:PivotTo(CFrame.new(0, -100000, 0))
		if ae.runTrack and ae.runTrack.IsPlaying then
			ae.runTrack:Stop(0)
		end
		if ae.idleTrack and ae.idleTrack.IsPlaying then
			ae.idleTrack:Stop(0)
		end
		if ae.toolTrack and ae.toolTrack.IsPlaying then
			ae.toolTrack:Stop(0)
		end
		ae.speed = 0
		ae.lastOrigin = nil
	end
end

function avatarrender.destroy(ae: AvatarEnt)
	if ae.model then
		ae.model:Destroy()
		ae.model = nil
	end
	ae.humanoid = nil
	ae.rootPart = nil
	ae.idleTrack = nil
	ae.runTrack = nil
end

return avatarrender
