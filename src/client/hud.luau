--!strict
-- Status bar — port of sbar.c: the real 320px sbar + ibar drawn from
-- gfx.wad pics (numbers, weapon icons with pickup flash, ammo counts in
-- conchars digits, items, sigils, faces), plus center prints and console
-- text overlays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local wadlib = require(engine.gfx.wad)
local vfslib = require(engine.common.vfs)
local cllib = require(engine.client.cl)

local textures = require(script.Parent.render.textures)

local hud = {}

local SCALE = 2 -- 320-wide virtual canvas scaled up

-- item flags (quakedef.h)
local IT_SHOTGUN = 1
local IT_INVULNERABILITY = 4194304
local IT_ARMOR1 = 8192
local IT_ARMOR2 = 16384
local IT_ARMOR3 = 32768
local IT_SHELLS = 256
local IT_NAILS = 512
local IT_ROCKETS = 1024
local IT_CELLS = 2048
local IT_INVISIBILITY = 524288
local IT_QUAD = 2097152

type Pic = { img: EditableImage?, w: number, h: number }

export type Hud = {
	gui: ScreenGui,
	canvas: Frame,
	pics: { [string]: Pic },
	-- dynamic widgets
	armorDigits: { ImageLabel },
	healthDigits: { ImageLabel },
	ammoDigits: { ImageLabel },
	armorIcon: ImageLabel,
	ammoIcon: ImageLabel,
	face: ImageLabel,
	weaponIcons: { ImageLabel },
	itemIcons: { ImageLabel },
	sigilIcons: { ImageLabel },
	countDigits: { { ImageLabel } }, -- 4 ammo types x 3 small digits
	centerLabel: TextLabel,
	consoleLabel: TextLabel,
	centerTime: number,
	consoleLines: { string },
	conchars: buffer?,
	charPics: { [number]: EditableImage? },
	pal: textures.Palette,
}

local function getPic(h: Hud, w: wadlib.Wad, name: string): Pic
	local cached = h.pics[name]
	if cached then
		return cached
	end
	local ok, pic = pcall(wadlib.getPic, w, name)
	if not ok then
		local missing: Pic = { img = nil, w = 8, h = 8 }
		h.pics[name] = missing
		return missing
	end
	local img = textures.createImage(pic.pixels, pic.width, pic.height, h.pal, true)
	local p: Pic = { img = img, w = pic.width, h = pic.height }
	h.pics[name] = p
	return p
end

-- an 8x8 conchars glyph as an image (used for the small yellow ammo counts)
local function charPic(h: Hud, code: number): EditableImage?
	if h.charPics[code] ~= nil then
		return h.charPics[code]
	end
	local conchars = h.conchars
	if not conchars then
		return nil
	end
	local glyph = buffer.create(64)
	local row = math.floor(code / 16)
	local col = code % 16
	for y = 0, 7 do
		for x = 0, 7 do
			local src = (row * 8 + y) * 128 + col * 8 + x
			local p = buffer.readu8(conchars, src)
			-- conchars uses 0 as transparent, not 255
			buffer.writeu8(glyph, y * 8 + x, if p == 0 then 255 else p)
		end
	end
	local img = textures.createImage(glyph, 8, 8, h.pal, true)
	h.charPics[code] = img
	return img
end

local function makeLabel(parent: Instance, x: number, y: number, w: number, hh: number): ImageLabel
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(w * SCALE, hh * SCALE)
	label.Visible = false
	label.Parent = parent
	return label
end

local function setPic(h: Hud, label: ImageLabel, name: string, w: wadlib.Wad)
	local pic = getPic(h, w, name)
	if pic.img then
		label.ImageContent = Content.fromObject(pic.img)
		label.Size = UDim2.fromOffset(pic.w * SCALE, pic.h * SCALE)
		label.Visible = true
	else
		label.Visible = false
	end
end

function hud.create(fs: vfslib.Vfs, pal: textures.Palette, parent: Instance): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeHud"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.ResetOnSpawn = false

	-- 320x48 canvas (ibar on top of sbar), bottom-centered
	local canvas = Instance.new("Frame")
	canvas.Name = "sbarCanvas"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 1)
	canvas.Position = UDim2.new(0.5, 0, 1, 0)
	canvas.Size = UDim2.fromOffset(320 * SCALE, 48 * SCALE)
	canvas.Parent = gui

	local h = {} :: Hud
	h.gui = gui
	h.canvas = canvas
	h.pics = {}
	h.charPics = {}
	h.pal = pal
	h.centerTime = 0
	h.consoleLines = {}

	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	assert(wadbuf, "gfx.wad missing")
	local w = wadlib.load(wadbuf)
	local ok, conchars = pcall(wadlib.getRaw, w, "conchars")
	h.conchars = if ok then conchars else nil

	-- static backgrounds: ibar at canvas y=0 (sbar-space -24), sbar at y=24
	local ibar = makeLabel(canvas, 0, 0, 320, 24)
	setPic(h, ibar, "ibar", w)
	local sbar = makeLabel(canvas, 0, 24, 320, 24)
	setPic(h, sbar, "sbar", w)

	-- sbar row (y=24 in canvas space)
	h.armorIcon = makeLabel(canvas, 0, 24, 24, 24)
	h.armorDigits = {}
	h.healthDigits = {}
	h.ammoDigits = {}
	for d = 0, 2 do
		h.armorDigits[d + 1] = makeLabel(canvas, 24 + d * 24, 24, 24, 24)
		h.healthDigits[d + 1] = makeLabel(canvas, 136 + d * 24, 24, 24, 24)
		h.ammoDigits[d + 1] = makeLabel(canvas, 248 + d * 24, 24, 24, 24)
	end
	h.face = makeLabel(canvas, 112, 24, 24, 24)
	h.ammoIcon = makeLabel(canvas, 224, 24, 24, 24)

	-- ibar row: weapons at y=8 (sbar-space -16), counts at y=0 (-24)
	h.weaponIcons = {}
	for i = 0, 6 do
		h.weaponIcons[i + 1] = makeLabel(canvas, i * 24, 8, 24, 16)
	end
	h.countDigits = {}
	for i = 0, 3 do
		local digits = {}
		for j = 0, 2 do
			digits[j + 1] = makeLabel(canvas, (6 * i + 1 + j) * 8 - 2, 0, 8, 8)
		end
		h.countDigits[i + 1] = digits
	end
	h.itemIcons = {}
	for i = 0, 5 do
		h.itemIcons[i + 1] = makeLabel(canvas, 192 + i * 16, 8, 16, 16)
	end
	h.sigilIcons = {}
	for i = 0, 3 do
		h.sigilIcons[i + 1] = makeLabel(canvas, 288 + i * 8, 8, 8, 16)
	end

	-- text overlays
	local centerLabel = Instance.new("TextLabel")
	centerLabel.Name = "centerprint"
	centerLabel.BackgroundTransparency = 1
	centerLabel.Font = Enum.Font.Code
	centerLabel.TextColor3 = Color3.fromRGB(200, 160, 120)
	centerLabel.TextSize = 24
	centerLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	centerLabel.Position = UDim2.new(0.5, 0, 0.35, 0)
	centerLabel.Size = UDim2.new(0.8, 0, 0.3, 0)
	centerLabel.Text = ""
	centerLabel.TextWrapped = true
	centerLabel.Parent = gui
	h.centerLabel = centerLabel

	local consoleLabel = Instance.new("TextLabel")
	consoleLabel.Name = "console"
	consoleLabel.BackgroundTransparency = 1
	consoleLabel.Font = Enum.Font.Code
	consoleLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	consoleLabel.TextSize = 16
	consoleLabel.TextXAlignment = Enum.TextXAlignment.Left
	consoleLabel.TextYAlignment = Enum.TextYAlignment.Top
	consoleLabel.Position = UDim2.new(0, 8, 0, 8)
	consoleLabel.Size = UDim2.new(0.7, 0, 0, 120)
	consoleLabel.Text = ""
	consoleLabel.Parent = gui
	h.consoleLabel = consoleLabel

	-- stash the wad for update-time pic loads
	;(h :: any)._wad = w

	gui.Parent = parent
	return h
end

-- Sbar_DrawNum: right-justified into `digits` 24px slots; color 1 = red
local function drawNum(h: Hud, labels: { ImageLabel }, baseX: number, num: number, color: number)
	local w = (h :: any)._wad :: wadlib.Wad
	local prefix = if color == 1 then "anum_" else "num_"
	local str = tostring(math.floor(num))
	if #str > 3 then
		str = str:sub(-3)
	end
	local startSlot = 3 - #str
	for slot = 0, 2 do
		local label = labels[slot + 1]
		local ci = slot - startSlot + 1
		if ci >= 1 then
			local ch = str:sub(ci, ci)
			local name = if ch == "-" then prefix .. "minus" else prefix .. ch
			setPic(h, label, name, w)
			label.Position = UDim2.fromOffset((baseX + slot * 24) * SCALE, 24 * SCALE)
		else
			label.Visible = false
		end
	end
end

function hud.centerPrint(h: Hud, s: string, time: number)
	h.centerLabel.Text = (s:gsub("[\1\2]", ""))
	h.centerTime = time + 2
end

function hud.print(h: Hud, s: string)
	local clean = s:gsub("[\128-\255]", function(ch)
		return string.char(bit32.band(ch:byte(), 127))
	end)
	for line in clean:gmatch("[^\n]+") do
		table.insert(h.consoleLines, line)
	end
	while #h.consoleLines > 6 do
		table.remove(h.consoleLines, 1)
	end
	h.consoleLabel.Text = table.concat(h.consoleLines, "\n")
end

local WEAPON_NAMES = { "shotgun", "sshotgun", "nailgun", "snailgun", "rlaunch", "srlaunch", "lightng" }
local ITEM_NAMES = { "sb_key1", "sb_key2", "sb_invis", "sb_invuln", "sb_suit", "sb_quad" }

-- Sbar_Draw
function hud.update(h: Hud, c: cllib.Client)
	local w = (h :: any)._wad :: wadlib.Wad
	local items = c.items
	local health = c.stats[cllib.STAT_HEALTH]

	-- armor
	if bit32.band(items, IT_INVULNERABILITY) ~= 0 then
		drawNum(h, h.armorDigits, 24, 666, 1)
		setPic(h, h.armorIcon, "disc", w)
	else
		local armor = c.stats[cllib.STAT_ARMOR]
		drawNum(h, h.armorDigits, 24, armor, if armor <= 25 then 1 else 0)
		if bit32.band(items, IT_ARMOR3) ~= 0 then
			setPic(h, h.armorIcon, "sb_armor3", w)
		elseif bit32.band(items, IT_ARMOR2) ~= 0 then
			setPic(h, h.armorIcon, "sb_armor2", w)
		elseif bit32.band(items, IT_ARMOR1) ~= 0 then
			setPic(h, h.armorIcon, "sb_armor1", w)
		else
			h.armorIcon.Visible = false
		end
	end

	-- face (Sbar_DrawFace)
	if bit32.band(items, IT_INVISIBILITY + IT_INVULNERABILITY) == IT_INVISIBILITY + IT_INVULNERABILITY then
		setPic(h, h.face, "face_inv2", w)
	elseif bit32.band(items, IT_QUAD) ~= 0 then
		setPic(h, h.face, "face_quad", w)
	elseif bit32.band(items, IT_INVISIBILITY) ~= 0 then
		setPic(h, h.face, "face_invis", w)
	elseif bit32.band(items, IT_INVULNERABILITY) ~= 0 then
		setPic(h, h.face, "face_invul2", w)
	else
		-- sb_faces[f][anim]: face5 is lowest health, face1 highest; the
		-- pain variant shows while cl.faceanimtime is in the future
		local f = math.clamp(math.floor(health / 20), 0, 4)
		local pain = c.faceanimtime > c.time
		local name = if pain then ("face_p" .. (5 - f)) else ("face" .. (5 - f))
		setPic(h, h.face, name, w)
	end

	-- health
	drawNum(h, h.healthDigits, 136, math.max(health, -99), if health <= 25 then 1 else 0)

	-- ammo icon + count
	if bit32.band(items, IT_SHELLS) ~= 0 then
		setPic(h, h.ammoIcon, "sb_shells", w)
	elseif bit32.band(items, IT_NAILS) ~= 0 then
		setPic(h, h.ammoIcon, "sb_nails", w)
	elseif bit32.band(items, IT_ROCKETS) ~= 0 then
		setPic(h, h.ammoIcon, "sb_rocket", w)
	elseif bit32.band(items, IT_CELLS) ~= 0 then
		setPic(h, h.ammoIcon, "sb_cells", w)
	else
		h.ammoIcon.Visible = false
	end
	local ammo = c.stats[cllib.STAT_AMMO]
	drawNum(h, h.ammoDigits, 248, ammo, if ammo <= 10 then 1 else 0)

	-- ibar weapons with pickup flash (Sbar_DrawInventory)
	for i = 0, 6 do
		local label = h.weaponIcons[i + 1]
		if bit32.band(items, bit32.lshift(IT_SHOTGUN, i)) ~= 0 then
			local time = c.item_gettime[i] or 0
			local flashon = math.floor((c.time - time) * 10)
			if flashon >= 10 then
				if c.stats[cllib.STAT_ACTIVEWEAPON] == bit32.lshift(IT_SHOTGUN, i) then
					flashon = 1
				else
					flashon = 0
				end
			else
				flashon = flashon % 5 + 2
			end
			local prefix
			if flashon == 0 then
				prefix = "inv_"
			elseif flashon == 1 then
				prefix = "inv2_"
			else
				prefix = "inva" .. (flashon - 1) .. "_"
			end
			setPic(h, label, prefix .. WEAPON_NAMES[i + 1], w)
			label.Position = UDim2.fromOffset(i * 24 * SCALE, 8 * SCALE)
		else
			label.Visible = false
		end
	end

	-- ibar ammo counts (small yellow conchars digits)
	for i = 0, 3 do
		local count = c.stats[cllib.STAT_SHELLS + i]
		local str = ("%3d"):format(math.clamp(count, 0, 999))
		for j = 0, 2 do
			local label = h.countDigits[i + 1][j + 1]
			local ch = str:sub(j + 1, j + 1)
			if ch ~= " " then
				local img = charPic(h, 18 + (ch:byte() - 48))
				if img then
					label.ImageContent = Content.fromObject(img)
					label.Visible = true
				end
			else
				label.Visible = false
			end
		end
	end

	-- items (keys + powerups): bits 17..22
	for i = 0, 5 do
		local label = h.itemIcons[i + 1]
		if bit32.band(items, bit32.lshift(1, 17 + i)) ~= 0 then
			setPic(h, label, ITEM_NAMES[i + 1], w)
			label.Position = UDim2.fromOffset((192 + i * 16) * SCALE, 8 * SCALE)
		else
			label.Visible = false
		end
	end

	-- sigils: bits 28..31
	for i = 0, 3 do
		local label = h.sigilIcons[i + 1]
		if bit32.band(items, bit32.lshift(1, 28 + i)) ~= 0 then
			setPic(h, label, "sb_sigil" .. (i + 1), w)
			label.Position = UDim2.fromOffset((288 + i * 8) * SCALE, 8 * SCALE)
		else
			label.Visible = false
		end
	end

	if h.centerTime > 0 and c.time > h.centerTime then
		h.centerLabel.Text = ""
		h.centerTime = 0
	end
end

return hud
