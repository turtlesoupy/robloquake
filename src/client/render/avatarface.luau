--!strict
--!optimize 2
-- Avatar HUD face (product layer, NOT engine): the sbar face slot shows
-- the LOCAL player's avatar headshot instead of the gfx.wad face
-- bitmaps, restyled toward the originals — a banded health tint that
-- reddens/darkens as health drops (Sbar_DrawFace's 5 bands), a red pain
-- flash + roll jolt while cl.faceanimtime is in the future, and a
-- tip-over roll on death. Powerup faces (quad/pent/ring) keep their
-- bitmaps — hud.luau only routes the health-band branch here.
--
-- The head is the official GetUserThumbnailAsync headshot, NOT a
-- ViewportFrame render of the QuakeAvatars rig: viewports run neither
-- the layered-clothing deformer nor SurfaceAppearance, so modern
-- avatars (layered hair, dynamic heads) rendered as a pale head with
-- the hair mesh floating beside it (playtest screenshot). The thumbnail
-- is Roblox's own render and gets every avatar right; if the fetch
-- never lands the widget never reports ready and the bitmaps remain.

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")

local avatarface = {}

local PAIN_FLASH_TIME = 0.2 -- cl.faceanimtime window (cl.luau sets +0.2)
local DEATH_ROLL_TIME = 0.5 -- tip-over on death
-- headshot thumbnails frame the head with generous margin; the gfx.wad
-- faces fill their 24px slot brow-to-chin, so the image zooms in a bit
-- (centered; the frame clips the spill)
local HEAD_ZOOM = 1.45

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
	image: ImageLabel,
	flash: Frame,
	loaded: boolean, -- headshot fetch landed; false = hud keeps bitmaps
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

	local image = Instance.new("ImageLabel")
	image.Name = "headshot"
	image.BackgroundTransparency = 1
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromScale(HEAD_ZOOM, HEAD_ZOOM)
	image.Parent = frame

	-- expression sprite between the head and the pain flash
	local overlay = Instance.new("ImageLabel")
	overlay.Name = "expression"
	overlay.BackgroundTransparency = 1
	overlay.ResampleMode = Enum.ResamplerMode.Pixelated
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = image.ZIndex + 1
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
		image = image,
		flash = flash,
		loaded = false,
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
		-- Studio multi-client test players are guests with NEGATIVE
		-- UserIds; thumbnails reject those — borrow the place creator's
		-- avatar, matching the avatarrigs guest substitution
		local uid = Players.LocalPlayer.UserId
		if uid <= 0 then
			uid = if game.CreatorType == Enum.CreatorType.User then game.CreatorId else 0
		end
		if uid <= 0 then
			return -- no fetchable avatar: hud keeps the bitmap faces
		end
		-- the thumbnail render can lag the join; poll until it's ready
		-- (isReady false still returns a placeholder url — don't show it)
		for _ = 1, 15 do
			local ok, content, isReady = pcall(function()
				return Players:GetUserThumbnailAsync(uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
			end)
			if ok and isReady then
				image.Image = content
				af.loaded = true
				return
			end
			task.wait(1)
		end
	end)
	return af
end

function avatarface.ready(af: Face): boolean
	return af.loaded
end

-- drive from Sbar_DrawFace inputs: health (band + death), faceanimtime
-- vs time (pain window). Idempotent per frame; cheap when nothing moves.
function avatarface.update(af: Face, health: number, faceanimtime: number, time: number)
	if not af.loaded then
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
		af.image.ImageColor3 = tint
	end
	af.flash.BackgroundTransparency = flashT
	-- the head and the expression sprite roll together as one GuiObject
	-- rotation (the old camera roll about the look axis read identically;
	-- X-eyes must stay on the eyes through the death tip-over)
	local deg = math.deg(roll)
	af.image.Rotation = deg
	af.overlay.Rotation = deg
end

function avatarface.setVisible(af: Face, on: boolean)
	if af.frame.Visible ~= on then
		af.frame.Visible = on
	end
end

return avatarface
