--!strict
--!optimize 2
-- Avatar HUD face (product layer, NOT engine): the sbar face slot shows
-- the LOCAL player's avatar head in a ViewportFrame instead of the
-- gfx.wad face bitmaps, restyled toward the originals — warm dim
-- lighting, a banded health tint that reddens/darkens as health drops
-- (Sbar_DrawFace's 5 bands), a red pain flash + camera-roll jolt while
-- cl.faceanimtime is in the future, and a tip-over roll on death.
-- Powerup faces (quad/pent/ring) keep their bitmaps — hud.luau only
-- routes the health-band branch here. The rig source is the same
-- server-published QuakeAvatars template avatarrender clones; when it
-- is missing the widget never reports ready and the bitmaps remain.

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local avatarface = {}

local PAIN_FLASH_TIME = 0.2 -- cl.faceanimtime window (cl.luau sets +0.2)
local DEATH_ROLL_TIME = 0.5 -- camera tip-over on death
local CAMERA_FOV = 40

-- Sbar_DrawFace's banded look, as viewport tints: band 4 (80+) down to
-- band 0 (<20) progressively redder and darker, plus a dead color. The
-- bands snap like the bitmaps do — no per-point lerp.
local BAND_TINT = {
	[4] = Color3.fromRGB(255, 244, 232),
	[3] = Color3.fromRGB(252, 220, 198),
	[2] = Color3.fromRGB(250, 186, 160),
	[1] = Color3.fromRGB(236, 142, 118),
	[0] = Color3.fromRGB(216, 106, 88),
}
local DEAD_TINT = Color3.fromRGB(122, 72, 62)

--------------------------------------------------------------------------
-- Expression overlay: the Quake guy's "expression" is baked pixel art
-- (gritted teeth, blood accumulating per band), and classic decal faces
-- have no runtime morphs — so the expression is a 24x24 palettized-style
-- sprite composited over the head, drawn in code into one EditableImage
-- (created once, rewritten in place) and upscaled Pixelated like every
-- gfx.wad pic. The camera framing is deterministic (face fills the slot
-- brow-to-chin), so eye/mouth positions are fixed grid coordinates.

local OV = 24 -- overlay grid == the sbar face slot's native pixels

-- quake-red blood ramp + feature inks
local BLOOD_DARK = { 111, 7, 7 }
local BLOOD_BRIGHT = { 167, 27, 27 }
local INK = { 37, 23, 13 } -- brows / X-eyes
local TEETH = { 219, 199, 171 }
local TEETH_EDGE = { 51, 31, 19 }

type Px = { number } -- {x, y, r, g, b}
local function mark(list: { Px }, x: number, y: number, c: { number })
	table.insert(list, { x, y, c[1], c[2], c[3] })
end
local function streak(list: { Px }, x: number, y0: number, y1: number, c: { number })
	for y = y0, y1 do
		mark(list, x, y, c)
	end
end

-- blood accumulates as the band drops: BLOOD[1] shows from band 3,
-- BLOOD[4] from band 0 (each stage draws on top of the earlier ones,
-- mirroring the progressively-bloodier sb_faces)
local BLOOD: { { Px } } = { {}, {}, {}, {} }
-- band 3: a nick at the right temple
streak(BLOOD[1], 17, 1, 4, BLOOD_DARK)
mark(BLOOD[1], 17, 5, BLOOD_BRIGHT)
-- band 2: cut over the left brow, dripping
mark(BLOOD[2], 5, 4, BLOOD_BRIGHT)
mark(BLOOD[2], 6, 4, BLOOD_BRIGHT)
mark(BLOOD[2], 7, 4, BLOOD_DARK)
streak(BLOOD[2], 6, 5, 7, BLOOD_DARK)
-- band 1: forehead gash with a run down the nose line
for x = 10, 14 do
	mark(BLOOD[3], x, 1, BLOOD_BRIGHT)
	mark(BLOOD[3], x, 2, BLOOD_DARK)
end
streak(BLOOD[3], 12, 3, 7, BLOOD_DARK)
-- band 0: running down both cheeks + out the mouth corner
streak(BLOOD[4], 4, 8, 15, BLOOD_DARK)
streak(BLOOD[4], 18, 7, 14, BLOOD_DARK)
streak(BLOOD[4], 5, 12, 15, BLOOD_BRIGHT)
streak(BLOOD[4], 7, 18, 20, BLOOD_BRIGHT)
mark(BLOOD[4], 8, 19, BLOOD_DARK)

-- pain grimace: angry brows + a bar of gritted teeth over the mouth
local GRIT: { Px } = {}
for _, b in { { 5, 5 }, { 6, 5 }, { 7, 6 }, { 8, 6 }, { 9, 7 } } do
	mark(GRIT, b[1], b[2], INK)
	mark(GRIT, OV - 1 - b[1], b[2], INK) -- mirrored right brow
end
for x = 8, 15 do
	mark(GRIT, x, 16, TEETH_EDGE)
	mark(GRIT, x, 18, TEETH_EDGE)
	mark(GRIT, x, 17, if x == 10 or x == 13 then TEETH_EDGE else TEETH)
end

-- death: X-eyes (the Roblox-native way to say what the bitmaps say
-- with closed bloody lids)
local XEYES: { Px } = {}
for _, cx in { 8, 15 } do
	for d = -2, 2 do
		mark(XEYES, cx + d, 9 + d, INK)
		mark(XEYES, cx + d, 9 - d, INK)
	end
end

local function blit(buf: buffer, list: { Px })
	for _, p in list do
		local o = (p[2] * OV + p[1]) * 4
		buffer.writeu8(buf, o, p[3])
		buffer.writeu8(buf, o + 1, p[4])
		buffer.writeu8(buf, o + 2, p[5])
		buffer.writeu8(buf, o + 3, 255)
	end
end

export type Face = {
	frame: Frame,
	viewport: ViewportFrame,
	flash: Frame,
	camera: Camera,
	baseCF: CFrame?, -- head-framing camera CFrame; nil until the rig loads
	model: Model?,
	dead: boolean,
	deathT0: number,
	painSign: number, -- jolt side, flipped per pain window
	lastPainT: number,
	lastTint: Color3?,
	-- expression overlay (blood/grit/X-eyes pixel sprite)
	overlay: ImageLabel,
	overlayImg: EditableImage?, -- nil = budget denied it; overlay stays hidden
	overlayBuf: buffer,
	overlayKey: string?, -- last composed "band:grit:dead" state
}

function avatarface.create(parent: Instance, x: number, y: number, size: number): Face
	local frame = Instance.new("Frame")
	frame.Name = "avatarface"
	frame.BackgroundTransparency = 1
	frame.ClipsDescendants = true
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(size, size)
	frame.Visible = false
	frame.Parent = parent

	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.fromScale(1, 1)
	-- warm, dim, front-lit: the closest viewport lighting gets to the
	-- brown-lit gfx.wad faces
	viewport.Ambient = Color3.fromRGB(126, 108, 92)
	viewport.LightColor = Color3.fromRGB(255, 228, 192)
	viewport.LightDirection = Vector3.new(0.3, -0.6, 1)
	viewport.Parent = frame

	local camera = Instance.new("Camera")
	camera.FieldOfView = CAMERA_FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- expression sprite between the head and the pain flash
	local overlay = Instance.new("ImageLabel")
	overlay.Name = "expression"
	overlay.BackgroundTransparency = 1
	overlay.ResampleMode = Enum.ResamplerMode.Pixelated
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = viewport.ZIndex + 1
	overlay.Visible = false
	overlay.Parent = frame

	local flash = Instance.new("Frame")
	flash.Name = "painflash"
	flash.BackgroundColor3 = Color3.fromRGB(210, 25, 25)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = overlay.ZIndex + 1
	flash.Parent = frame

	local af: Face = {
		frame = frame,
		viewport = viewport,
		flash = flash,
		camera = camera,
		baseCF = nil,
		model = nil,
		dead = false,
		deathT0 = 0,
		painSign = 1,
		lastPainT = 0,
		lastTint = nil,
		overlay = overlay,
		overlayImg = nil,
		overlayBuf = buffer.create(OV * OV * 4),
		overlayKey = nil,
	}

	-- one tiny EditableImage, rewritten in place per state change (never
	-- churned); creation can fail under the device editable budget, in
	-- which case the face just renders without the expression sprite
	do
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(OV, OV) })
		end)
		if ok and img then
			af.overlayImg = img
			overlay.ImageContent = Content.fromObject(img)
		end
	end

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("QuakeAvatars", 15)
		local player = Players.LocalPlayer
		local template = if folder and player then folder:WaitForChild(tostring(player.UserId), 20) else nil
		if not template or not template:IsA("Model") then
			return -- no rig: never ready, hud keeps the bitmap faces
		end
		local model = template:Clone()
		model.Name = "hudface"
		-- static portrait: no animation, no state machine, and NO ScaleTo
		-- (the published template is native-scale; camera distance frames
		-- it, so the parked-rig scaling hazard never comes up)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.EvaluateStateMachine = false
			humanoid.AutomaticScalingEnabled = false
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end
		model:PivotTo(CFrame.identity)
		local head = model:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") then
			model:Destroy()
			return
		end
		model.Parent = af.viewport
		-- frame the head: rigs face -Z, so the camera sits in front on -Z
		-- looking back. Tight portrait like the gfx.wad faces (they fill
		-- the 24px slot brow-to-chin): ~1.25 head-heights of vertical
		-- field, aimed a touch low so hats crop at the top edge the way
		-- the bitmaps crop hair
		local target = head.Position - Vector3.new(0, head.Size.Y * 0.05, 0)
		local extent = math.max(head.Size.Y, head.Size.X)
		local dist = (extent * 1.25) / (2 * math.tan(math.rad(CAMERA_FOV / 2)))
		af.baseCF = CFrame.lookAt(target - Vector3.new(0, 0, dist), target)
		af.camera.CFrame = af.baseCF :: CFrame
		af.model = model
	end)
	return af
end

function avatarface.ready(af: Face): boolean
	return af.baseCF ~= nil
end

-- drive from Sbar_DrawFace inputs: health (band + death), faceanimtime
-- vs time (pain window). Idempotent per frame; cheap when nothing moves.
function avatarface.update(af: Face, health: number, faceanimtime: number, time: number)
	local baseCF = af.baseCF
	if not baseCF then
		return
	end

	local dead = health <= 0
	if dead and not af.dead then
		af.dead = true
		af.deathT0 = time
	elseif not dead and af.dead then
		af.dead = false
	end
	if af.deathT0 > time then
		af.deathT0 = time -- level restart rewound the clock
	end

	local roll = 0
	local tint: Color3
	local flashT = 1
	local band = math.clamp(math.floor(health / 20), 0, 4)
	local grit = false
	if af.dead then
		-- tip over: accelerate into an ~80 degree roll and hold the slump
		local k = math.clamp((time - af.deathT0) / DEATH_ROLL_TIME, 0, 1)
		roll = k * k * math.rad(80)
		tint = DEAD_TINT
		band = 0
	else
		local painT = math.clamp(faceanimtime - time, 0, PAIN_FLASH_TIME)
		if painT > af.lastPainT then
			af.painSign = -af.painSign -- new pain window: jolt the other way
		end
		af.lastPainT = painT
		tint = BAND_TINT[band]
		if painT > 0 then
			local k = painT / PAIN_FLASH_TIME -- 1 at the hit, decays to 0
			roll = af.painSign * k * math.rad(11)
			flashT = 0.45 + 0.55 * (1 - k)
			grit = true
		end
	end

	-- expression sprite: recompose the 24x24 only when the banded state
	-- changes (band blood is cumulative; grit rides the pain window;
	-- death swaps grit for X-eyes over full blood)
	local img = af.overlayImg
	if img then
		local key = `{band}:{grit}:{af.dead}`
		if key ~= af.overlayKey then
			af.overlayKey = key
			local buf = af.overlayBuf
			buffer.fill(buf, 0, 0)
			for stage = 1, 4 - band do
				blit(buf, BLOOD[stage])
			end
			if af.dead then
				blit(buf, XEYES)
			elseif grit then
				blit(buf, GRIT)
			end
			img:WritePixelsBuffer(Vector2.zero, img.Size, buf)
			af.overlay.Visible = band < 4 or grit or af.dead
		end
	end

	if af.lastTint ~= tint then
		af.lastTint = tint
		af.viewport.ImageColor3 = tint
	end
	af.flash.BackgroundTransparency = flashT
	af.camera.CFrame = if roll ~= 0 then baseCF * CFrame.Angles(0, 0, roll) else baseCF
	-- the sprite tracks the head through the camera roll (X-eyes must
	-- stay on the eyes through the death tip-over): rolling the camera
	-- +r about its look axis reads as the scene rotating +r clockwise
	-- on screen, matching GuiObject.Rotation's clockwise degrees
	-- (verified in-game: the negated form counter-rotated the X-eyes)
	af.overlay.Rotation = math.deg(roll)
end

function avatarface.setVisible(af: Face, on: boolean)
	if af.frame.Visible ~= on then
		af.frame.Visible = on
	end
end

return avatarface
