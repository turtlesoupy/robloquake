--!strict
--!optimize 2
-- Roblox avatars mode (product layer, NOT engine): player entities
-- render as the player's own Roblox avatar rig instead of player.mdl.
-- The server publishes one neutralized R15 rig per connected player
-- under ReplicatedStorage.QuakeAvatars/<userId>; this module clones it,
-- anchors the root, drives position/yaw from the Quake entity, and
-- plays animation tracks from a measured-motion state machine (idle/
-- run/jump/fall/swim), a scripted tip-over death, and a pain flash.
-- Everything here is client-local visuals — the Quake simulation still
-- owns physics, and the engine's alias renderer remains the fallback
-- (rig loading, toggle off).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local avatarrender = {}

-- standard R15 animation pack fallbacks (rig attributes override with
-- the player's own equipped animation pack; SwimIdle has no
-- HumanoidDescription property, so it is always the stock track)
local DEFAULT_IDLE = 507766666
local DEFAULT_RUN = 507767714
local DEFAULT_JUMP = 507765000
local DEFAULT_FALL = 507767968
local DEFAULT_SWIM = 507784897
local DEFAULT_SWIM_IDLE = 507785072
-- standard R15 tool-hold: raises the right forearm so the attached
-- weapon reads as carried (same track the stock Animate script plays)
local TOOL_HOLD = 507768375

-- Quake player origin is mid-body: mins z = -24, so feet are 24 units
-- (3 studs at SCALE 1/8) below the entity origin
local FEET_BELOW_ORIGIN = 24 * qcoords.SCALE

-- rigs are normalized to the 56qu player height: the hitbox is the same
-- for everyone, so short/tall avatar body scales must not misrepresent
-- it. The server publishes rigs at NATIVE avatar scale (an external
-- ScaleTo there races the humanoid's async description re-application,
-- with no solver in ReplicatedStorage to reconcile — that detached
-- hair/hats); the one ScaleTo happens HERE on the clone, in workspace,
-- where the solver keeps joints and accessories coherent through it.
local QUAKE_PLAYER_HEIGHT = 56 * qcoords.SCALE

-- movement thresholds, quake units/s (measured, smoothed)
local RUN_SPEED = 40
local JUMP_VSPEED = 120 -- jump launch is +270
local FALL_VSPEED = -180 -- below stair-descent bumps
local TELEPORT_SPEED = 700 -- instantaneous spikes above this are teleports
local RUN_REFERENCE = 160 -- qu/s at which the run track plays at 1.0

local DEATH_FALL_TIME = 0.55 -- matches the ~6-frame quake death sequences
local PAIN_FLASH_TIME = 0.22

type MoveState = "idle" | "run" | "jump" | "fall" | "swim" | "swimidle"

type Region = "shirt" | "pants"
-- a clothing surface that renders OVER BasePart.Color and so takes the
-- quake team tint through its own (script-writable) color property,
-- with the original value saved for restore: classic clothing Color3,
-- SurfaceAppearance Color. Lightmap shading does NOT go through these —
-- it rides one Highlight fill per rig (see setLight), because most of
-- a dressed avatar's surfaces have no runtime-writable tint at all
-- (MeshPart TextureID ignores Part.Color; SurfaceAppearance ColorMap /
-- ColorMapContent are plugin-gated at runtime).
type TintTarget = { inst: Instance, prop: string, color0: Color3, region: Region }

-- accessory types that dress the shirt/pants regions (layered clothing);
-- hats/hair/faces are identity, not clothing, and are never tinted
local ACCESSORY_REGION: { [Enum.AccessoryType]: Region } = {
	[Enum.AccessoryType.TShirt] = "shirt",
	[Enum.AccessoryType.Shirt] = "shirt",
	[Enum.AccessoryType.Jacket] = "shirt",
	[Enum.AccessoryType.Sweater] = "shirt",
	[Enum.AccessoryType.Pants] = "pants",
	[Enum.AccessoryType.Shorts] = "pants",
	[Enum.AccessoryType.DressSkirt] = "pants",
	[Enum.AccessoryType.LeftShoe] = "pants",
	[Enum.AccessoryType.RightShoe] = "pants",
}

export type AvatarEnt = {
	userId: number,
	model: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,
	rightHand: BasePart?,
	tracks: { [MoveState]: AnimationTrack? },
	toolTrack: AnimationTrack?,
	loading: boolean,
	visible: boolean,
	lastOrigin: vector?,
	lastMoveTime: number,
	speed: number, -- smoothed horizontal qu/s
	vspeed: number, -- smoothed vertical qu/s (+up)
	moveDot: number, -- smoothed cos(move dir vs facing); < 0 = backpedal
	swimTilt: number, -- smoothed body pitch while swimming (radians)
	lastJumpPlay: number,
	dead: boolean,
	deathT0: number,
	painUntil: number,
	highlight: Highlight?,
	fadeAlpha: number?, -- mild mode corpse fade (0 visible .. 1 gone)
	shirtColor: Color3?,
	pantsColor: Color3?,
	baseColors: { [BasePart]: Color3 },
	partRegion: { [BasePart]: Region },
	tints: { TintTarget },
	lightFactor: number,
}

function avatarrender.create(userId: number, parent: Instance): AvatarEnt
	local ae: AvatarEnt = {
		userId = userId,
		model = nil,
		humanoid = nil,
		rootPart = nil,
		rightHand = nil,
		tracks = {},
		toolTrack = nil,
		loading = true,
		visible = false,
		lastOrigin = nil,
		lastMoveTime = 0,
		speed = 0,
		vspeed = 0,
		moveDot = 1,
		swimTilt = 0,
		lastJumpPlay = 0,
		dead = false,
		deathT0 = 0,
		painUntil = 0,
		highlight = nil,
		shirtColor = nil,
		pantsColor = nil,
		baseColors = {},
		partRegion = {},
		tints = {},
		lightFactor = 1,
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
		humanoid.AutomaticScalingEnabled = false -- our ScaleTo below is final
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
		rig:PivotTo(CFrame.new(0, -100000, 0))
		rig.Parent = parent

		-- normalize to the Quake player height (foot sole to head top),
		-- measured after the solver has seated the freshly cloned assembly
		local mhead = rig:FindFirstChild("Head")
		local mfoot = rig:FindFirstChild("LeftFoot") or rig:FindFirstChild("RightFoot")
		if mhead and mhead:IsA("BasePart") and mfoot and mfoot:IsA("BasePart") then
			local deadline = os.clock() + 3
			while os.clock() < deadline do
				task.wait()
				local h = (mhead.Position.Y + mhead.Size.Y / 2) - (mfoot.Position.Y - mfoot.Size.Y / 2)
				if h > 1 then
					rig:ScaleTo(rig:GetScale() * QUAKE_PLAYER_HEIGHT / h)
					break
				end
			end
		end

		local function loadTrack(attr: string, fallback: number): AnimationTrack?
			local id = rigTemplate:GetAttribute(attr)
			local n = if typeof(id) == "number" and id ~= 0 then id else fallback
			local anim = Instance.new("Animation")
			anim.AnimationId = `rbxassetid://{n}`
			local ok, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			return if ok then track else nil
		end
		ae.tracks = {
			idle = loadTrack("IdleAnim", DEFAULT_IDLE),
			run = loadTrack("RunAnim", DEFAULT_RUN),
			jump = loadTrack("JumpAnim", DEFAULT_JUMP),
			fall = loadTrack("FallAnim", DEFAULT_FALL),
			swim = loadTrack("SwimAnim", DEFAULT_SWIM),
			swimidle = loadTrack("SwimIdleAnim", DEFAULT_SWIM_IDLE),
		}
		ae.toolTrack = loadTrack("ToolHoldAnim", TOOL_HOLD)
		local hand = rig:FindFirstChild("RightHand")
		ae.rightHand = if hand and hand:IsA("BasePart") then hand else nil
		-- original part colors: setLight darkens by scaling these
		for _, d in rig:GetDescendants() do
			if d:IsA("BasePart") and d ~= root then
				ae.baseColors[d] = d.Color
			end
		end
		-- quake shirt/pants tint targets. Body parts are direct children
		-- of the rig; regions mirror the alias translation ranges:
		-- shirt = torso + arms, pants = legs + feet
		for _, d in rig:GetChildren() do
			if d:IsA("BasePart") and d ~= root then
				local n = d.Name
				if string.find(n, "Leg") or string.find(n, "Foot") then
					ae.partRegion[d] = "pants"
				elseif string.find(n, "Torso") or string.find(n, "Arm") or string.find(n, "Hand") then
					ae.partRegion[d] = "shirt"
				end
			end
		end
		-- clothing accessory parts tint with their region too (a jacket
		-- over a red shirt reads red); hats/hair keep their own colors
		for _, a in rig:GetChildren() do
			if a:IsA("Accessory") then
				local region = ACCESSORY_REGION[a.AccessoryType]
				if region then
					for _, p in a:GetDescendants() do
						if p:IsA("BasePart") then
							ae.partRegion[p] = region
						end
					end
				end
			end
		end
		-- clothing wearables stay ON and take the team tint through their
		-- own color properties (Part.Color is invisible under them):
		-- classic clothing multiplies Color3 into its texture,
		-- SurfaceAppearance multiplies Color into its ColorMap (layered
		-- clothing). Only region-mapped surfaces are collected — lightmap
		-- shading is the Highlight fill, not a per-surface tint.
		for _, d in rig:GetDescendants() do
			if d:IsA("Shirt") or d:IsA("ShirtGraphic") then
				table.insert(ae.tints, { inst = d, prop = "Color3", color0 = d.Color3, region = "shirt" :: Region })
			elseif d:IsA("Pants") then
				table.insert(ae.tints, { inst = d, prop = "Color3", color0 = d.Color3, region = "pants" :: Region })
			elseif d:IsA("SurfaceAppearance") then
				local p = d.Parent
				local region = if p and p:IsA("BasePart") then ae.partRegion[p] else nil
				if region then
					table.insert(ae.tints, { inst = d, prop = "Color", color0 = d.Color, region = region })
				end
			end
		end
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

-- brief red flash on the rig: quake's pain frames have no Roblox
-- animation counterpart, so hit feedback is a decaying highlight
function avatarrender.flashPain(ae: AvatarEnt, time: number)
	ae.painUntil = time + PAIN_FLASH_TIME
end

-- persistent re-skin in the player's Quake shirt/pants colors (the
-- identity/teamplay signal the alias skin translation carries); nil
-- clears a region back to the avatar's real look. Body parts are
-- painted directly; clothing wearables take the tint through their
-- color properties. Lightmap darkness composes on top via the
-- Highlight fill, so no light scaling happens here.
function avatarrender.setTeamColors(ae: AvatarEnt, shirt: Color3?, pants: Color3?)
	if ae.shirtColor == shirt and ae.pantsColor == pants then
		return
	end
	ae.shirtColor = shirt
	ae.pantsColor = pants
	for part, c0 in ae.baseColors do
		local region = ae.partRegion[part]
		part.Color = if region == "shirt" then shirt or c0 elseif region == "pants" then pants or c0 else c0
	end
	for _, t in ae.tints do
		local c = if t.region == "shirt" then shirt or t.color0 else pants or t.color0
		local inst = t.inst :: any
		inst[t.prop] = c
	end
end

-- R_AliasSetupLighting for rigs: same lightmap-sample scalar the alias
-- renderer gets (entrender.setLight math). A dressed avatar has no
-- runtime-writable per-surface tint that covers everything (MeshPart
-- textures ignore Part.Color; SurfaceAppearance ColorMap is
-- plugin-gated), so the darkness rides the rig's Highlight fill:
-- FillColor black at FillTransparency l renders exactly original * l
-- on every surface — skin, clothing, hair, faces. Applied in update()
-- (shared with the pain flash); this just stores the factor.
function avatarrender.setLight(ae: AvatarEnt, light: number)
	local l = math.min((light + 8) * 2, 255) / 255 -- +8 ambient floor
	l = l ^ 0.7 -- match the world lighting gamma
	ae.lightFactor = l
end

local function stopAllTracks(ae: AvatarEnt, fade: number)
	for _, track in ae.tracks do
		if track.IsPlaying then
			track:Stop(fade)
		end
	end
	if ae.toolTrack and ae.toolTrack.IsPlaying then
		ae.toolTrack:Stop(fade)
	end
end

-- position + yaw from the Quake entity; animation state from motion.
-- dead: entity frame is in player.mdl's death/corpse band — scripted
-- tip-over, held as the corpse pose. swimming: entity origin (mid-body)
-- is in water contents. velocity (optional, qu/s): the replicated
-- velocity when the protocol carries it (QW playerstate); when absent
-- (NQ), motion is measured from interpolated origin deltas.
function avatarrender.update(
	ae: AvatarEnt,
	origin: vector,
	angles: vector,
	time: number,
	dead: boolean?,
	swimming: boolean?,
	velocity: vector?
)
	local model = ae.model
	local root = ae.rootPart
	local humanoid = ae.humanoid
	if not model or not root or not humanoid then
		return
	end

	-- death state transitions. A corpse first seen already dead (bodyque
	-- corpses left behind after respawn, corpses entering the PVS) lies
	-- down instantly instead of replaying the fall.
	if dead and not ae.dead then
		ae.dead = true
		ae.deathT0 = if ae.lastOrigin == nil then time - DEATH_FALL_TIME else time
		ae.swimTilt = 0
		ae.painUntil = 0
		stopAllTracks(ae, 0.1)
	elseif not dead and ae.dead then
		ae.dead = false -- respawned
		ae.speed = 0
		ae.vspeed = 0
		ae.lastOrigin = nil
	end

	if not ae.dead then
		if velocity then
			-- replicated velocity (QW): tick-rate origins make per-frame
			-- deltas useless (a whole tick's move in one frame reads as a
			-- teleport, the rest read as standing still), so use the wire
			-- velocity directly with light smoothing
			local horiz = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
			ae.speed = ae.speed * 0.5 + horiz * 0.5
			ae.vspeed = ae.vspeed * 0.5 + velocity.z * 0.5
			if horiz > 0.1 then
				local yawr = math.rad(angles.y)
				local fdot = (velocity.x * math.cos(yawr) + velocity.y * math.sin(yawr)) / horiz
				ae.moveDot = ae.moveDot * 0.6 + fdot * 0.4
			end
		else
			-- measured motion: NQ interpolates entity origins every frame
			-- (CL_RelinkEntities), so smoothed origin deltas track speed
			local last = ae.lastOrigin
			if last and time > ae.lastMoveTime then
				local dt = time - ae.lastMoveTime
				if dt < 0.5 then
					local d = origin - last
					local horiz = math.sqrt(d.x * d.x + d.y * d.y)
					local hs = horiz / dt
					if hs < TELEPORT_SPEED then
						ae.speed = ae.speed * 0.6 + hs * 0.4
						ae.vspeed = ae.vspeed * 0.6 + (d.z / dt) * 0.4
						if horiz > 0.1 then
							local yawr = math.rad(angles.y)
							local fdot = (d.x * math.cos(yawr) + d.y * math.sin(yawr)) / horiz
							ae.moveDot = ae.moveDot * 0.6 + fdot * 0.4
						end
					end
					-- teleport spike: keep the previous smoothed motion
				end
			end
		end
	end
	ae.lastOrigin = origin
	ae.lastMoveTime = time

	-- pose
	local feet = qcoords.toRoblox(origin) - Vector3.new(0, FEET_BELOW_ORIGIN, 0)
	local rootOffset = humanoid.HipHeight + root.Size.Y / 2
	-- quake yaw: 0 = +x; roblox -Z forward
	local yaw = math.rad(angles.y)
	local base = CFrame.new(feet) * CFrame.Angles(0, yaw - math.pi / 2, 0)
	if ae.dead then
		-- tip over backward about the feet, accelerating like a fall, and
		-- hold the lying pose as the corpse until the frame leaves the band
		local k = math.clamp((time - ae.deathT0) / DEATH_FALL_TIME, 0, 1)
		local ease = k * k
		local tilt = ease * math.rad(84)
		local lift = 0.45 * ease -- half body thickness: rest on the floor, not in it
		model:PivotTo((base * CFrame.Angles(tilt, 0, 0) * CFrame.new(0, rootOffset, 0)) + Vector3.new(0, lift, 0))
	else
		-- swimming: pitch the body toward the travel direction (Roblox
		-- swim tracks assume physics tilts the character; ours is anchored)
		local tiltTarget = 0
		if swimming and (ae.speed > RUN_SPEED or math.abs(ae.vspeed) > RUN_SPEED) then
			tiltTarget = math.clamp(math.atan2(ae.speed, ae.vspeed), 0, math.rad(110))
		end
		ae.swimTilt += (tiltTarget - ae.swimTilt) * 0.2
		model:PivotTo(base * CFrame.new(0, rootOffset, 0) * CFrame.Angles(-ae.swimTilt, 0, 0))
	end

	-- animation state machine
	if not ae.dead then
		local state: MoveState
		if swimming then
			state = if ae.speed > RUN_SPEED or math.abs(ae.vspeed) > RUN_SPEED then "swim" else "swimidle"
		elseif ae.vspeed > JUMP_VSPEED then
			state = "jump"
		elseif ae.vspeed < FALL_VSPEED then
			state = "fall"
		elseif ae.speed > RUN_SPEED then
			state = "run"
		else
			state = "idle"
		end
		local desired = ae.tracks[state]
		for _, track in ae.tracks do
			if track ~= desired and track.IsPlaying then
				track:Stop(0.15)
			end
		end
		if desired and not desired.IsPlaying then
			if state == "jump" then
				-- one-shot; don't restart it every frame after it finishes
				if time - ae.lastJumpPlay > 0.5 then
					ae.lastJumpPlay = time
					desired:Play(0.1)
				end
			else
				desired:Play(0.15)
			end
		end
		if state == "run" and desired then
			-- scale foot speed to measured speed; reversed for backpedal
			local rate = math.clamp(ae.speed / RUN_REFERENCE, 0.55, 1.7)
			if ae.moveDot < -0.25 then
				rate = -rate * 0.85
			end
			desired:AdjustSpeed(rate)
		end
		local toolTrack = ae.toolTrack
		if toolTrack and not toolTrack.IsPlaying then
			toolTrack:Play(0.15) -- right forearm raised: weapon reads as held
		end
	end

	-- one Highlight per rig (Roblox caps enabled highlights at 31),
	-- doing double duty: the pain flash (red fill) and the lightmap
	-- darkness (black fill at FillTransparency = light factor, which
	-- renders original * l on every surface — see setLight)
	local flashing = ae.painUntil > time and not ae.dead
	local dark = ae.lightFactor < 0.98
	local highlight = ae.highlight
	if flashing or dark then
		if not highlight then
			highlight = Instance.new("Highlight")
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.OutlineTransparency = 1
			highlight.Enabled = false
			highlight.Parent = model
			ae.highlight = highlight
		end
		if flashing then
			highlight.FillColor = Color3.fromRGB(210, 25, 25)
			highlight.FillTransparency = 0.35 + 0.65 * (1 - (ae.painUntil - time) / PAIN_FLASH_TIME)
		else
			highlight.FillColor = Color3.new(0, 0, 0)
			highlight.FillTransparency = ae.lightFactor
		end
		highlight.Enabled = true
	elseif highlight and highlight.Enabled then
		highlight.Enabled = false
	end
end

-- mild mode corpse fade: LocalTransparencyModifier on every part. The
-- rig's Highlight ignores part transparency (it would keep drawing a
-- solid silhouette), so it stays forced off while any fade is active —
-- update() re-enables it each frame, so this runs after update().
function avatarrender.setFade(ae: AvatarEnt, alpha: number)
	local model = ae.model
	if not model then
		return
	end
	if alpha > 0 and ae.highlight then
		(ae.highlight :: Highlight).Enabled = false
	end
	if ae.fadeAlpha == alpha or (alpha <= 0 and ae.fadeAlpha == nil) then
		return
	end
	ae.fadeAlpha = if alpha > 0 then alpha else nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = alpha
		end
	end
end

-- world CFrame of the right hand (weapon attach point); nil until loaded
function avatarrender.rightHandCFrame(ae: AvatarEnt): CFrame?
	local hand = ae.rightHand
	return if hand then hand.CFrame else nil
end

function avatarrender.setVisible(ae: AvatarEnt, on: boolean)
	if ae.visible == on then
		return
	end
	ae.visible = on
	local model = ae.model
	if model and not on then
		if workspace:GetAttribute("RQDBG_AvParkTrace") then
			print("[avpark]", model.Name, debug.traceback("", 2))
		end
		model:PivotTo(CFrame.new(0, -100000, 0))
		stopAllTracks(ae, 0)
		ae.speed = 0
		ae.vspeed = 0
		ae.moveDot = 1
		ae.swimTilt = 0
		ae.lastOrigin = nil
		ae.dead = false
		ae.painUntil = 0
		if ae.highlight then
			ae.highlight.Enabled = false
		end
	end
end

function avatarrender.destroy(ae: AvatarEnt)
	if ae.model then
		ae.model:Destroy()
		ae.model = nil
	end
	ae.humanoid = nil
	ae.rootPart = nil
	ae.rightHand = nil
	ae.tracks = {}
	ae.toolTrack = nil
	ae.highlight = nil
	ae.baseColors = {}
	ae.partRegion = {}
	ae.tints = {}
end

return avatarrender
