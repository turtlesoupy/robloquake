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
local confontlib = require(script.Parent.render.confont)

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
	font: confontlib.Font?,
	centerFrame: Frame,
	centerRows: { confontlib.TextRow },
	centerLines: { string },
	centerStart: number,
	centerTime: number,
	notifyRows: { confontlib.TextRow },
	notifyLines: { { text: string, expire: number } },
	loadingPlaque: ImageLabel?,
	pausePlaque: ImageLabel?,
	interFrame: Frame,
	interSig: string,
	showScores: boolean,
	soloRows: { [string]: confontlib.TextRow },
	sbarBg: ImageLabel,
	fs: vfslib.Vfs,
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
	h.centerStart = 0
	h.centerRows = {}
	h.centerLines = {}
	h.notifyRows = {}
	h.notifyLines = {}

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
	h.sbarBg = sbar

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

	-- text overlays in the conchars font
	h.font = if h.conchars then confontlib.new(h.conchars, pal) else nil

	-- Con_DrawNotify: the last 4 console lines at the top-left, 8px rows,
	-- first column indented one character like (x+1)<<3. Shifted below the
	-- Roblox topbar inset, which would otherwise cover them.
	local inset = game:GetService("GuiService"):GetGuiInset()
	local NOTIFY_COLS = 64
	for i = 1, 4 do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "notify" .. i
		rowFrame.BackgroundTransparency = 1
		rowFrame.Position = UDim2.fromOffset(8 * SCALE, inset.Y + (i - 1) * 8 * SCALE)
		rowFrame.Size = UDim2.fromOffset(NOTIFY_COLS * 8 * SCALE, 8 * SCALE)
		rowFrame.Parent = gui
		h.notifyRows[i] = confontlib.newRow(rowFrame, NOTIFY_COLS, SCALE)
	end

	-- SCR_DrawLoading / SCR_DrawPause: gfx plaques centered above the sbar
	local function plaque(picName: string): ImageLabel?
		local buf = vfslib.loadFile(fs, picName)
		if not buf then
			return nil
		end
		local pic = wadlib.parseQPic(buf)
		local img = textures.createImage(pic.pixels, pic.width, pic.height, pal, true)
		if not img then
			return nil
		end
		local label = Instance.new("ImageLabel")
		label.Name = picName
		label.BackgroundTransparency = 1
		label.ImageContent = Content.fromObject(img)
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.new(0.5, 0, 0.5, -24 * SCALE)
		label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
		label.Visible = false
		label.ZIndex = 15
		label.Parent = gui
		return label
	end
	h.loadingPlaque = plaque("gfx/loading.lmp")
	h.pausePlaque = plaque("gfx/pause.lmp")

	-- SCR_DrawCenterString rows are (re)built per message
	local centerFrame = Instance.new("Frame")
	centerFrame.Name = "centerprint"
	centerFrame.BackgroundTransparency = 1
	centerFrame.Size = UDim2.new(1, 0, 1, 0)
	centerFrame.Parent = gui
	h.centerFrame = centerFrame

	-- Sbar_IntermissionOverlay / Sbar_DeathmatchOverlay / Sbar_FinaleOverlay:
	-- a 320x200 virtual canvas, rebuilt when the overlay state changes
	local interFrame = Instance.new("Frame")
	interFrame.Name = "intermission"
	interFrame.BackgroundTransparency = 1
	interFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	interFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	interFrame.Size = UDim2.fromOffset(320 * SCALE, 200 * SCALE)
	interFrame.Visible = false
	interFrame.ZIndex = 12
	interFrame.Parent = gui
	h.interFrame = interFrame
	h.interSig = ""
	h.showScores = false
	h.fs = fs

	-- Sbar_SoloScoreboard rows drawn over the status row (canvas coords)
	local function soloRow(x: number, y: number, cols: number): confontlib.TextRow
		local holder = Instance.new("Frame")
		holder.Name = "solo"
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
		holder.Size = UDim2.fromOffset(cols * 8 * SCALE, 8 * SCALE)
		holder.Parent = canvas
		local row = confontlib.newRow(holder, cols, SCALE)
		;(row :: any).holder = holder
		return row
	end
	h.soloRows = {
		monsters = soloRow(8, 28, 20),
		secrets = soloRow(8, 36, 20),
		time = soloRow(184, 28, 14),
		level = soloRow(0, 36, 40),
	}

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

-- SCR_CenterPrint + SCR_DrawCenterString: lines centered per-line, block
-- starting at 0.35*height (<=4 lines) or y=48
function hud.centerPrint(h: Hud, s: string, time: number)
	local font = h.font
	if not font then
		return
	end
	table.clear(h.centerLines)
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(h.centerLines, line)
	end
	while #h.centerLines > 0 and h.centerLines[#h.centerLines] == "" do
		table.remove(h.centerLines)
	end
	h.centerFrame:ClearAllChildren()
	table.clear(h.centerRows)
	local n = #h.centerLines
	for i, line in h.centerLines do
		local w = math.max(#line, 1) * 8 * SCALE
		local rowFrame = Instance.new("Frame")
		rowFrame.BackgroundTransparency = 1
		if n <= 4 then
			rowFrame.Position = UDim2.new(0.5, -w / 2, 0.35, (i - 1) * 8 * SCALE)
		else
			rowFrame.Position = UDim2.new(0.5, -w / 2, 0, (48 + (i - 1) * 8) * SCALE)
		end
		rowFrame.Size = UDim2.fromOffset(w, 8 * SCALE)
		rowFrame.Parent = h.centerFrame
		local row = confontlib.newRow(rowFrame, math.max(#line, 1), SCALE)
		confontlib.setRow(font, row, line)
		h.centerRows[i] = row
	end
	h.centerStart = time
	h.centerTime = time + 2 -- scr_centertime
	h.centerFrame.Visible = true
end

local function refreshNotify(h: Hud)
	local font = h.font
	if not font then
		return
	end
	for i = 1, 4 do
		local item = h.notifyLines[i]
		confontlib.setRow(font, h.notifyRows[i], if item then item.text else "")
	end
end

-- SCR_BeginLoadingPlaque / SCR_EndLoadingPlaque
function hud.setLoading(h: Hud, on: boolean)
	if h.loadingPlaque then
		h.loadingPlaque.Visible = on
	end
	if on then
		-- Con_ClearNotify + centertime_off = 0
		table.clear(h.notifyLines)
		refreshNotify(h)
		h.centerFrame.Visible = false
		h.centerTime = 0
	end
end

function hud.setPaused(h: Hud, on: boolean)
	if h.pausePlaque then
		h.pausePlaque.Visible = on
	end
end

-- Con_Print → Con_DrawNotify: raw bytes so bronze text keeps its glyphs
function hud.print(h: Hud, s: string, time: number?)
	for line in s:gmatch("[^\n]+") do
		table.insert(h.notifyLines, { text = line, expire = (time or 0) + 3 }) -- con_notifytime
	end
	while #h.notifyLines > 4 do
		table.remove(h.notifyLines, 1)
	end
	refreshNotify(h)
end

--------------------------------------------------------------------------
-- intermission / rankings overlays

local function interLmp(h: Hud, name: string, x: number, y: number, centered: boolean?)
	local buf = vfslib.loadFile(h.fs, name)
	if not buf then
		return
	end
	local pic = wadlib.parseQPic(buf)
	local img = textures.createImage(pic.pixels, pic.width, pic.height, h.pal, true)
	if not img then
		return
	end
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(img)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	local px = if centered then (320 - pic.width) // 2 else x
	label.Position = UDim2.fromOffset(px * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
	label.Parent = h.interFrame
end

local function interWadPic(h: Hud, name: string, x: number, y: number)
	local w = (h :: any)._wad :: wadlib.Wad
	local p = getPic(h, w, name)
	if not p.img then
		return
	end
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(p.img :: EditableImage)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	label.Size = UDim2.fromOffset(p.w * SCALE, p.h * SCALE)
	label.Parent = h.interFrame
end

-- Sbar_IntermissionNumber: right-justified big digits in a `digits`-wide field
local function interBigNum(h: Hud, x: number, y: number, num: number, digits: number)
	local str = tostring(math.floor(num))
	if #str > digits then
		str = str:sub(-digits)
	end
	x += (digits - #str) * 24
	for i = 1, #str do
		local ch = str:sub(i, i)
		interWadPic(h, if ch == "-" then "num_minus" else "num_" .. ch, x, y)
		x += 24
	end
end

local function interText(h: Hud, x: number, y: number, text: string)
	local font = h.font
	if not font then
		return
	end
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	holder.Size = UDim2.fromOffset(#text * 8 * SCALE, 8 * SCALE)
	holder.Parent = h.interFrame
	local row = confontlib.newRow(holder, math.max(#text, 1), SCALE)
	confontlib.setRow(font, row, text)
end

local function interFill(h: Hud, x: number, y: number, w: number, hh: number, palIndex: number)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = h.pal[palIndex + 1] or Color3.new()
	f.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	f.Size = UDim2.fromOffset(w * SCALE, hh * SCALE)
	f.Parent = h.interFrame
end

-- Sbar_DeathmatchOverlay
local function buildRankings(h: Hud, c: cllib.Client)
	interLmp(h, "gfx/ranking.lmp", 0, 8, true)
	-- Sbar_SortFrags
	local order = {}
	for i, sc in c.scores do
		if sc.name ~= "" then
			table.insert(order, i)
		end
	end
	table.sort(order, function(a, b)
		return c.scores[a].frags > c.scores[b].frags
	end)
	local x, y = 80, 40
	for _, k in order do
		local sc = c.scores[k]
		-- Sbar_ColorForMap: palette row base + 8
		interFill(h, x, y, 40, 4, bit32.band(sc.colors, 0xf0) + 8)
		interFill(h, x, y + 4, 40, 4, bit32.lshift(bit32.band(sc.colors, 15), 4) + 8)
		interText(h, x + 8, y, ("%3i"):format(sc.frags))
		if k == c.viewentity - 1 then
			interText(h, x - 8, y, string.char(12))
		end
		interText(h, x + 64, y, sc.name)
		y += 10
	end
end

-- Sbar_IntermissionOverlay (single player)
local function buildIntermission(h: Hud, c: cllib.Client)
	interLmp(h, "gfx/complete.lmp", 64, 24)
	interLmp(h, "gfx/inter.lmp", 0, 56)
	local t = math.floor(c.completed_time)
	local mins = t // 60
	local secs = t - mins * 60
	interBigNum(h, 160, 64, mins, 3)
	interWadPic(h, "num_colon", 234, 64)
	interWadPic(h, "num_" .. (secs // 10), 246, 64)
	interWadPic(h, "num_" .. (secs % 10), 266, 64)
	interBigNum(h, 160, 104, c.stats[13] or 0, 3) -- STAT_SECRETS
	interWadPic(h, "num_slash", 232, 104)
	interBigNum(h, 240, 104, c.stats[11] or 0, 3) -- STAT_TOTALSECRETS
	interBigNum(h, 160, 144, c.stats[14] or 0, 3) -- STAT_MONSTERS
	interWadPic(h, "num_slash", 232, 144)
	interBigNum(h, 240, 144, c.stats[12] or 0, 3) -- STAT_TOTALMONSTERS
end

function hud.setShowScores(h: Hud, on: boolean)
	h.showScores = on
end

function hud.updateOverlays(h: Hud, c: cllib.Client)
	local mode = ""
	if c.intermission == 1 then
		mode = if c.gametype == 1 then "dm" else "sp"
	elseif c.intermission >= 2 then
		mode = "finale"
	elseif h.showScores and c.gametype == 1 then
		mode = "dm"
	end

	local sig = mode
	if mode == "dm" then
		for _, sc in c.scores do
			if sc.name ~= "" then
				sig ..= ("|%s:%d:%d"):format(sc.name, sc.frags, sc.colors)
			end
		end
	elseif mode == "sp" then
		sig ..= tostring(math.floor(c.completed_time))
	end

	if sig ~= h.interSig then
		h.interSig = sig
		h.interFrame:ClearAllChildren()
		if mode == "dm" then
			buildRankings(h, c)
		elseif mode == "sp" then
			buildIntermission(h, c)
		elseif mode == "finale" then
			interLmp(h, "gfx/finale.lmp", 0, 16, true)
		end
	end
	h.interFrame.Visible = mode ~= ""
end

local WEAPON_NAMES = { "shotgun", "sshotgun", "nailgun", "snailgun", "rlaunch", "srlaunch", "lightng" }
local ITEM_NAMES = { "sb_key1", "sb_key2", "sb_invis", "sb_invuln", "sb_suit", "sb_quad" }

-- Sbar_Draw
function hud.update(h: Hud, c: cllib.Client)
	local w = (h :: any)._wad :: wadlib.Wad
	local items = c.items
	local health = c.stats[cllib.STAT_HEALTH]

	-- Sbar_DrawScoreboard (solo): replaces the status row when showing
	-- scores or dead, outside deathmatch
	local soloActive = (h.showScores or health <= 0) and c.gametype ~= 1
	-- Sbar_Draw swaps the status backdrop for scorebar.lmp when scoring
	setPic(h, h.sbarBg, if soloActive then "scorebar" else "sbar", w)
	h.sbarBg.Position = UDim2.fromOffset(0, 24 * SCALE)

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

	-- Sbar_SoloScoreboard text over the status row
	local font = h.font
	if soloActive and font then
		local mins = math.floor(c.time / 60)
		local secs = math.floor(c.time - 60 * mins)
		confontlib.setRow(font, h.soloRows.monsters, ("Monsters:%3i /%3i"):format(c.stats[14] or 0, c.stats[12] or 0))
		confontlib.setRow(font, h.soloRows.secrets, ("Secrets :%3i /%3i"):format(c.stats[13] or 0, c.stats[11] or 0))
		confontlib.setRow(font, h.soloRows.time, ("Time :%3i:%i%i"):format(mins, secs // 10, secs % 10))
		confontlib.setRow(font, h.soloRows.level, c.levelname)
		local lvlHolder = (h.soloRows.level :: any).holder :: Frame
		lvlHolder.Position = UDim2.fromOffset((232 - #c.levelname * 4) * SCALE, 36 * SCALE)
		for _, row in h.soloRows do
			((row :: any).holder :: Frame).Visible = true
		end
		-- hide the status-row widgets the scoreboard replaces
		h.armorIcon.Visible = false
		h.face.Visible = false
		h.ammoIcon.Visible = false
		for _, l in h.armorDigits do
			l.Visible = false
		end
		for _, l in h.healthDigits do
			l.Visible = false
		end
		for _, l in h.ammoDigits do
			l.Visible = false
		end
	else
		for _, row in h.soloRows do
			((row :: any).holder :: Frame).Visible = false
		end
	end

	-- notify lines age out after con_notifytime
	local pruned = false
	for i = #h.notifyLines, 1, -1 do
		if c.time > h.notifyLines[i].expire then
			table.remove(h.notifyLines, i)
			pruned = true
		end
	end
	if pruned then
		refreshNotify(h)
	end

	-- the finale prints its centerstring one character at a time
	-- (scr_printspeed); outside intermission everything shows at once
	local font = h.font
	if h.centerFrame.Visible and c.intermission ~= 0 and font then
		local remaining = math.floor(8 * (c.time - h.centerStart))
		for i, line in h.centerLines do
			local shown = math.clamp(remaining, 0, #line)
			confontlib.setRow(font, h.centerRows[i], line:sub(1, shown))
			remaining -= shown
		end
	end

	if h.centerTime > 0 and c.time > h.centerTime and c.intermission == 0 then
		h.centerFrame.Visible = false
		h.centerTime = 0
	end
end

return hud
