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
local qwview = require(engine.qw.qwview)

local textures = require(script.Parent.render.textures)
local confontlib = require(script.Parent.render.confont)

local hud = {}

local SCALE = 2 -- 320-wide virtual canvas scaled up

-- screen.c sb_lines: >=120 no bar, >=110 status row only, else full HUD
function hud.sbarLinesPx(viewsize: number): number
	if viewsize >= 120 then
		return 0
	elseif viewsize >= 110 then
		return 24 * SCALE
	end
	return 48 * SCALE
end
hud.SBAR_LINES_PX = hud.sbarLinesPx(100) -- default viewsize

-- item flags (quakedef.h)
local IT_SHOTGUN = 1
local IT_INVULNERABILITY = 1048576 -- quakedef.h:158
local IT_ARMOR1 = 8192
local IT_ARMOR2 = 16384
local IT_ARMOR3 = 32768
local IT_SHELLS = 256
local IT_NAILS = 512
local IT_ROCKETS = 1024
local IT_CELLS = 2048
local IT_INVISIBILITY = 524288
local IT_QUAD = 4194304 -- quakedef.h:160

-- img is usually the shared page (rect-addressed); dedicated only when
-- the page is full. One page instead of ~25 pics: live EditableImage
-- bindings are a scarce pool (~128) and binds past the cap render black.
type Pic = { img: EditableImage?, content: Content?, off: Vector2, w: number, h: number }

export type Hud = {
	gui: ScreenGui,
	canvas: Frame,
	pics: { [string]: Pic },
	lastPic: { [ImageLabel]: string }, -- setPic dirty-check (Sbar_Changed spirit)
	lastDigit: { [ImageLabel]: string }, -- small ammo-count digit dirty-check
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
	notifyCols: number,
	notifyHolders: { Frame },
	notifyY: number,
	notifyOpen: boolean, -- Con_Print: the last notify line has no \n yet
	loadingPlaque: ImageLabel?,
	loadingCurtain: GuiObject?,
	pausePlaque: ImageLabel?,
	interFrame: Frame,
	interSig: string,
	miniFrame: Frame,
	miniSig: string,
	viewsize: number,
	showScores: boolean,
	showTeamScores: boolean,
	soloRows: { [string]: confontlib.TextRow },
	sbarBg: ImageLabel,
	fs: vfslib.Vfs,
	conchars: buffer?,
	charPics: { [number]: Pic? },
	page: textures.ImagePage,
	pal: textures.Palette,
}

local function getPic(h: Hud, w: wadlib.Wad, name: string): Pic
	local cached = h.pics[name]
	if cached then
		return cached
	end
	local ok, pic = pcall(wadlib.getPic, w, name)
	if not ok then
		local missing: Pic = { img = nil, off = Vector2.zero, w = 8, h = 8 }
		h.pics[name] = missing
		return missing
	end
	local off = textures.pageAlloc(h.page, pic.pixels, pic.width, pic.height, h.pal, true)
	local p: Pic
	if off then
		p = { img = h.page.img, off = off, w = pic.width, h = pic.height }
	else
		-- page full: dedicated image (rect (0,0)-(w,h) addresses it whole)
		local img = textures.createImage(pic.pixels, pic.width, pic.height, h.pal, true)
		p = { img = img, off = Vector2.zero, w = pic.width, h = pic.height }
	end
	p.content = if p.img then Content.fromObject(p.img) else nil
	h.pics[name] = p
	return p
end

-- an 8x8 conchars glyph pic (used for the small yellow ammo counts)
local function charPic(h: Hud, code: number): Pic?
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
	local off = textures.pageAlloc(h.page, glyph, 8, 8, h.pal, true)
	local p: Pic? = nil
	if off then
		p = { img = h.page.img, off = off, w = 8, h = 8 }
	else
		local img = textures.createImage(glyph, 8, 8, h.pal, true)
		if img then
			p = { img = img, off = Vector2.zero, w = 8, h = 8 }
		end
	end
	if p and p.img then
		p.content = Content.fromObject(p.img)
	end
	h.charPics[code] = p
	return p
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

-- Sbar_Changed spirit: the C sbar only repaints when sb_updates was
-- bumped; here each label skips its reflected writes when it already
-- shows the named pic. hidePic clears the cache so the next setPic
-- re-applies in full.
local function setPic(h: Hud, label: ImageLabel, name: string, w: wadlib.Wad)
	if h.lastPic[label] == name then
		return
	end
	local pic = getPic(h, w, name)
	h.lastPic[label] = name
	if pic.img then
		label.ImageContent = pic.content :: Content
		label.ImageRectOffset = pic.off
		label.ImageRectSize = Vector2.new(pic.w, pic.h)
		label.Size = UDim2.fromOffset(pic.w * SCALE, pic.h * SCALE)
		label.Visible = true
	else
		label.Visible = false
	end
end

local function hidePic(h: Hud, label: ImageLabel)
	if h.lastPic[label] ~= nil then
		h.lastPic[label] = nil
		label.Visible = false
	end
end

-- Con_CheckResize (console.c): the console/notify column count derives
-- from the viewport width — (vid.conwidth >> 3) - 3 in C, here with
-- 8*SCALE-pixel characters. Floor 38 like C's too-small fallback; the
-- cap only bounds glyph-label instance counts on very wide windows.
local MIN_NOTIFY_COLS = 38
local MAX_NOTIFY_COLS = 120
local function notifyColsFor(gui: ScreenGui): number
	local w = gui.AbsoluteSize.X
	if w <= 0 then
		return 64 -- pre-layout default; the per-frame check corrects it
	end
	return math.clamp(math.floor(w / (8 * SCALE)) - 3, MIN_NOTIFY_COLS, MAX_NOTIFY_COLS)
end

-- (re)build the 4 notify rows at h.notifyCols (Con_DrawNotify geometry:
-- one char indent, 8px rows below the Roblox topbar inset)
local function buildNotifyRows(h: Hud)
	for _, f in h.notifyHolders do
		f:Destroy()
	end
	table.clear(h.notifyHolders)
	table.clear(h.notifyRows)
	for i = 1, 4 do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "notify" .. i
		rowFrame.BackgroundTransparency = 1
		rowFrame.Position = UDim2.fromOffset(8 * SCALE, h.notifyY + (i - 1) * 8 * SCALE)
		rowFrame.Size = UDim2.fromOffset(h.notifyCols * 8 * SCALE, 8 * SCALE)
		rowFrame.Parent = h.gui
		h.notifyHolders[i] = rowFrame
		h.notifyRows[i] = confontlib.newRow(rowFrame, h.notifyCols, SCALE)
	end
end

function hud.create(fs: vfslib.Vfs, pal: textures.Palette, parent: Instance): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakeHud"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.ResetOnSpawn = false

	-- 320x48 canvas (ibar on top of sbar), bottom-centered
	local strip = Instance.new("Frame")
	strip.Name = "sbarStrip"
	strip.BorderSizePixel = 0
	strip.BackgroundColor3 = Color3.new(0, 0, 0)
	strip.AnchorPoint = Vector2.new(0, 1)
	strip.Position = UDim2.new(0, 0, 1, 0)
	strip.Size = UDim2.new(1, 0, 0, 48 * SCALE)
	strip.ZIndex = 0
	strip.Parent = gui

	local canvas = Instance.new("Frame")
	canvas.Name = "sbarCanvas"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 1)
	canvas.Position = UDim2.new(0.5, 0, 1, 0)
	canvas.Size = UDim2.fromOffset(320 * SCALE, 48 * SCALE)
	canvas.Parent = gui

	local h = {} :: Hud
	h.gui = gui
	h.sbarStrip = strip
	h.canvas = canvas
	h.pics = {}
	h.lastPic = {}
	h.lastDigit = {}
	h.charPics = {}
	h.page = textures.newImagePage(512)
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

	-- static backgrounds: ibar at canvas y=0 (sbar-space -24), sbar at y=24.
	-- the whole inventory row lives in its own frame: screen.c's
	-- sb_lines drops it first as viewsize rises
	local ibarRow = Instance.new("Frame")
	ibarRow.Name = "ibarRow"
	ibarRow.BackgroundTransparency = 1
	ibarRow.Size = UDim2.fromOffset(320 * SCALE, 24 * SCALE)
	ibarRow.Parent = canvas
	h.ibarRow = ibarRow
	local ibar = makeLabel(ibarRow, 0, 0, 320, 24)
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
		h.weaponIcons[i + 1] = makeLabel(ibarRow, i * 24, 8, 24, 16)
	end
	h.countDigits = {}
	for i = 0, 3 do
		local digits = {}
		for j = 0, 2 do
			-- C x is (6*i+1+j)*8 - 2, plus Sbar_DrawCharacter's built-in +4
			digits[j + 1] = makeLabel(ibarRow, (6 * i + 1 + j) * 8 + 2, 0, 8, 8)
		end
		h.countDigits[i + 1] = digits
	end
	h.itemIcons = {}
	for i = 0, 5 do
		h.itemIcons[i + 1] = makeLabel(ibarRow, 192 + i * 16, 8, 16, 16)
	end
	h.sigilIcons = {}
	for i = 0, 3 do
		h.sigilIcons[i + 1] = makeLabel(ibarRow, 288 + i * 8, 8, 8, 16)
	end

	-- text overlays in the conchars font
	h.font = if h.conchars then confontlib.new(h.conchars, pal) else nil

	-- Con_DrawNotify: the last 4 console lines at the top-left, 8px rows,
	-- first column indented one character like (x+1)<<3. Shifted below the
	-- Roblox topbar inset, which would otherwise cover them. Width tracks
	-- the viewport (Con_CheckResize) — rebuilt in hud.update on resize.
	local inset = game:GetService("GuiService"):GetGuiInset()
	h.notifyY = inset.Y
	h.notifyHolders = {}
	h.notifyCols = notifyColsFor(gui)
	h.notifyOpen = false
	buildNotifyRows(h)

	-- SCR_DrawRam / SCR_DrawTurtle / SCR_DrawNet: status icons at the
	-- view top-left (turtle x=vrect.x, ram +32, net +64 like screen.c)
	local iconsFrame = Instance.new("Frame")
	iconsFrame.Name = "scricons"
	iconsFrame.BackgroundTransparency = 1
	iconsFrame.Position = UDim2.fromOffset(0, inset.Y + 40 * SCALE)
	iconsFrame.Size = UDim2.fromOffset(96 * SCALE, 16 * SCALE)
	iconsFrame.Parent = gui
	local turtleIcon = makeLabel(iconsFrame, 0, 0, 16, 16)
	setPic(h, turtleIcon, "turtle", w)
	turtleIcon.Visible = false
	local ramIcon = makeLabel(iconsFrame, 32, 0, 16, 16)
	setPic(h, ramIcon, "ram", w)
	ramIcon.Visible = false
	local netIcon = makeLabel(iconsFrame, 64, 0, 16, 16)
	setPic(h, netIcon, "net", w)
	netIcon.Visible = false
	;(h :: any).turtleIcon = turtleIcon
	;(h :: any).ramIcon = ramIcon
	;(h :: any).netIcon = netIcon

	-- SCR_DrawFPS (QW): bottom-right counter, gated by show_fps
	local fpsHolder = Instance.new("Frame")
	fpsHolder.Name = "fps"
	fpsHolder.BackgroundTransparency = 1
	fpsHolder.AnchorPoint = Vector2.new(1, 1)
	fpsHolder.Position = UDim2.new(1, -8, 1, -hud.SBAR_LINES_PX - 8)
	fpsHolder.Size = UDim2.fromOffset(10 * 8 * SCALE, 8 * SCALE)
	fpsHolder.Visible = false
	fpsHolder.Parent = gui
	;(h :: any).fpsRow = confontlib.newRow(fpsHolder, 10, SCALE)
	;(h :: any).fpsHolder = fpsHolder

	-- SCR_DrawLoading / SCR_DrawPause: gfx plaques centered above the sbar
	local function plaque(picName: string): ImageLabel?
		local buf = vfslib.loadFile(fs, picName)
		if not buf then
			return nil
		end
		local pic = wadlib.parseQPic(buf)
		local off = textures.pageAlloc(h.page, pic.pixels, pic.width, pic.height, pal, true)
		local img = if off then h.page.img else textures.createImage(pic.pixels, pic.width, pic.height, pal, true)
		if not img then
			return nil
		end
		local label = Instance.new("ImageLabel")
		label.Name = picName
		label.BackgroundTransparency = 1
		label.ImageContent = Content.fromObject(img)
		label.ImageRectOffset = off or Vector2.zero
		label.ImageRectSize = Vector2.new(pic.width, pic.height)
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.new(0.5, 0, 0.5, -24 * SCALE)
		label.Size = UDim2.fromOffset(pic.width * SCALE, pic.height * SCALE)
		label.Visible = false
		label.ZIndex = 15
		label.Parent = gui
		return label
	end
	-- scr_disabled_for_loading analog: Quake freezes the screen under the
	-- loading plaque (SCR_UpdateScreen returns early), but the Roblox
	-- viewport keeps rendering the workspace — entities pop in against the
	-- void while the world mesh builds. An opaque conback curtain stands in
	-- for the not-updating screen (it's what a first-connect load shows).
	do
		local curtain: GuiObject
		local img: EditableImage? = nil
		local backbuf = vfslib.loadFile(fs, "gfx/conback.lmp")
		if backbuf then
			local pic = wadlib.parseQPic(backbuf)
			img = textures.createImage(pic.pixels, pic.width, pic.height, pal, false)
		end
		if img then
			local label = Instance.new("ImageLabel")
			label.ImageContent = Content.fromObject(img :: EditableImage)
			label.ResampleMode = Enum.ResamplerMode.Pixelated
			curtain = label
		else
			curtain = Instance.new("Frame")
		end
		curtain.Name = "loadingCurtain"
		curtain.BackgroundColor3 = Color3.new(0, 0, 0)
		curtain.BackgroundTransparency = 0
		curtain.BorderSizePixel = 0
		curtain.Size = UDim2.fromScale(1, 1)
		curtain.Visible = false
		curtain.ZIndex = 14
		curtain.Parent = gui
		h.loadingCurtain = curtain
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
	h.showTeamScores = false
	h.viewsize = 100
	h.fs = fs

	-- Sbar_MiniDeathmatchOverlay: frags/name list right of the sbar
	-- (canvas-relative x=324, sbar-height rows)
	local miniFrame = Instance.new("Frame")
	miniFrame.Name = "minidm"
	miniFrame.BackgroundTransparency = 1
	miniFrame.Position = UDim2.fromOffset(324 * SCALE, 0)
	miniFrame.Size = UDim2.fromOffset(160 * SCALE, 48 * SCALE)
	miniFrame.Visible = false
	miniFrame.Parent = canvas
	h.miniFrame = miniFrame
	h.miniSig = ""

	-- Sbar_DrawFrags: up to 4 mini frag cells in the ibar's top-right
	-- (x = 23*8, colors fill + frags + own-slot brackets)
	local fragsFrame = Instance.new("Frame")
	fragsFrame.Name = "fragcells"
	fragsFrame.BackgroundTransparency = 1
	fragsFrame.Position = UDim2.fromOffset(184 * SCALE, 0) -- 23*8
	fragsFrame.Size = UDim2.fromOffset(136 * SCALE, 8 * SCALE)
	fragsFrame.Visible = false
	fragsFrame.Parent = ibarRow
	;(h :: any).fragsFrame = fragsFrame
	;(h :: any).fragsGen = -1

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
			-- position is fixed at creation (baseX + slot*24, 24)
		else
			hidePic(h, label)
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
	if h.loadingCurtain then
		h.loadingCurtain.Visible = on
	end
	if on then
		-- Con_ClearNotify + centertime_off = 0
		table.clear(h.notifyLines)
		h.notifyOpen = false
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

-- Con_Print → Con_DrawNotify: raw bytes so bronze text keeps its glyphs.
-- Appends to the OPEN line — server messages arrive in pieces
-- ("You got the " .. "nails\n") — closing only on '\n'; wraps at the
-- live column count like Con_Print filling the text buffer. Appending
-- refreshes the line's con_notifytime window like C's con_times stamp.
function hud.printCon(h: Hud, s: string, time: number?)
	local expire = (time or 0) + 3 -- con_notifytime
	local pieces = s:split("\n")
	for j, piece in pieces do
		if #piece > 0 then
			if h.notifyOpen and #h.notifyLines > 0 then
				local last = h.notifyLines[#h.notifyLines]
				last.text ..= piece
				last.expire = expire
			else
				table.insert(h.notifyLines, { text = piece, expire = expire })
			end
			h.notifyOpen = true
			while #h.notifyLines[#h.notifyLines].text > h.notifyCols do
				local last = table.remove(h.notifyLines) :: { text: string, expire: number }
				table.insert(h.notifyLines, { text = last.text:sub(1, h.notifyCols), expire = last.expire })
				table.insert(h.notifyLines, { text = last.text:sub(h.notifyCols + 1), expire = last.expire })
			end
		end
		if j < #pieces then
			h.notifyOpen = false -- blank lines are not worth a notify row
		end
	end
	while #h.notifyLines > 4 do
		table.remove(h.notifyLines, 1)
	end
	refreshNotify(h)
end

-- one call = one finished line (chat and product-layer messages)
function hud.print(h: Hud, s: string, time: number?)
	hud.printCon(h, s .. "\n", time)
end

--------------------------------------------------------------------------
-- intermission / rankings overlays

local function interLmp(h: Hud, name: string, x: number, y: number, centered: boolean?)
	local buf = vfslib.loadFile(h.fs, name)
	if not buf then
		return
	end
	local pic = wadlib.parseQPic(buf)
	local off = textures.pageAlloc(h.page, pic.pixels, pic.width, pic.height, h.pal, true)
	local img = if off then h.page.img else textures.createImage(pic.pixels, pic.width, pic.height, h.pal, true)
	if not img then
		return
	end
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(img)
	label.ImageRectOffset = off or Vector2.zero
	label.ImageRectSize = Vector2.new(pic.width, pic.height)
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
	label.ImageRectOffset = p.off
	label.ImageRectSize = Vector2.new(p.w, p.h)
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
	-- Palette is {r,g,b} arrays, not Color3s (was pal[i].R — always nil,
	-- so scoreboard color fills silently rendered black)
	f.BackgroundColor3 = Color3.fromRGB(h.pal.r[palIndex + 1] or 0, h.pal.g[palIndex + 1] or 0, h.pal.b[palIndex + 1] or 0)
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
		-- own slot: scores is 1-based, entity n = slot n-1 = scores[n]
		if k == c.viewentity then
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

-- viewsize application (screen.c sb_lines): 100 = full HUD, 110 =
-- status row only, 120 = none. The boot recomputes the vrect fov with
-- hud.sbarLinesPx after calling this.
function hud.setViewsize(h: Hud, viewsize: number)
	h.viewsize = viewsize
	local px = hud.sbarLinesPx(viewsize)
	h.sbarStrip.Size = UDim2.new(1, 0, 0, px)
	h.sbarStrip.Visible = px > 0
	h.ibarRow.Visible = viewsize < 110
	local canvas = h.ibarRow.Parent :: Frame
	canvas.Visible = viewsize < 120
end

-- SCR_DrawTurtle / SCR_DrawRam / SCR_DrawNet visibility (conditions are
-- the boot's: turtle = 3 consecutive >0.1s frames, net = no message for
-- 0.3s, ram = surface-cache thrash — no surface cache exists, so the
-- boot never raises it (documented))
function hud.setIcons(h: Hud, turtle: boolean, ram: boolean, net: boolean)
	((h :: any).turtleIcon :: ImageLabel).Visible = turtle
	;((h :: any).ramIcon :: ImageLabel).Visible = ram
	;((h :: any).netIcon :: ImageLabel).Visible = net
end

-- SCR_DrawFPS: nil hides
function hud.setFps(h: Hud, fps: number?)
	local holder = (h :: any).fpsHolder :: Frame
	holder.Visible = fps ~= nil
	local font = h.font
	if fps and font then
		confontlib.setRow(font, (h :: any).fpsRow, ("%3d FPS"):format(fps))
	end
end

function hud.setShowScores(h: Hud, on: boolean)
	h.showScores = on
end

-- Sbar_ShowTeamScores / Sbar_DontShowTeamScores (+showteamscores keys)
function hud.setShowTeamScores(h: Hud, on: boolean)
	h.showTeamScores = on
end

-- Sbar_DeathmatchOverlay (QW sbar.c): ping/pl/time/frags/name columns,
-- color fill at +104, frags at +112; teamplay adds the team column and
-- shifts the base to x=4. `start` ~= 0 skips the ranking plaque (the
-- team overlay appends the player list below itself, like C).
local function buildQWRankings(h: Hud, c: any, start: number)
	local teamplay = (c.teamplay or 0) > 0
	local x, y
	if start == 0 then
		interLmp(h, "gfx/ranking.lmp", 0, 0, true)
		y = 24
	else
		y = start
	end
	x = if teamplay then 4 else 16
	if teamplay then
		interText(h, x, y, "ping pl time frags team name")
		y += 8
		interText(h, x, y, "\29\30\30\31 \29\31 \29\30\30\31 \29\30\30\30\31 \29\30\30\31 \29\30\30\30\30\30\30\30\30\30\30\30\30\30\31")
	else
		interText(h, x, y, "ping pl time frags name")
		y += 8
		interText(h, x, y, "\29\30\30\31 \29\31 \29\30\30\31 \29\30\30\30\31 \29\30\30\30\30\30\30\30\30\30\30\30\30\30\31")
	end
	y += 8

	-- Sbar_SortFrags(true): spectators included at -999
	local order = qwview.sortFrags(c.scores, true)
	local nameX = if teamplay then x + 152 + 40 else x + 152

	for _, k in order do
		if y > 200 - 10 then
			break
		end
		local sc = c.scores[k]
		local ping = math.clamp(sc.ping or 0, 0, 999)
		interText(h, x, y, ("%4i"):format(ping))
		interText(h, x + 32, y, ("%3i"):format(sc.pl or 0))
		if sc.spectator then
			interText(h, x + 40, y, "(spectator)")
			interText(h, nameX, y, sc.name)
		else
			local total = (if c.intermission ~= 0 then c.completed_time else c.time) - (sc.entertime or 0)
			interText(h, x + 64, y, ("%4i"):format(math.max(total // 60, 0)))
			interFill(h, x + 104, y + 1, 40, 4, bit32.band(sc.colors, 0xf0) + 8)
			interFill(h, x + 104, y + 5, 40, 4, bit32.lshift(bit32.band(sc.colors, 15), 4) + 8)
			interText(h, x + 112, y, ("%3i"):format(sc.frags))
			if k == c.playerslot then
				interText(h, x + 104, y, string.char(16))
				interText(h, x + 136, y, string.char(17))
			end
			if teamplay then
				interText(h, x + 152, y, (sc.team or ""):sub(1, 4))
			end
			interText(h, nameX, y, sc.name)
		end
		y += 10
	end
end

-- Sbar_TeamOverlay: low/avg/high ping, team, total frags, player count
-- per team, then the full player list below (C appends
-- Sbar_DeathmatchOverlay(y))
local function buildQWTeamOverlay(h: Hud, c: any)
	local teamplay = c.teamplay or 0
	if teamplay == 0 then
		-- C falls through to the plain rankings
		buildQWRankings(h, c, 0)
		return
	end
	interLmp(h, "gfx/ranking.lmp", 0, 0, true)
	local x, y = 36, 24
	interText(h, x, y, "low/avg/high team total players")
	y += 8
	interText(h, x, y, "\29\30\30\30\30\30\30\30\30\30\30\31 \29\30\30\31 \29\30\30\30\31 \29\30\30\30\30\30\31")
	y += 8

	local ownTeam = ""
	local own = c.scores[c.playerslot]
	if own then
		ownTeam = (own.team or ""):sub(1, 16)
	end

	local teams = qwview.sortTeams(c.scores, teamplay)
	for _, tm in teams do
		if y > 200 - 10 then
			break
		end
		local plow = math.clamp(tm.plow, 0, 999)
		local phigh = math.clamp(tm.phigh, 0, 999)
		local pavg = if tm.players == 0 then 999 else math.clamp(tm.ptotal // tm.players, 0, 999)
		interText(h, x, y, ("%3i/%3i/%3i"):format(plow, pavg, phigh))
		interText(h, x + 104, y, tm.team:sub(1, 4))
		interText(h, x + 104 + 40, y, ("%5i"):format(tm.frags))
		interText(h, x + 104 + 88, y, ("%5i"):format(tm.players))
		if tm.team == ownTeam then
			interText(h, x + 104 - 8, y, string.char(16))
			interText(h, x + 104 + 32, y, string.char(17))
		end
		y += 8
	end
	y += 8
	buildQWRankings(h, c, y)
end

-- generic text/fill helpers targeting an arbitrary overlay frame
local function frameText(h: Hud, parent: Frame, x: number, y: number, text: string)
	local font = h.font
	if not font then
		return
	end
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	holder.Size = UDim2.fromOffset(#text * 8 * SCALE, 8 * SCALE)
	holder.Parent = parent
	local row = confontlib.newRow(holder, math.max(#text, 1), SCALE)
	confontlib.setRow(font, row, text)
end

local function frameFill(h: Hud, parent: Frame, x: number, y: number, w: number, hh: number, palIndex: number)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Color3.fromRGB(h.pal.r[palIndex + 1] or 0, h.pal.g[palIndex + 1] or 0, h.pal.b[palIndex + 1] or 0)
	f.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	f.Size = UDim2.fromOffset(w * SCALE, hh * SCALE)
	f.Parent = parent
end

-- Sbar_DrawFrags: the top-4 frag cells in the ibar row. Both sbar.c
-- versions share the layout: fills at x*8+10 (28 wide), digits at
-- (x+1..3)*8+4 (chars get Sbar_DrawCharacter's +4, fills don't),
-- own-slot brackets, 4 cells of 32px from x=23*8. The C
-- deathmatch xofs=0 quirk (fills screen-left, digits sbar-relative)
-- collapses at the 320 reference width the canvas replicates, so both
-- draw sbar-relative here.
local function updateFragCells(h: Hud, scores: { any }, playerslot: number, gen: number)
	local frame = (h :: any).fragsFrame :: Frame
	-- rebuild gate: scoresGen replaces the per-frame signature string (and
	-- skips the per-frame sortFrags alloc entirely)
	if (h :: any).fragsGen == gen and (h :: any).fragsSlot == playerslot then
		return
	end
	;(h :: any).fragsGen = gen
	;(h :: any).fragsSlot = playerslot
	local order = qwview.sortFrags(scores, false)
	frame:ClearAllChildren()
	frame.Visible = #order > 0
	local x = 23
	for i = 1, math.min(#order, 4) do
		local k = order[i]
		local sc = scores[k]
		if sc.name ~= "" then
			frameFill(h, frame, x * 8 + 10 - 184, 1, 28, 4, bit32.band(sc.colors, 0xf0) + 8)
			frameFill(h, frame, x * 8 + 10 - 184, 5, 28, 3, bit32.lshift(bit32.band(sc.colors, 15), 4) + 8)
			local num = ("%3i"):format(sc.frags)
			-- chars carry Sbar_DrawCharacter's built-in +4; fills don't
			for j = 1, 3 do
				frameText(h, frame, (x + j) * 8 + 4 - 184, 0, num:sub(j, j))
			end
			if k == playerslot then
				frameText(h, frame, x * 8 + 2 + 4 - 184, 0, string.char(16))
				frameText(h, frame, (x + 4) * 8 - 4 + 4 - 184, 0, string.char(17))
			end
			x += 4
		end
	end
end

-- text/fill helpers targeting the mini overlay frame
local function miniText(h: Hud, x: number, y: number, text: string)
	local font = h.font
	if not font then
		return
	end
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	holder.Size = UDim2.fromOffset(#text * 8 * SCALE, 8 * SCALE)
	holder.Parent = h.miniFrame
	local row = confontlib.newRow(holder, math.max(#text, 1), SCALE)
	confontlib.setRow(font, row, text)
end

local function miniFill(h: Hud, x: number, y: number, w: number, hh: number, palIndex: number)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Color3.fromRGB(h.pal.r[palIndex + 1] or 0, h.pal.g[palIndex + 1] or 0, h.pal.b[palIndex + 1] or 0)
	f.Position = UDim2.fromOffset(x * SCALE, y * SCALE)
	f.Size = UDim2.fromOffset(w * SCALE, hh * SCALE)
	f.Parent = h.miniFrame
end

-- Sbar_MiniDeathmatchOverlay: a frags/name strip right of the sbar,
-- windowed around the local player. Draws only with sb_lines > 0 and a
-- window wide enough (C: vid.width >= 512).
local function updateMiniOverlay(h: Hud, scores: { any }, playerslot: number, teamplayNum: number, gen: number)
	local sbLines = if h.viewsize >= 120 then 0 elseif h.viewsize >= 110 then 24 else 48
	local numlines = sbLines // 8
	local vidWidth = h.gui.AbsoluteSize.X / SCALE
	if sbLines == 0 or numlines < 3 or vidWidth < 512 then
		h.miniFrame.Visible = false
		h.miniSig = ""
		return
	end
	-- rebuild gate: everything below is a pure function of (scores,
	-- playerslot, teamplay, sbLines, vidWidth) — skip sort+rebuild when
	-- none changed. miniSig carries the non-gen inputs.
	local key = `{playerslot}:{teamplayNum}:{sbLines}:{vidWidth}`
	if (h :: any).miniGen == gen and h.miniSig == key then
		return
	end
	;(h :: any).miniGen = gen
	h.miniSig = key
	local teamplay = teamplayNum > 0

	-- Sbar_SortFrags(false)
	local order = qwview.sortFrags(scores, false)
	if #order == 0 then
		h.miniFrame.Visible = false
		h.miniSig = ""
		return
	end

	-- find us; spectators default to the top
	local selfAt = 0
	for i, k in order do
		if k == playerslot then
			selfAt = i
			break
		end
	end
	local first = if selfAt == 0 then 1 else selfAt - numlines // 2
	first = math.clamp(first, 1, math.max(#order - numlines + 1, 1))

	-- y = vid.height - sb_lines - 1 in canvas space (canvas is 48 tall)
	h.miniFrame.Position = UDim2.fromOffset(324 * SCALE, (48 - sbLines - 1) * SCALE)
	h.miniFrame.Visible = true
	h.miniFrame:ClearAllChildren()

	local y = 0
	for i = first, #order do
		if y >= sbLines - 8 + 1 then
			break
		end
		local k = order[i]
		local sc = scores[k]
		if sc.name == "" then
			continue
		end
		miniFill(h, 0, y + 1, 40, 3, bit32.band(sc.colors, 0xf0) + 8)
		miniFill(h, 0, y + 4, 40, 4, bit32.lshift(bit32.band(sc.colors, 15), 4) + 8)
		miniText(h, 8, y, ("%3i"):format(sc.frags))
		if k == playerslot then
			miniText(h, 0, y, string.char(16))
			miniText(h, 32, y, string.char(17))
		end
		if teamplay then
			miniText(h, 48, y, (sc.team or ""):sub(1, 4))
			miniText(h, 48 + 40, y, sc.name:sub(1, 16))
		else
			miniText(h, 48, y, sc.name:sub(1, 16))
		end
		y += 8
	end
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

	-- rebuild gate: scoresGen replaces the per-frame signature string
	local sig = if mode == "dm"
		then `{mode}:{c.scoresGen}`
		elseif mode == "sp" then `{mode}:{math.floor(c.completed_time)}`
		else mode
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

	-- Sbar_MiniDeathmatchOverlay (NQ Sbar_Draw: sb_lines > 0 + deathmatch)
	if c.gametype == 1 then
		updateMiniOverlay(h, c.scores :: { any }, c.viewentity, 0, c.scoresGen)
	else
		h.miniFrame.Visible = false
	end
end

-- QW overlay driver (Sbar_Draw + Sbar_IntermissionOverlay + finale):
-- dead or TAB raises the rankings; teamplay routes to the team overlay;
-- svc_finale (intermission 2) shows the finale plaque
function hud.updateOverlaysQW(h: Hud, c: any)
	local teamplay = (c.teamplay or 0) > 0
	local dead = (c.stats[cllib.STAT_HEALTH] or 100) <= 0 and not c.spectator
	local mode = ""
	if c.intermission == 2 then
		mode = "finale"
	elseif c.intermission ~= 0 or dead then
		mode = if teamplay and not h.showScores then "team" else "dm"
	elseif h.showScores then
		mode = "dm"
	elseif h.showTeamScores then
		mode = "team"
	end
	-- rebuild gate: scoresGen covers name/frags/colors/ping/entertime/team
	-- (the QW copy loop bumps it on any field change)
	local sig = if mode == "dm" or mode == "team" then `{mode}:{c.scoresGen or 0}` else mode
	if sig ~= h.interSig then
		h.interSig = sig
		h.interFrame:ClearAllChildren()
		if mode == "dm" then
			buildQWRankings(h, c, 0)
		elseif mode == "team" then
			buildQWTeamOverlay(h, c)
		elseif mode == "finale" then
			interLmp(h, "gfx/finale.lmp", 0, 16, true)
		end
	end
	h.interFrame.Visible = mode ~= ""

	updateMiniOverlay(h, c.scores, c.playerslot, c.teamplay or 0, c.scoresGen or 0)
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
			hidePic(h, h.armorIcon)
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
		hidePic(h, h.ammoIcon)
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
			-- position fixed at creation (i*24, 8)
		else
			hidePic(h, label)
		end
	end

	-- ibar ammo counts (small yellow conchars digits), dirty-checked per
	-- label so an unchanged count costs 4 string.sub compares
	for i = 0, 3 do
		local count = c.stats[cllib.STAT_SHELLS + i]
		local str = ("%3d"):format(math.clamp(count, 0, 999))
		for j = 0, 2 do
			local label = h.countDigits[i + 1][j + 1]
			local ch = str:sub(j + 1, j + 1)
			if h.lastDigit[label] ~= ch then
				h.lastDigit[label] = ch
				if ch ~= " " then
					local pic = charPic(h, 18 + (ch:byte() - 48))
					if pic and pic.content then
						label.ImageContent = pic.content :: Content
						label.ImageRectOffset = pic.off
						label.ImageRectSize = Vector2.new(pic.w, pic.h)
						label.Visible = true
					end
				else
					label.Visible = false
				end
			end
		end
	end

	-- items (keys + powerups): bits 17..22
	for i = 0, 5 do
		local label = h.itemIcons[i + 1]
		if bit32.band(items, bit32.lshift(1, 17 + i)) ~= 0 then
			setPic(h, label, ITEM_NAMES[i + 1], w)
			-- position fixed at creation (192 + i*16, 8)
		else
			hidePic(h, label)
		end
	end

	-- sigils: bits 28..31
	for i = 0, 3 do
		local label = h.sigilIcons[i + 1]
		if bit32.band(items, bit32.lshift(1, 28 + i)) ~= 0 then
			setPic(h, label, "sb_sigil" .. (i + 1), w)
			-- position fixed at creation (288 + i*8, 8)
		else
			hidePic(h, label)
		end
	end

	-- Sbar_DrawFrags: multiplayer, full ibar visible (sb_lines > 24)
	local fragsFrame = (h :: any).fragsFrame :: Frame
	if h.viewsize < 110 and ((c :: any).maxclients or 2) ~= 1 then
		updateFragCells(h, c.scores :: { any }, (c :: any).playerslot or c.viewentity, (c :: any).scoresGen or 0)
	elseif fragsFrame.Visible then
		fragsFrame.Visible = false
		;(h :: any).fragsGen = -1 -- force a rebuild when shown again
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
		-- hide the status-row widgets the scoreboard replaces (via hidePic
		-- so the setPic cache re-applies them when the scoreboard closes)
		hidePic(h, h.armorIcon)
		hidePic(h, h.face)
		hidePic(h, h.ammoIcon)
		for _, l in h.armorDigits do
			hidePic(h, l)
		end
		for _, l in h.healthDigits do
			hidePic(h, l)
		end
		for _, l in h.ammoDigits do
			hidePic(h, l)
		end
	else
		for _, row in h.soloRows do
			((row :: any).holder :: Frame).Visible = false
		end
	end

	-- Con_CheckResize: rebuild the notify rows when the viewport width
	-- changes the column count
	local cols = notifyColsFor(h.gui)
	if cols ~= h.notifyCols then
		h.notifyCols = cols
		buildNotifyRows(h)
		refreshNotify(h)
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
