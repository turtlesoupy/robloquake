--!strict
-- Pause menu (PRODUCT layer, NOT engine): the game's "menu" overlay opened
-- with E or the top-right MENU plaque (this file also owns the always-on
-- MENU/MAP plaques next to the director gear). The world keeps simulating
-- while it is up (Roblox multiplayer never pauses); we only drop an 80%
-- black scrim over it.
--
-- REMOVAL: delete this file plus the two attach blocks (search "pause menu"
-- in src/client/init.client.luau and src/client/qwclient.luau), the MENU
-- FONT toggle in src/client/tweaksui.luau, src/client/menuicons.luau, and
-- tools/build_menuicons.py.
--
-- Design: a fixed "content box" (836x408 design px, scaled to the viewport)
-- subdivided into cells with 12px spacers. Every page shares the same
-- title-on-top / button-on-bottom framing and picks a layout:
--   main      hero + 6 blocks   (profile, SHOP, MY SKINS, ABOUT,
--                                 FRIENDS, RANKINGS, SETTINGS)
--   settings  1 full block
--   about     1 full block      (engine origin + GPL/LibreQuake credits)
--   shop      3-up daily cards  (rarity, weapon render, FRAGS + ROBUX buttons)
--   skins     8-grid            (weapon render + APPLY, in-grid pager arrows)
--   friends   8-grid            (headshot + status + INVITE via SocialService)
--   rankings  1 full block      (period/scope tab rows + a scrolling kill
--                                 board; data from leaderboardui, L or the
--                                 RANKINGS block)
-- Cells are the Quake gfx/box_*.lmp nine-slice (border + tiled fill); cell
-- content lives INSIDE the panel frame so the press pulse scales the whole
-- card. Text is the conchars bitmap font tinted via ImageColor3 (the
-- tweaks-menu toggle swaps small cool-white "classic" — the default — for
-- large orange "plaque"). Weapon cards render the real v_rock2.mdl rocket
-- launcher with skinforge skins in a ViewportFrame, one baked mesh cloned
-- per card. The shop rotates daily: three picks (common/rare/legendary from
-- a fixed rarity split) seeded by the UTC day number, with a live countdown.
-- Clicks anywhere outside the interactive bits trigger the bottom action.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local shopcatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("shopcatalog"))
local vfslib = require(engine.common.vfs)
local wadlib = require(engine.gfx.wad)
local mdllib = require(engine.models.mdl)

local textures = require(script.Parent.render.textures)
local avatarrender = require(script.Parent.render.avatarrender)
local confontlib = require(script.Parent.render.confont)
local entrender = require(script.Parent.render.entrender)
local skinforge = require(script.Parent.render.skinforge)
local menuicons = require(script.Parent.menuicons)

local pausemenu = {}

-- design-space geometry (scaled to the viewport by a UIScale) --------------
local BOX_W, BOX_H, GAP = 836, 408, 6
-- the cell grid renders ~10% smaller than its 836x408 slot (boxes shrink,
-- gaps/title/bottom-nav keep their size), centred in the slot
local GRID_W, GRID_H = 754, 368
local GRID_X = (BOX_W - GRID_W) / 2
local TITLE_H, BTN_H = 48, 52
local BOX_Y = TITLE_H + GAP + (BOX_H - GRID_H) / 2
local CANVAS_W = BOX_W
local CANVAS_H = TITLE_H + GAP + BOX_H + GAP + BTN_H
local BOTTOM_Y = TITLE_H + GAP + BOX_H + GAP
local BOXSCALE = 2 -- each box_*.lmp pixel blown up this much
local CARD_BTN_H = 46 -- full-bleed card button height

local BOX_PIECES = { "box_tl", "box_tr", "box_bl", "box_br", "box_tm", "box_bm", "box_ml", "box_mr", "box_mm" }

local RARITY_GREY = Color3.fromRGB(150, 140, 130)
local ROBUX_GLYPH = "rbxasset://textures/ui/common/robux.png" -- built-in Roblox icon

-- The conchars glyphs are white on transparent, so ImageColor3 tints them.
-- "classic" (default) = smaller cool-white; "big" = large orange plaque.
export type FontStyle = { color: Color3, title: number, head: number, body: number }
local ORANGE = Color3.fromRGB(255, 150, 60)
local COOL = Color3.fromRGB(210, 222, 235)
local BIG_FONT: FontStyle = { color = ORANGE, title = 4, head = 2, body = 2 }
local CLASSIC_FONT: FontStyle = { color = COOL, title = 3, head = 2, body = 2 }

-- Frag Coin accents (hero-card balance line + shop balance, designer mock)
local COIN_COLOR = Color3.fromRGB(255, 70, 40)
-- rarity tiers/prices and the daily rotation live in the shared catalog
-- (src/shared/shopcatalog.luau) so the server validates what we render

export type Handle = {
	toggle: () -> (),
	isOpen: () -> boolean,
	setBigFont: (on: boolean) -> (),
	isBigFont: () -> boolean,
	setGrainyBg: (on: boolean) -> (),
	isGrainyBg: () -> boolean,
}

export type Opts = {
	playerGui: Instance,
	fs: vfslib.Vfs,
	pal: textures.Palette,
	isTyping: () -> boolean,
	onUiToggle: ((open: boolean) -> ())?,
	onReturnToGame: (() -> ())?,
	-- menu click sound (S_LocalSound misc/menu2.wav, wired by the boot)
	playSound: (() -> ())?,
	-- same hook as tweaksui: nil spec restores the authentic skin; APPLY
	-- pushes the picked skin onto every viewmodel at once
	setWeaponSkin: ((mdlName: string, spec: string?) -> ())?,
	-- the player's currently-equipped skin per viewmodel (nil = authentic);
	-- MY SKINS on the main page renders the rocket launcher's pick
	getWeaponSkin: ((mdlName: string) -> string?)?,
	-- RANKINGS page data source (leaderboardui): resolves the server's
	-- Leaderboards RemoteFunction and runs a paced fetch. A nil (or dormant)
	-- handle leaves the page showing "unavailable" — the stats pipeline is
	-- optional (see src/server/stats.luau).
	leaderboards: Leaderboards?,
	-- top-right MAP plaque / M: opens the CALL A VOTE page (proposals go
	-- to the director via directorui.Handle.cv); plaque omitted when nil
	callvote: Callvote?,
	-- SETTINGS page hooks: the menu.c M_Options rows that function on this
	-- platform (see buildSettings); the page shows a stub when nil
	settings: Settings?,
	-- AVATAR page hooks: quake shirt/pants palette rows (0..13), wired to
	-- the boot's `color` command so the tint replicates to everyone; the
	-- page shows a stub when nil
	avatarColors: { get: () -> (number, number), set: (top: number, bottom: number) -> () }?,
	-- skin economy bridge (shopclient.luau): Frag Coin balance, owned
	-- kinds, and the two purchase paths. nil = everything free (dev boots
	-- without the shop wired) — SHOP/MY SKINS fall back to plain APPLY.
	shop: Shop?,
}

-- structurally shopclient.Handle (kept local so this module doesn't
-- require the bridge that feeds it, same as Settings/Leaderboards)
export type Shop = {
	getCoins: () -> number,
	isOwned: (kind: string) -> boolean,
	buy: (kind: string, pay: "coins" | "robux") -> (boolean, string?),
	-- live managed-pricing PriceInRobux (catalog constant until fetched)
	getRobuxPrice: (rarityName: string) -> number,
	onChanged: (cb: () -> ()) -> (),
}

-- mid-game callvote bridge (structurally directorui.Handle.cv): live match
-- state for the CALL A VOTE page plus the propose action. hooks are
-- assigned by this file and fired by directorui when the server answers a
-- proposal (cvDeny reasons land in the page footer; cvBegin closes the
-- menu so the yes/no banner is usable).
export type CallvoteState = {
	map: string,
	maplist: string,
	-- file name -> menu label, e.g. "Grotto (lqdm2)" (sanitized title +
	-- codename; server-composed). Falls back to the raw name if absent.
	maptitles: { [string]: string },
	rules: { [string]: number },
	avatars: boolean,
}
export type Callvote = {
	getState: () -> CallvoteState?,
	propose: (key: string, value: any) -> (),
	hooks: { onDeny: ((reason: string) -> ())?, onBegin: (() -> ())? },
}

export type Settings = {
	getSensitivity: () -> number, -- LOOK SPEED (menu.c MOUSE SPEED), 1..11
	setSensitivity: (v: number) -> (),
	getInvertMouse: () -> boolean, -- INVERT MOUSE (m_pitch sign)
	setInvertMouse: (on: boolean) -> (),
	getAlwaysRun: () -> boolean, -- ALWAYS RUN (cl_forwardspeed 400/200)
	setAlwaysRun: (on: boolean) -> (),
	getVolume: () -> number, -- SOUND VOLUME, 0..1
	setVolume: (v: number) -> (),
}

-- RANKINGS page data source (leaderboardui): one board = a period × scope
-- pick. fetch yields (it invokes the server RemoteFunction) and returns
-- (ok, result); a false ok is a transport error, a result.disabled means the
-- server has stats switched off this session.
export type LbEntry = { userId: number, name: string, value: number }
export type LbResult = { disabled: boolean?, entries: { LbEntry }? }
-- the local player's own card for the MAIN page: all-time frags/wins plus
-- day/all-time GLOBAL kill ranks (rank nil = unranked / outside the top page)
export type LbMyStats = { frags: number, wins: number, rankDay: number?, rankAll: number?, disabled: boolean? }
export type Leaderboards = {
	ready: () -> boolean, -- the RemoteFunction has resolved
	fetch: (period: string, scope: string) -> (boolean, LbResult?),
	myStats: () -> (boolean, LbMyStats?),
}

-- every viewmodel APPLY re-skins (matches tweaksui.WEAPONS)
local VIEWMODELS = {
	"progs/v_axe.mdl",
	"progs/v_shot.mdl",
	"progs/v_shot2.mdl",
	"progs/v_nail.mdl",
	"progs/v_nail2.mdl",
	"progs/v_rock.mdl",
	"progs/v_rock2.mdl",
	"progs/v_light.mdl",
}

-- Thousands separators, e.g. 4200 -> "4,200".
local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end
pausemenu._commas = commas

-- base64 -> buffer (menu icons are baked as base64 RGBA by build_menuicons.py)
local B64: { [number]: number } = {}
do
	local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, #A do
		B64[A:byte(i)] = i - 1
	end
end
local function b64decode(s: string): buffer
	local pad = 0
	if s:sub(-1) == "=" then
		pad += 1
	end
	if s:sub(-2, -2) == "=" then
		pad += 1
	end
	local outLen = (#s // 4) * 3 - pad
	local out = buffer.create(outLen)
	local oi = 0
	for i = 1, #s, 4 do
		local n = (B64[s:byte(i)] or 0) * 262144
			+ (B64[s:byte(i + 1)] or 0) * 4096
			+ (B64[s:byte(i + 2)] or 0) * 64
			+ (B64[s:byte(i + 3)] or 0)
		if oi < outLen then
			buffer.writeu8(out, oi, math.floor(n / 65536) % 256)
			oi += 1
		end
		if oi < outLen then
			buffer.writeu8(out, oi, math.floor(n / 256) % 256)
			oi += 1
		end
		if oi < outLen then
			buffer.writeu8(out, oi, n % 256)
			oi += 1
		end
	end
	return out
end

export type BoxImg = { img: EditableImage?, w: number, h: number }

-- mirror an 8-bit (palette-index) pixel buffer horizontally and/or vertically
local function flipPixels(px: buffer, w: number, h: number, flipH: boolean, flipV: boolean): buffer
	local out = buffer.create(w * h)
	for y = 0, h - 1 do
		local sy = if flipV then h - 1 - y else y
		for x = 0, w - 1 do
			local sx = if flipH then w - 1 - x else x
			buffer.writeu8(out, y * w + x, buffer.readu8(px, sy * w + sx))
		end
	end
	return out
end

-- flipH/flipV mirror the piece, used to build the "lit" (top-left bevel) pieces
-- for the other three sides so the whole frame is lit the same way
local function loadPic(fs: vfslib.Vfs, pal: textures.Palette, name: string, flipH: boolean?, flipV: boolean?): BoxImg
	local buf = vfslib.loadFile(fs, "gfx/" .. name .. ".lmp")
	if not buf then
		return { img = nil, w = 8, h = 8 }
	end
	local pic = wadlib.parseQPic(buf)
	local px = pic.pixels
	if flipH or flipV then
		px = flipPixels(px, pic.width, pic.height, flipH == true, flipV == true)
	end
	local img = textures.createImage(px, pic.width, pic.height, pal, true)
	return { img = img, w = pic.width, h = pic.height }
end

-- one tiling/stretched slice of a nine-slice
local function slice(parent: Instance, box: BoxImg, tile: boolean, x: number, y: number, w: number, h: number)
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.ResampleMode = Enum.ResamplerMode.Pixelated
	l.Position = UDim2.fromOffset(x, y)
	l.Size = UDim2.fromOffset(w, h)
	if box.img then
		l.ImageContent = Content.fromObject(box.img)
	end
	if tile then
		l.ScaleType = Enum.ScaleType.Tile
		l.TileSize = UDim2.fromOffset(box.w * BOXSCALE, box.h * BOXSCALE)
	end
	l.Parent = parent
	return l
end

type Pieces = { [string]: BoxImg }

-- box_*.lmp border ring into `parent` (which is `w`x`h`). `center` fills the
-- middle with box_mm.
--
-- Every border piece is [bevel face][1px shadow line][2px of ITS OWN wood], and
-- that inner wood is a slightly different palette shade than box_mm -- so if the
-- centre fill only reaches the pieces' inner edge, those 2px read as a stripe
-- that stops short of the border (the artefact we kept chasing). Instead we lay
-- the whole ring down first (strips just STRETCH -- their bevel faces are
-- uniform along the strip, so no grain to distort or drift), then paint the fill
-- ON TOP of the ring's inner wood, stopping exactly at each shadow line. The
-- interior wood then runs uniformly right up to the shading on all four sides,
-- and because the ring sits underneath, the fill's edge can't open a background
-- seam. Every side uses the lit (top-left-bevel) piece -- the right/bottom are
-- the left/top pieces mirrored (see the box_*_lit_* variants) -- so the shadow
-- sits at the same depth (native index 5) all round and the inset is uniform.
local function nineSlice(
	parent: GuiObject,
	pieces: Pieces,
	w: number,
	h: number,
	center: boolean,
	trackFill: ((ImageLabel) -> ())?
)
	local cw = pieces.box_tl.w * BOXSCALE
	local ch = pieces.box_tl.h * BOXSCALE
	-- every side uses the lit pieces (mirrored onto the right/bottom), so the
	-- highlight ramp and its shadow line sit the same depth on all four sides
	slice(parent, pieces.box_tm, false, cw, 0, w - 2 * cw, ch)
	slice(parent, pieces.box_tm_lit_b, false, cw, h - ch, w - 2 * cw, ch)
	slice(parent, pieces.box_ml, false, 0, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_ml_lit_r, false, w - cw, ch, cw, h - 2 * ch)
	slice(parent, pieces.box_tl, false, 0, 0, cw, ch)
	slice(parent, pieces.box_tl_lit_tr, false, w - cw, 0, cw, ch)
	slice(parent, pieces.box_tl_lit_bl, false, 0, h - ch, cw, ch)
	slice(parent, pieces.box_tl_lit_br, false, w - cw, h - ch, cw, ch)
	if center then
		-- fill starts just past the shadow line on every side (indices 0-5 stay);
		-- symmetric now that all four sides are the same lit piece
		local ins = 6 * BOXSCALE
		local fw, fh = w - 2 * ins, h - 2 * ins
		-- clip holder: the fill sits on TOP of the ring, so its own
		-- fractional-scale ghost tile has nothing above it -- contain it here so
		-- it can't spill past the shadow line onto the bevel faces
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.ClipsDescendants = true
		holder.Position = UDim2.fromOffset(ins, ins)
		holder.Size = UDim2.fromOffset(fw, fh)
		holder.Parent = parent
		local fill = slice(holder, pieces.box_mm, true, 0, 0, fw, fh)
		if trackFill then
			trackFill(fill)
		end
	end
end

-- re-anchor a top-left-positioned element to its centre so a UIScale press
-- pulse shrinks it in place
local function centerAnchor(g: GuiObject)
	local p, s = g.Position, g.Size
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.fromOffset(p.X.Offset + s.X.Offset // 2, p.Y.Offset + s.Y.Offset // 2)
end

-- layout cells (box-local rects: x,y from the box's top-left) ---------------
type Rect = { x: number, y: number, w: number, h: number }

-- n equal columns with integer edges (the naive w=(GRID_W-gaps)/n leaves
-- fractional positions and the right edge drifts a pixel between pages)
local function cols(n: number, y: number, h: number): { Rect }
	local out = {}
	local span = GRID_W + GAP
	for i = 0, n - 1 do
		local x0 = math.round(i * span / n)
		local x1 = math.round((i + 1) * span / n) - GAP
		out[i + 1] = { x = GRID_X + x0, y = y, w = x1 - x0, h = h }
	end
	return out
end

local function layout1(): { Rect }
	return { { x = GRID_X, y = 0, w = GRID_W, h = GRID_H } }
end
local function layout2(): { Rect }
	return cols(2, 0, GRID_H)
end
local function layout3(): { Rect }
	return cols(3, 0, GRID_H)
end
local function layout8(): { Rect }
	local ch = (GRID_H - GAP) / 2
	local top = cols(4, 0, ch)
	local bottom = cols(4, ch + GAP, ch)
	return { top[1], top[2], top[3], top[4], bottom[1], bottom[2], bottom[3], bottom[4] }
end
-- wide hero (top-left, 2 cols) + 6 square blocks. cells[1] = hero, [2..3] =
-- the rest of the top row, [4..7] = the four-wide bottom row (row-major)
local function layoutHero6(): { Rect }
	local bh = (GRID_H - GAP) / 2
	local top = cols(4, 0, bh)
	local bottom = cols(4, bh + GAP, bh)
	local hero = { x = top[1].x, y = 0, w = (top[2].x + top[2].w) - top[1].x, h = bh }
	return { hero, top[3], top[4], bottom[1], bottom[2], bottom[3], bottom[4] }
end

function pausemenu.attach(opts: Opts): Handle
	local fs, pal = opts.fs, opts.pal

	-- conchars font sheet (shared with the console / HUD)
	local font: confontlib.Font? = nil
	-- BUTTON BG tweaks-menu toggle: swap the button/panel fill between the
	-- box_mm wood tile and the gfx.wad "backtile" grain HUD tiles beside the
	-- 320px sbar (SCR_TileClear, see hud.luau). Center-fill ImageLabels are
	-- tracked in fillLabels so an already-built plaque (the top MENU/MAP
	-- buttons, built once outside showPage) can be re-skinned in place.
	local grainyFill: BoxImg = { img = nil, w = 8, h = 8 }
	local fillLabels: { ImageLabel } = {}
	local grainyBg = false
	local wadbuf = vfslib.loadFile(fs, "gfx.wad")
	if wadbuf then
		local w = wadlib.load(wadbuf)
		local ok, conchars = pcall(wadlib.getRaw, w, "conchars")
		if ok then
			font = confontlib.new(conchars, pal)
		end
		local okTile, tile = pcall(wadlib.getPic, w, "backtile")
		if okTile then
			grainyFill = { img = textures.createImage(tile.pixels, tile.width, tile.height, pal, true), w = tile.width, h = tile.height }
		end
	end

	local pieces: Pieces = {}
	for _, name in BOX_PIECES do
		pieces[name] = loadPic(fs, pal, name)
	end
	local woodFill = pieces.box_mm
	local function trackFill(l: ImageLabel)
		table.insert(fillLabels, l)
	end
	-- the box art is a top-left-lit bevel: box_ml/box_tm/box_tl carry the soft
	-- highlight ramp, box_mr/box_bm/box_br only a hard shadow -- so the right and
	-- bottom edges render dark. Mirror the lit pieces onto the other sides so the
	-- whole frame is lit uniformly (right = box_ml flipped H, bottom = box_tm
	-- flipped V, and each far corner = box_tl flipped to match).
	pieces.box_ml_lit_r = loadPic(fs, pal, "box_ml", true, false)
	pieces.box_tm_lit_b = loadPic(fs, pal, "box_tm", false, true)
	pieces.box_tl_lit_tr = loadPic(fs, pal, "box_tl", true, false)
	pieces.box_tl_lit_bl = loadPic(fs, pal, "box_tl", false, true)
	pieces.box_tl_lit_br = loadPic(fs, pal, "box_tl", true, true)

	-- menu icons -> EditableImages (RGBA baked in menuicons.luau)
	local iconImg: { [string]: EditableImage? } = {}
	for name, b64 in menuicons.data do
		iconImg[name] = textures.createRGBAImage(b64decode(b64), menuicons.size, menuicons.size)
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "QuakePauseMenu"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 25
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = opts.playerGui

	-- hidden holder for the weapon template mesh (cloned into card viewports)
	local weaponHolder = Instance.new("Folder")
	weaponHolder.Name = "WeaponTemplates"
	weaponHolder.Parent = gui

	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.BorderSizePixel = 0
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.2
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = gui

	-- clicks that land on nothing interactive trigger the bottom action
	-- (RETURN TO GAME / BACK TO MENU); panels are Active so their bodies
	-- swallow clicks instead of falling through to this
	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 0
	catcher.Parent = gui

	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(CANVAS_W, CANVAS_H)
	canvas.ZIndex = 1
	canvas.Parent = gui
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = canvas
	local function fitCanvas()
		local sz = gui.AbsoluteSize
		if sz.X > 0 and sz.Y > 0 then
			uiScale.Scale = math.min(sz.X / (CANVAS_W + 48), sz.Y / (CANVAS_H + 48))
		end
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCanvas)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = canvas

	-- ---- press feedback --------------------------------------------------
	local function playClick()
		if opts.playSound then
			opts.playSound()
		end
	end
	-- shrink `visual` to 0.95 while the pointer is down on `btn`
	local function pressPulse(btn: GuiButton, visual: GuiObject)
		local sc = visual:FindFirstChildOfClass("UIScale")
		if not sc then
			local ns = Instance.new("UIScale")
			ns.Parent = visual
			sc = ns
		end
		local scale = sc :: UIScale
		btn.MouseButton1Down:Connect(function()
			scale.Scale = 0.95
		end)
		btn.MouseButton1Up:Connect(function()
			scale.Scale = 1
		end)
		btn.MouseLeave:Connect(function()
			scale.Scale = 1
		end)
	end

	-- ---- weapon template (lazy; entrender.create yields once) ----------
	local weaponDef: any = nil
	local weaponTemplate: BasePart? = nil
	local weaponTried = false
	local weaponBuilding = false
	local skinCache: { [string]: EditableImage? } = {}
	local function ensureWeapon(): BasePart?
		-- create() yields (CreateMeshPartAsync); a page built during that
		-- yield must wait for the template rather than render without guns
		while weaponBuilding do
			task.wait()
		end
		if weaponTried then
			return weaponTemplate
		end
		weaponTried = true
		weaponBuilding = true
		-- every path returns nil so the typed pcall yields the (ok, err) pair
		local ok, err = pcall(function()
			local buf = vfslib.loadFile(fs, "progs/v_rock2.mdl", true)
			if not buf then
				return nil
			end
			local am = mdllib.load("progs/v_rock2.mdl", buf)
			local def = { kind = "alias", alias = am, flags = am.flags }
			entrender.prepareImages(def :: any, pal)
			local re = entrender.create(def :: any, weaponHolder)
			if not re or not re.part then
				return nil
			end
			entrender.setLight(re, 300) -- bright bake; ViewportFrame is Ambient-only
			weaponDef = def
			weaponTemplate = re.part
			return nil
		end)
		weaponBuilding = false
		if not ok then
			warn(`[fragparty] pause-menu weapon template failed: {err}`)
		end
		return weaponTemplate
	end
	local function skinImage(spec: string): EditableImage?
		if skinCache[spec] == nil and weaponDef then
			skinCache[spec] = skinforge.createImage(spec, weaponDef.skinPixels, weaponDef.skinW, weaponDef.skinH, pal)
		end
		return skinCache[spec]
	end

	-- a weapon render (rocket launcher w/ skin) in a ViewportFrame
	-- nil spec keeps the template's authentic (baked) skin
	local function weaponView(parent: Instance, x: number, y: number, w: number, h: number, spec: string?)
		local vf = Instance.new("ViewportFrame")
		vf.BackgroundTransparency = 1
		vf.BorderSizePixel = 0
		vf.Position = UDim2.fromOffset(x, y)
		vf.Size = UDim2.fromOffset(w, h)
		vf.Ambient = Color3.new(1, 1, 1)
		vf.LightColor = Color3.new(0, 0, 0)
		vf.ZIndex = 3
		vf.Parent = parent
		local template = ensureWeapon()
		if not template then
			return
		end
		local world = Instance.new("WorldModel")
		world.Parent = vf
		local cam = Instance.new("Camera")
		cam.Parent = vf
		vf.CurrentCamera = cam
		local p = template:Clone()
		local img = if spec then skinImage(spec) else nil
		-- template may be the box-fallback Part when the Mesh API is off
		if img and p:IsA("MeshPart") then
			p.TextureContent = Content.fromObject(img)
		end
		local ext = p.Size
		local maxE = math.max(ext.X, ext.Y, ext.Z)
		-- near-profile pose (reference mockup): muzzle right, slightly
		-- toward camera and dipped; nudged left so the visual mass (the
		-- thick muzzle end sits right of the bbox centre) reads centred
		p.CFrame = CFrame.new(-maxE * 0.07, 0, 0) * CFrame.Angles(math.rad(4), math.rad(-30), math.rad(-6))
		p.Parent = world
		cam.FieldOfView = 40
		local dist = maxE * 1.3
		cam.CFrame = CFrame.lookAt(Vector3.new(0, maxE * 0.06, dist), Vector3.zero)
	end

	-- ---- text + widgets ------------------------------------------------
	local style: FontStyle = CLASSIC_FONT
	-- draw one line at (x,y); align 0 left / 0.5 centre within [x, x+wspan]
	local function text(parent: Instance, x: number, y: number, str: string, scale: number, color: Color3?, wspan: number?, align: number?): Frame
		local f = font
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(math.max(#str, 1) * 8 * scale, 8 * scale)
		local px = x
		if wspan and align then
			px = x + (wspan - #str * 8 * scale) * align
		end
		holder.Position = UDim2.fromOffset(math.floor(px), y)
		holder.ZIndex = 4
		holder.Parent = parent
		local col = color or style.color
		if f then
			local row = confontlib.newRow(holder, math.max(#str, 1), scale)
			confontlib.setRow(f, row, str)
			for _, lbl in row.labels do
				lbl.ImageColor3 = col
				lbl.ZIndex = 4
			end
		else
			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = Enum.Font.Code
			lbl.TextScaled = true
			lbl.TextColor3 = col
			lbl.Text = str
			lbl.Parent = holder
		end
		return holder
	end

	-- fixed-capacity, updatable text line (the shop countdown); centred
	-- within wspan for its full capacity so updates never move it
	local function dynamicText(parent: Instance, x: number, y: number, capacity: number, scale: number, color: Color3, wspan: number): (string) -> ()
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(capacity * 8 * scale, 8 * scale)
		holder.Position = UDim2.fromOffset(math.floor(x + (wspan - capacity * 8 * scale) / 2), y)
		holder.ZIndex = 4
		holder.Parent = parent
		local f = font
		if f then
			local row = confontlib.newRow(holder, capacity, scale)
			for _, lbl in row.labels do
				lbl.ImageColor3 = color
				lbl.ZIndex = 4
			end
			return function(s: string)
				confontlib.setRow(f, row, s)
			end
		end
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.Code
		lbl.TextScaled = true
		lbl.TextColor3 = color
		lbl.Parent = holder
		return function(s: string)
			lbl.Text = s
		end
	end

	-- lift a widget's glyphs above the button border (Sibling ZIndex)
	local function raiseZ(inst: Instance)
		for _, d in inst:GetDescendants() do
			if d:IsA("ImageLabel") or d:IsA("TextLabel") then
				(d :: any).ZIndex = 6
			end
		end
	end

	-- Bottom button strip of a card, FULL-BLEED (mockup): the card's own
	-- side/bottom borders frame the buttons. Each row is topped by a solid
	-- box_tm divider that spans the inner width and butts up against the
	-- inside face of both side borders (reading like the panel frame itself).
	-- No background wash -- the row's payment text is simply tinted orange.
	type StripRow = { label: string?, robux: number?, onClick: (() -> ())? }
	local DIVIDER = pieces.box_tm.h * BOXSCALE -- full-height (unsquashed) divider
	local function cardButtons(p: Frame, cellW: number, cellH: number, rows: { StripRow })
		local sideW = pieces.box_ml.w * BOXSCALE
		local botH = pieces.box_bl.h * BOXSCALE
		local innerX, innerW = sideW, cellW - 2 * sideW
		local top = cellH - botH - #rows * CARD_BTN_H
		for i, row in rows do
			local rowY = top + (i - 1) * CARD_BTN_H
			-- solid divider at the row top, spanning the inner width so it
			-- butts against the inside face of each side border (not over them,
			-- which would spill into the gaps between cards)
			local div = slice(p, pieces.box_tm, false, innerX, rowY, innerW, DIVIDER)
			div.ZIndex = 4
			local b = Instance.new("TextButton")
			b.AutoButtonColor = false
			b.Text = ""
			b.BorderSizePixel = 0
			b.BackgroundTransparency = 1
			b.ClipsDescendants = true
			b.Position = UDim2.fromOffset(innerX, rowY)
			b.Size = UDim2.fromOffset(innerW, CARD_BTN_H)
			b.ZIndex = 5
			b.Parent = p
			centerAnchor(b)
			pressPulse(b, b)
			local cb = row.onClick
			b.Activated:Connect(function()
				playClick()
				if cb then
					cb()
				end
			end)
			-- content centres in the region below the divider
			local cy = DIVIDER + math.floor((CARD_BTN_H - DIVIDER - 8 * style.body) / 2)
			if row.robux then
				local numStr = commas(row.robux :: number)
				local gs = 8 * style.body
				-- optional word before the glyph (e.g. "BUY [robux] 49")
				local prefix = row.label
				local prefixW = if prefix then #prefix * 8 * style.body + 6 else 0
				local total = prefixW + gs + 6 + #numStr * 8 * style.body
				local sx = math.floor((innerW - total) / 2)
				if prefix then
					raiseZ(text(b, sx, cy, prefix, style.body, ORANGE))
					sx += prefixW
				end
				local g = Instance.new("ImageLabel")
				g.BackgroundTransparency = 1
				g.Image = ROBUX_GLYPH
				g.Size = UDim2.fromOffset(gs, gs)
				g.Position = UDim2.fromOffset(sx, cy)
				g.ZIndex = 6
				g.Parent = b
				raiseZ(text(b, sx + gs + 6, cy, numStr, style.body, ORANGE))
			else
				raiseZ(text(b, 0, cy, row.label :: string, style.body, ORANGE, innerW, 0.5))
			end
		end
	end

	-- transparent click target over a rect; `visual` gets the press pulse
	local function clickable(parent: Instance, x: number, y: number, w: number, h: number, visual: GuiObject?, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.BackgroundTransparency = 1
		b.Text = ""
		b.AutoButtonColor = false
		b.Position = UDim2.fromOffset(x, y)
		b.Size = UDim2.fromOffset(w, h)
		b.ZIndex = 7
		b.Parent = parent
		if visual then
			pressPulse(b, visual)
		end
		b.Activated:Connect(function()
			playClick()
			onClick()
		end)
	end

	-- centre an icon EditableImage inside a panel (panel-local coords)
	local function iconInPanel(p: Frame, w: number, h: number, name: string)
		local img = iconImg[name]
		if not img then
			return
		end
		local side = math.min(w, h) * 0.52
		local l = Instance.new("ImageLabel")
		l.BackgroundTransparency = 1
		l.ImageContent = Content.fromObject(img)
		l.ResampleMode = Enum.ResamplerMode.Pixelated
		l.Size = UDim2.fromOffset(side, side)
		l.Position = UDim2.fromOffset((w - side) / 2, (h - side) / 2 + 12)
		l.ZIndex = 3
		l.Parent = p
	end

	-- ---- daily shop rotation --------------------------------------------
	-- picks/rarities/prices come from the shared catalog so the server
	-- validates purchases against exactly what these cards show
	local function utcDay(): number
		return os.time() // 86400
	end

	-- ---- pages ---------------------------------------------------------
	local state = "main"
	local skinPage = 0
	local friendsPage = 0
	-- SHOP page: transient purchase-result line ("NOT ENOUGH FRAGCOINS");
	-- consumed by the next buildShop so it shows exactly once
	local shopNotice: string? = nil
	-- RANKINGS page: selected tabs + last fetch. Like cvPending/friendsCache,
	-- this lives outside the build so the async fetch survives page rebuilds
	-- and re-renders when it lands. rkFetchedKey names the "period|scope" the
	-- current rkData/rkErr belongs to; rkInflightKey the one a fetch is
	-- currently chasing (both nil until the first fetch resolves).
	local rkPeriod, rkScope = "day", "mode"
	local rkGen = 0
	local rkFetchedKey: string? = nil
	local rkInflightKey: string? = nil
	local rkData: LbResult? = nil
	local rkErr = false
	local rkLastInvoke = -math.huge
	-- MAIN page personal card: the local player's persistent stats, fetched
	-- from the same Leaderboards remote (kind="me"). Lives outside the build
	-- like rkData so it survives rebuilds and re-renders when it lands; cached
	-- briefly so reopening the menu doesn't refetch every time.
	local msData: LbMyStats? = nil
	local msFetchedAt = -math.huge
	local msFetching = false
	local showPage: () -> ()
	local close: () -> ()

	-- ---- friends data (Roblox friends list + SocialService invites) -----
	-- GetFriendsAsync pages through the local player's whole friends list;
	-- PromptGameInvite opens the platform invite sheet, aimed at a single
	-- friend via ExperienceInviteOptions.InviteUser. CanSendGameInviteAsync
	-- gates the buttons (false in Studio and when the user's privacy
	-- settings disallow invites).
	type FriendInfo = { id: number, name: string, online: boolean }
	local friendsCache: { FriendInfo }? = nil
	local friendsFetchedAt = 0
	local friendsFetching = false
	local canInvite: boolean? = nil

	local function fetchFriends()
		if friendsFetching then
			return
		end
		friendsFetching = true
		task.spawn(function()
			local list: { FriendInfo } = {}
			-- GetFriendsAsync's IsOnline died in 2024 (always false); overlay
			-- GetFriendsOnline, which is privacy-filtered — friends hiding
			-- their status simply read as offline
			local onlineSet: { [number]: boolean } = {}
			pcall(function()
				for _, f in (Players.LocalPlayer :: any):GetFriendsOnline(200) :: { any } do
					if f.IsOnline ~= false then
						onlineSet[f.VisitorId] = true
					end
				end
			end)
			local ok, err = pcall(function()
				local pages = Players:GetFriendsAsync(Players.LocalPlayer.UserId)
				while true do
					for _, item in pages:GetCurrentPage() :: { any } do
						-- conchars is ASCII-only; anything else becomes "?"
						local name = tostring(item.DisplayName or item.Username or item.Id)
						table.insert(list, {
							id = item.Id :: number,
							name = (name:upper():gsub("[^\32-\126]", "?")),
							online = onlineSet[item.Id :: number] == true,
						})
					end
					if pages.IsFinished then
						break
					end
					pages:AdvanceToNextPageAsync()
				end
			end)
			-- GetFriendsAsync's page order is arbitrary; online friends are
			-- the ones you'd actually invite, so they sort first
			table.sort(list, function(a, b)
				if a.online ~= b.online then
					return a.online
				end
				return a.name < b.name
			end)
			if not ok then
				warn(`[fragparty] friends list fetch failed: {err}`)
			end
			friendsCache = if ok then list else (friendsCache or {})
			friendsFetchedAt = os.clock()
			if canInvite == nil then
				local okc, can = pcall(function()
					return SocialService:CanSendGameInviteAsync(Players.LocalPlayer)
				end)
				canInvite = okc and can == true
			end
			friendsFetching = false
			if state == "friends" and gui.Enabled then
				task.defer(showPage)
			end
		end)
	end

	-- nil userId opens the untargeted invite sheet (friend picker)
	local function promptInvite(userId: number?)
		task.spawn(function()
			local ok, err = pcall(function()
				local inviteOpts = Instance.new("ExperienceInviteOptions")
				if userId then
					inviteOpts.InviteUser = userId
				end
				SocialService:PromptGameInvite(Players.LocalPlayer, inviteOpts)
			end)
			if not ok then
				warn(`[fragparty] game invite prompt failed: {err}`)
			end
		end)
	end

	-- a cell's box panel; Active so its body swallows clicks (instead of
	-- falling through to the outside-click catcher)
	local function cellPanel(cell: Rect): Frame
		local f = Instance.new("Frame")
		f.BackgroundTransparency = 1
		f.Active = true
		-- tiled slices at fractional UIScale can paint a partial extra tile
		-- beyond the frame (ghost lines in the gaps); clip them
		f.ClipsDescendants = true
		f.Position = UDim2.fromOffset(cell.x, BOX_Y + cell.y)
		f.Size = UDim2.fromOffset(cell.w, cell.h)
		f.Parent = content
		centerAnchor(f)
		nineSlice(f, pieces, cell.w, cell.h, true, trackFill)
		return f
	end

	-- pull the local player's personal card once per menu-open (cached ~20s).
	-- Paced by the server's per-player cooldown; re-renders MAIN when it lands.
	local function myStatsFetch()
		local lb = opts.leaderboards
		if not lb or not lb.ready() or msFetching then
			return
		end
		if os.clock() - msFetchedAt < 20 then
			return -- still fresh
		end
		msFetching = true
		task.spawn(function()
			local ok, res = lb.myStats()
			msFetching = false
			if ok and typeof(res) == "table" then
				msData = res
				msFetchedAt = os.clock()
				if state == "main" and gui.Enabled then
					task.defer(showPage)
				end
			end
		end)
	end

	-- ---- avatar tint preview machinery (AVATAR page + main-page hero) ----
	-- Quake shirt/pants palette rows plus the avatarrender template rig the
	-- previews clone. The template is created ONCE into workspace (create
	-- ScaleTo's a parked humanoid rig — only safe there, see avatarrender),
	-- re-tinted with the same palette-row math avatarlayer uses, and cloned
	-- inert into a page's ViewportFrame.
	local QUAKE_COLOR_NAMES = {
		"WHITE", "BROWN", "LAVENDER", "KHAKI", "RED", "OLIVE", "ORANGE",
		"PEACH", "PURPLE", "MAGENTA", "TAN", "GREEN", "YELLOW", "BLUE",
	}
	local function quakeRowColor(row: number): Color3 -- palette row 0..13
		local base = row * 16
		local idx = base + (if base < 128 then 11 else 4)
		return Color3.fromRGB(pal.r[idx + 1], pal.g[idx + 1], pal.b[idx + 1])
	end
	local avatarPreviewEnt: avatarrender.AvatarEnt? = nil
	local function ensureAvatarPreview(): Model?
		if not avatarPreviewEnt then
			local holder = Instance.new("Folder")
			holder.Name = "QuakeMenuAvatarPreview"
			holder.Parent = workspace
			avatarPreviewEnt = avatarrender.create(Players.LocalPlayer.UserId, holder)
		end
		local ae = avatarPreviewEnt
		return if ae and not ae.loading then ae.model else nil
	end
	-- clone of the template carrying the CURRENT tint (nil while the rig
	-- is still replicating). Byte 0 = untinted in the live pipeline
	-- (avatarlayer passes nil,nil); mirrored so previews match what
	-- other players see.
	local function tintedAvatarClone(): Model?
		local model = ensureAvatarPreview()
		local ae = avatarPreviewEnt
		if not model or not ae then
			return nil
		end
		local ac = opts.avatarColors
		if ac then
			local top, bottom = ac.get()
			if top == 0 and bottom == 0 then
				avatarrender.setTeamColors(ae, nil, nil)
			else
				avatarrender.setTeamColors(ae, quakeRowColor(top), quakeRowColor(bottom))
			end
		end
		return model:Clone()
	end
	-- drop a tinted-rig viewport into a panel; false = rig not ready yet
	local function avatarViewport(parent: Frame, x: number, y: number, w: number, h: number): boolean
		local clone = tintedAvatarClone()
		if not clone then
			return false
		end
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.Ambient = Color3.new(1, 1, 1)
		vp.LightColor = Color3.new(0, 0, 0)
		vp.Position = UDim2.fromOffset(x, y)
		vp.Size = UDim2.fromOffset(w, h)
		vp.ZIndex = 3
		vp.Parent = parent
		local wm = Instance.new("WorldModel")
		wm.Parent = vp
		clone:PivotTo(CFrame.new(0, 0, 0))
		clone.Parent = wm
		local cf, size = clone:GetBoundingBox()
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		local dist = math.max(size.Y, size.X, 1) * 2.1
		cam.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * dist, cf.Position)
		cam.Parent = vp
		vp.CurrentCamera = cam
		return true
	end

	local function buildMain()
		local cells = layoutHero6()
		local hero = cells[1]

		-- hero: the local player's profile card, click -> skins. Name across
		-- the top, avatar headshot on the right, persistent stats stacked at
		-- the left (frags/wins + today/all-time kill ranks). Numbers show "--"
		-- until the async kind="me" fetch lands (see myStatsFetch).
		local hp = cellPanel(hero)
		myStatsFetch()
		local me = Players.LocalPlayer
		local pad = 20
		local ns = style.head
		local nameMax = math.max(1, (hero.w - 2 * pad) // (8 * ns))
		local nm = me.DisplayName:upper():gsub("[^\32-\126]", "?")
		if #nm > nameMax then
			nm = nm:sub(1, nameMax)
		end
		text(hp, pad, 16, nm, ns)

		-- avatar: right side, below the name line — the tinted rig preview,
		-- so the quake shirt/pants pick shows here too. Falls back to the
		-- flat full-body thumbnail (which can't tint, but matches the rig's
		-- framing) while the rig replicates.
		local bodyTop = 16 + 8 * ns + 12
		local avSide = math.min(hero.h - bodyTop - 16, math.floor(hero.w * 0.3))
		if not avatarViewport(hp, hero.w - avSide - 16, bodyTop, avSide, avSide) then
			local av = Instance.new("ImageLabel")
			av.BackgroundTransparency = 1
			av.Image = `rbxthumb://type=Avatar&id={me.UserId}&w=180&h=180`
			av.Size = UDim2.fromOffset(avSide, avSide)
			av.Position = UDim2.fromOffset(hero.w - avSide - 16, bodyTop)
			av.ZIndex = 3
			av.Parent = hp
		end

		-- stat lines, left column (kept clear of the avatar). A touch smaller
		-- than body so "RANK #NN ALL TIME" fits beside the headshot. The Frag
		-- Coin balance leads in red (designer mock) — live off the RQCoins
		-- attribute, so no fetch needed.
		local ms = msData
		local function rankLine(r: number?, period: string): string
			if not ms or ms.disabled then
				return `RANK -- {period}`
			end
			return if r then `RANK #{r} {period}` else `UNRANKED {period}`
		end
		local function numLine(n: number?, label: string): string
			return if ms and not ms.disabled then `{commas(n or 0)} {label}` else `-- {label}`
		end
		local rows: { { s: string, c: Color3? } } = {}
		if opts.shop then
			table.insert(rows, { s = `{commas(opts.shop.getCoins())} FRAGCOINS`, c = COIN_COLOR })
		end
		table.insert(rows, { s = rankLine(ms and ms.rankDay, "TODAY") })
		table.insert(rows, { s = rankLine(ms and ms.rankAll, "ALL TIME") })
		table.insert(rows, { s = numLine(ms and ms.frags, "FRAGS") })
		table.insert(rows, { s = numLine(ms and ms.wins, "WINS") })
		local ss = 1.5
		local lineH = 8 * ss + 8
		local sy = bodyTop + math.max(0, (avSide - #rows * lineH) // 2)
		for _, line in rows do
			text(hp, pad + 2, sy, line.s, ss, line.c)
			sy += lineH
		end
		-- the stats/profile card opens the AVATAR tint subscreen
		clickable(content, hero.x, BOX_Y + hero.y, hero.w, hero.h, hp, function()
			state = "avatar"
			showPage()
		end)

		-- the rocket launcher render on MY SKINS follows the equipped pick
		-- (nil = authentic); the picture updates when APPLY rebuilds this page
		local equipped = if opts.getWeaponSkin then opts.getWeaponSkin("progs/v_rock2.mdl") else nil
		local legendary = shopcatalog.picks(utcDay())[3]
		-- one action per block: `go` switches to that page; a cell shows either
		-- a baked icon or a weapon render (skin=true keeps MY SKINS rendering
		-- the authentic gun when nothing is equipped)
		type HubCell = { label: string, go: string, icon: string?, weapon: string?, skin: boolean?, big: string? }
		local defs: { HubCell } = {
			{ label = "SHOP", weapon = legendary.spec, go = "shop" }, -- cells[2]
			{ label = "MY SKINS", weapon = equipped, skin = true, go = "skins" }, -- cells[3]
			{ label = "ABOUT", big = "1996", go = "about" }, -- cells[4]
			{ label = "FRIENDS", icon = "friends", go = "friends" }, -- cells[5]
			{ label = "RANKINGS", icon = "leaderboard", go = "rankings" }, -- cells[6]
			{ label = "SETTINGS", icon = "settings", go = "settings" }, -- cells[7]
		}
		for i, d in defs do
			local cell = cells[i + 1]
			local p = cellPanel(cell)
			-- block labels are centred (mockup), unlike the hero's header
			text(p, 0, 16, d.label, style.head, nil, cell.w, 0.5)
			if d.icon then
				iconInPanel(p, cell.w, cell.h, d.icon)
			elseif d.big then
				-- text-only tile (ABOUT): big conchar year, centred in the
				-- icon area below the label
				local bs = 4
				text(p, 0, 16 + math.floor((cell.h - 16 - 8 * bs) / 2), d.big, bs, RARITY_GREY, cell.w, 0.5)
			elseif d.weapon or d.skin then
				-- MY SKINS always renders (authentic when nothing equipped)
				weaponView(p, 10, 30, cell.w - 20, cell.h - 40, d.weapon)
			end
			clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, function()
				local go = d.go
				if not go then
					return
				end
				state = go
				if go == "friends" then
					friendsPage = 0
				elseif go == "skins" then
					skinPage = 0
				elseif go == "rankings" then
					rkFetchedKey, rkData = nil, nil -- refetch fresh on entry
				end
				showPage()
			end)
		end
	end

	-- The menu.c M_Options screen LibreQuake ships, restyled into one cell:
	-- label column right-aligned at the panel midline, widget column to the
	-- right. Sliders draw the authentic conchars rail (128 cap / 129 rail /
	-- 130 cap, knob 131 travelling SLIDER_RANGE-1 cells, M_DrawSlider) with
	-- < > hotspots stepping like the arrow keys (M_AdjustSliders); toggles
	-- show ON/OFF. Every change rebuilds the page, like the skins pager.
	-- Renames from the original: MOUSE SPEED reads LOOK SPEED. Rows
	-- omitted: BRIGHTNESS (gamma is fixed on this platform), CD MUSIC (no
	-- music track in the bank), SCREEN SIZE (product call — the console's
	-- viewsize/sizeup/sizedown still work), LOOKSPRING and LOOKSTRAFE
	-- (meaningless under always-mouselook), CUSTOMIZE CONTROLS / GO TO
	-- CONSOLE / VIDEO OPTIONS (separate systems here).
	local SLIDER_RANGE = 10 -- menu.c
	local function buildSettings()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		local maybe = opts.settings
		if not maybe then
			text(p, 0, cell.h / 2 - 8 * style.body, "SETTINGS COMING SOON", style.body, RARITY_GREY, cell.w, 0.5)
			return
		end
		-- rebind under a concrete type: closures below capture it, and the
		-- old solver drops ?-refinements at closure boundaries
		local s: Settings = maybe

		local WHITE = Color3.new(1, 1, 1)
		local bs = 8 * style.body -- glyph size at body scale
		local rowH = 46
		local y0 = math.floor((cell.h - 5 * rowH) / 2)
		local labelR = math.floor(cell.w / 2) - 12 -- labels right-align here
		local widgetX = math.floor(cell.w / 2) + 12

		-- panel-local click target that applies `fn` then redraws the page
		local function hot(lx: number, ly: number, w: number, h: number, visual: GuiObject?, fn: () -> ())
			clickable(content, cell.x + lx, BOX_Y + cell.y + ly, w, h, visual, function()
				fn()
				showPage()
			end)
		end

		local ri = 0
		local function rowY(): number
			local ry = y0 + ri * rowH
			ri += 1
			return ry
		end
		local function label(ry: number, str: string)
			text(p, labelR - #str * bs, ry + (rowH - bs) // 2, str, style.body)
		end

		local function sliderRow(name: string, get: () -> number, set: (v: number) -> (), min: number, max: number, step: number)
			local ry = rowY()
			label(ry, name)
			local ty = ry + (rowH - bs) // 2
			local railX = widgetX + bs + 8
			local railW = (SLIDER_RANGE + 2) * bs
			local arrowL = text(p, widgetX, ty, "<", style.body, WHITE)
			-- rail glyphs carry their own palette colors; no tint
			text(p, railX, ty, string.char(128) .. string.rep(string.char(129), SLIDER_RANGE) .. string.char(130), style.body, WHITE)
			local frac = math.clamp((get() - min) / (max - min), 0, 1)
			text(p, railX + bs + frac * (SLIDER_RANGE - 1) * bs, ty, string.char(131), style.body, WHITE)
			local arrowR = text(p, railX + railW + 8, ty, ">", style.body, WHITE)
			hot(widgetX - 8, ry, bs + 16, rowH, arrowL, function()
				set(math.clamp(get() - step, min, max))
			end)
			hot(railX + railW, ry, bs + 16, rowH, arrowR, function()
				set(math.clamp(get() + step, min, max))
			end)
		end

		local function toggleRow(name: string, get: () -> boolean, set: (on: boolean) -> ())
			local ry = rowY()
			label(ry, name)
			local t = text(p, widgetX, ry + (rowH - bs) // 2, if get() then "ON" else "OFF", style.body, WHITE)
			hot(widgetX - 8, ry, 3 * bs + 16, rowH, t, function()
				set(not get())
			end)
		end

		sliderRow("LOOK SPEED", s.getSensitivity, s.setSensitivity, 1, 11, 0.5)
		toggleRow("INVERT MOUSE", s.getInvertMouse, s.setInvertMouse)
		toggleRow("ALWAYS RUN", s.getAlwaysRun, s.setAlwaysRun)
		sliderRow("SOUND VOLUME", s.getVolume, s.setVolume, 0, 1, 0.1)

		-- menu.c RESET TO DEFAULTS (default.cfg values: volume 0.7 included,
		-- since the boot execs it too)
		local ry = rowY()
		local rlabel = "RESET TO DEFAULTS"
		local rt = text(p, 0, ry + (rowH - bs) // 2, rlabel, style.body, ORANGE, cell.w, 0.5)
		hot((cell.w - #rlabel * bs) // 2 - 8, ry, #rlabel * bs + 16, rowH, rt, function()
			s.setSensitivity(3)
			s.setInvertMouse(false)
			s.setAlwaysRun(false)
			s.setVolume(0.7)
		end)
	end

	-- CALL A VOTE (mid-game callvote; wire protocol in directorui.luau): the
	-- propose panel restyled like the settings page — one row per proposal,
	-- label right-aligned at the midline, a < value > stepper widget.
	-- Touching a stepper arms that row (its value shows orange) and the big
	-- VOTE line at the bottom (RESET TO DEFAULTS treatment) fires it; the
	-- server answers with the yes/no banner vote, or a deny reason shown
	-- under the VOTE line. Every click rebuilds the page (like settings),
	-- so pending stepper values live outside the build; openCallVote
	-- resets them.
	local cvPending: { [string]: number } = {}
	local cvMapIdx = 0 -- 1-based maplist index; 0 = re-pick the default
	local cvSelected: string? = nil -- armed row (proposal key); nil = default
	local cvDeny: string? = nil -- last server deny reason
	local function buildCallVote()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		local cv = opts.callvote
		local st = if cv then cv.getState() else nil
		if not cv or not st then
			text(p, 0, cell.h / 2 - 8 * style.body, "VOTING UNAVAILABLE", style.body, RARITY_GREY, cell.w, 0.5)
			return
		end

		local maps: { string } = {}
		for name in st.maplist:gmatch("%S+") do
			table.insert(maps, name)
		end

		if cvSelected == nil then
			cvSelected = if #maps > 0 then "map" else "fraglimit"
		end

		local WHITE = Color3.new(1, 1, 1)
		local bs = 8 * style.body -- glyph size at body scale
		local rowH = 46
		local rows = (if #maps > 0 then 1 else 0) + 2 + 1 -- + rules + VOTE
		local y0 = math.floor((cell.h - rows * rowH) / 2)
		local labelR = math.floor(cell.w / 2) - 12 -- labels right-align here
		local widgetX = math.floor(cell.w / 2) + 12
		-- shared widget geometry so the < > arrows align across rows. The
		-- value field is wide (arrows sit near the cell edges, not hugging
		-- the value) so long level names fit; short values just centre in it.
		local valueX = widgetX + bs + 8
		local arrowRX = cell.w - bs - 24
		local span = arrowRX - 8 - valueX
		local maxValueChars = math.floor(span / bs)

		-- panel-local click target that applies `fn` then redraws the page
		local function hot(lx: number, ly: number, w: number, h: number, visual: GuiObject?, fn: () -> ())
			clickable(content, cell.x + lx, BOX_Y + cell.y + ly, w, h, visual, function()
				fn()
				showPage()
			end)
		end

		local ri = 0
		local function rowY(): number
			local ry = y0 + ri * rowH
			ri += 1
			return ry
		end
		local function label(ry: number, str: string)
			text(p, labelR - #str * bs, ry + (rowH - bs) // 2, str, style.body)
		end
		-- a < value > stepper: draw the current value, wire the arrows.
		-- Touching either arrow arms this row as the proposal VOTE fires;
		-- the armed row's value shows orange, `dim` (the current map) grey.
		local function stepper(ry: number, key: string, value: string, dim: boolean, dec: () -> (), inc: () -> ())
			local ty = ry + (rowH - bs) // 2
			local color = if cvSelected == key then ORANGE elseif dim then RARITY_GREY else WHITE
			if #value > maxValueChars then -- a long level name; clip to the field
				value = value:sub(1, maxValueChars)
			end
			local arrowL = text(p, widgetX, ty, "<", style.body, WHITE)
			text(p, valueX, ty, value, style.body, color, span, 0.5)
			local arrowR = text(p, arrowRX, ty, ">", style.body, WHITE)
			hot(widgetX - 8, ry, bs + 16, rowH, arrowL, function()
				cvSelected = key
				dec()
			end)
			hot(arrowRX - 8, ry, bs + 16, rowH, arrowR, function()
				cvSelected = key
				inc()
			end)
		end

		if #maps > 0 then
			if cvMapIdx < 1 or cvMapIdx > #maps then
				cvMapIdx = 1
				for i, name in maps do -- default to the next map in rotation
					if name ~= st.map then
						cvMapIdx = i
						break
					end
				end
			end
			local ry = rowY()
			label(ry, "LEVEL")
			local name = maps[cvMapIdx]
			-- server-composed menu label ("<title> (<codename>)"); the raw
			-- file name is the fallback when no label was supplied
			local shown = (st.maptitles[name] or name):upper()
			-- the current map shows greyed (a same-map proposal is pointless)
			stepper(ry, "map", shown, name == st.map, function()
				cvMapIdx = (cvMapIdx - 2) % #maps + 1
			end, function()
				cvMapIdx = cvMapIdx % #maps + 1
			end)
		end

		local function ruleRow(name: string, key: string, step: number)
			local ry = rowY()
			label(ry, name)
			if cvPending[key] == nil then
				cvPending[key] = tonumber(st.rules[key]) or 0
			end
			stepper(ry, key, tostring(cvPending[key]), false, function()
				cvPending[key] = math.max(0, cvPending[key] - step)
			end, function()
				cvPending[key] += step
			end)
		end
		ruleRow("FRAGLIMIT", "fraglimit", 5)
		ruleRow("TIMELIMIT", "timelimit", 5)

		-- the single VOTE line (RESET TO DEFAULTS treatment): fires the
		-- armed row's proposal; the redraw clears any stale deny text
		local vy = rowY()
		local vlabel = "VOTE"
		local vt = text(p, 0, vy + (rowH - bs) // 2, vlabel, style.body, ORANGE, cell.w, 0.5)
		hot((cell.w - #vlabel * bs) // 2 - 8, vy, #vlabel * bs + 16, rowH, vt, function()
			cvDeny = nil
			if cvSelected == "map" and maps[cvMapIdx] then
				cv.propose("map", maps[cvMapIdx])
			elseif cvSelected then
				cv.propose(cvSelected, cvPending[cvSelected])
			end
		end)

		-- the server's last deny reason sits under the VOTE line
		if cvDeny then
			text(p, 0, y0 + rows * rowH + 6, cvDeny:upper(), style.body, RARITY_GREY, cell.w, 0.5)
		end
	end

	-- ABOUT: what this is and whose work it stands on. Engine port of the
	-- 1996 Quake source (GPLv2); shipped game content is LibreQuake (BSD).
	local function buildAbout()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		local lines: { { s: string, c: Color3? } } = {
			{ s = "THIS IS THE ORIGINAL 1996 QUAKE ENGINE" },
			{ s = "BY ID SOFTWARE, RUNNING IN ROBLOX." },
			{ s = "" },
			{ s = "ENGINE: PORTED FROM ID'S QUAKE SOURCE,", c = RARITY_GREY },
			{ s = "RELEASED UNDER THE GNU GPL V2.", c = RARITY_GREY },
			{ s = "GAME CONTENT: THE LIBREQUAKE PROJECT,", c = RARITY_GREY },
			{ s = "BSD-LICENSED COMMUNITY-MADE ASSETS.", c = RARITY_GREY },
			{ s = "" },
			{ s = "QUAKE IS A TRADEMARK OF ID SOFTWARE.", c = RARITY_GREY },
			{ s = "THIS PROJECT IS NOT AFFILIATED WITH ID.", c = RARITY_GREY },
		}
		local lineH = 8 * style.body + 12
		local y = math.floor((cell.h - #lines * lineH) / 2)
		for _, line in lines do
			if line.s ~= "" then
				text(p, 0, y, line.s, style.body, line.c, cell.w, 0.5)
			end
			y += lineH
		end
	end

	-- purchase-failure codes (shop.luau / shopclient.luau) -> card footer text
	local NOTICES: { [string]: string } = {
		POOR = "NOT ENOUGH FRAGCOINS",
		LOADING = "WALLET STILL LOADING - TRY AGAIN",
		NOPRODUCT = "ROBUX PURCHASES COMING SOON",
		SLOW = "EASY THERE - TRY AGAIN",
		OFFLINE = "SHOP OFFLINE - TRY AGAIN",
	}
	local function noticeFor(err: string?): string
		return NOTICES[err or ""] or "PURCHASE FAILED - TRY AGAIN"
	end

	local function buildShop()
		local day = utcDay()
		local picks = shopcatalog.picks(day)
		local shop = opts.shop
		local notice = shopNotice
		shopNotice = nil -- show once; the next rebuild clears it
		for i, cell in layout3() do
			local pick = picks[i]
			local rarity = shopcatalog.RARITIES[pick.rarity]
			local p = cellPanel(cell)
			text(p, 0, 14, pick.kind:upper(), style.head, nil, cell.w, 0.5)
			text(p, 0, 14 + 8 * style.head + 6, pick.rarity, style.body, RARITY_GREY, cell.w, 0.5)
			local owned = if shop then shop.isOwned(pick.kind) else true
			local equipped = (if opts.getWeaponSkin then opts.getWeaponSkin("progs/v_rock2.mdl") else nil)
				== pick.spec
			-- equip this card's featured spec on every viewmodel
			local function apply()
				if opts.setWeaponSkin then
					for _, mdl in VIEWMODELS do
						opts.setWeaponSkin(mdl, pick.spec)
					end
				end
			end
			local function applyAndRefresh()
				apply()
				showPage() -- EQUIP flips to EQUIPPED
			end
			-- purchases resolve async; success re-renders via the wallet
			-- attribute change (opts.shop.onChanged), failures via shopNotice
			local function buyCoins()
				task.spawn(function()
					local ok, err = (shop :: Shop).buy(pick.kind, "coins")
					if ok then
						apply() -- wear it right away
					else
						shopNotice = noticeFor(err)
					end
					if state == "shop" and gui.Enabled then
						task.defer(showPage)
					end
				end)
			end
			local function buyRobux()
				task.spawn(function()
					local ok, err = (shop :: Shop).buy(pick.kind, "robux")
					-- on ok the platform prompt is up; the receipt lands as
					-- an attribute change and onChanged rebuilds this page
					if not ok then
						shopNotice = noticeFor(err)
						if state == "shop" and gui.Enabled then
							task.defer(showPage)
						end
					end
				end)
			end
			-- owned: one EQUIP/EQUIPPED row. Unowned: the two payment rows
			-- from the mock — "<value> FRAGCOINS" over the [robux glyph] price.
			local rows: { StripRow } = if owned
				then {
					{
						label = if equipped then "EQUIPPED" else "EQUIP",
						onClick = if equipped then nil else applyAndRefresh,
					},
				}
				else {
					{ label = `{commas(rarity.coins)} FRAGCOINS`, onClick = buyCoins },
					-- live price when the shop is wired (managed pricing);
					-- rarity.robux only on shop-less dev boots
					{
						robux = if shop then shop.getRobuxPrice(pick.rarity) else rarity.robux,
						onClick = buyRobux,
					},
				}
			-- weapon render fills the middle, above the price/equip strip
			weaponView(p, 12, 64, cell.w - 24, cell.h - 64 - (#rows * CARD_BTN_H + 22), pick.spec)
			cardButtons(p, cell.w, cell.h, rows)
			-- whole-card click target (behind the render/button strip): equips
			-- when owned; buying stays on the explicit price buttons so a
			-- stray card tap can't spend currency
			if owned then
				clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, applyAndRefresh)
			end
		end
		-- Frag Coin balance, right-aligned beside the countdown line (mock red)
		if shop then
			text(content, 0, TITLE_H - 8, `{commas(shop.getCoins())} FRAGCOINS`, 1.5, COIN_COLOR, CANVAS_W - GRID_X, 1)
		end
		if notice then
			-- a purchase notice borrows the countdown slot for one rebuild
			text(content, 0, TITLE_H - 8, notice, style.body, ORANGE, CANVAS_W, 0.5)
			task.delay(4, function()
				if state == "shop" and gui.Enabled then
					task.defer(showPage) -- restore the countdown
				end
			end)
			return
		end
		-- countdown under the title; rebuilds the page when the day rolls
		-- over (swapping in the next three picks)
		local setTimer = dynamicText(content, 0, TITLE_H - 8, 15, style.body, RARITY_GREY, CANVAS_W)
		local alive = content:FindFirstChildOfClass("Frame") -- any page child: dies on rebuild
		task.spawn(function()
			while alive and alive.Parent do
				local now = os.time()
				if now // 86400 ~= day then
					if state == "shop" and gui.Enabled then
						task.defer(showPage)
					end
					break
				end
				local rem = 86400 - now % 86400
				setTimer(string.format("RESETS IN %02d:%02d", rem // 3600, (rem % 3600) // 60))
				task.wait(1)
			end
		end)
	end

	-- ---- shared 8-grid pager (skins + friends) ---------------------------
	-- in-grid pager (mockup): past page 0 the first cell is a back arrow,
	-- and while items remain the cell after the last item is a forward
	-- arrow; unused cells sit as dark empty slots. pagerSplit returns each
	-- page's first item index and item count under that displacement.
	local function pagerSplit(n: number, cellCount: number): ({ number }, { number })
		local starts, counts = { 1 }, {}
		if n <= cellCount then
			counts[1] = n
		else
			counts[1] = cellCount - 1 -- page 0: items + forward arrow
			local start = cellCount
			while true do
				table.insert(starts, start)
				local rem = n - start + 1
				if rem <= cellCount - 1 then
					table.insert(counts, rem) -- last page: back arrow + rest
					break
				end
				table.insert(counts, cellCount - 2) -- middle: back + items + fwd
				start += cellCount - 2
			end
		end
		return starts, counts
	end
	local function arrowCell(cell: Rect, glyph: string, onClick: () -> ())
		local p = cellPanel(cell)
		text(p, 0, math.floor((cell.h - 8 * 5) / 2), glyph, 5, Color3.new(1, 1, 1), cell.w, 0.5)
		clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, onClick)
	end
	local function emptyCell(cell: Rect)
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.Active = true
		f.BackgroundColor3 = Color3.fromRGB(16, 10, 8)
		f.BackgroundTransparency = 0.45
		f.Position = UDim2.fromOffset(cell.x, BOX_Y + cell.y)
		f.Size = UDim2.fromOffset(cell.w, cell.h)
		f.ZIndex = 2
		f.Parent = content
	end

	local function buildSkins()
		local cells = layout8()
		local shop = opts.shop
		-- the locker: the free AUTHENTIC default first, then every OWNED kind
		-- with its rarity status. Without the shop bridge (dev boots) every
		-- kind shows, preserving the old free-apply behavior.
		type SkinEntry = { kind: string?, name: string, rarity: string }
		local list: { SkinEntry } = { { kind = nil, name = "AUTHENTIC", rarity = "DEFAULT" } }
		for _, kind in skinforge.kinds() do -- sorted, stable order
			if not shop or shop.isOwned(kind) then
				local r = shopcatalog.rarityOf(kind)
				table.insert(list, { kind = kind, name = kind:upper(), rarity = if r then r.name else "SPECIAL" })
			end
		end
		local n = #list
		local starts, counts = pagerSplit(n, #cells)
		skinPage = math.clamp(skinPage, 0, #starts - 1)
		local first = starts[skinPage + 1]
		local count = counts[skinPage + 1]

		-- the equipped pick (kind granularity: any seed of a kind counts)
		local current = if opts.getWeaponSkin then opts.getWeaponSkin("progs/v_rock2.mdl") else nil
		local eqKind = if current then current:match("^(%a+)") else nil

		local function skinCell(cell: Rect, entry: SkinEntry)
			local p = cellPanel(cell)
			local sc = if #entry.name * 8 * style.head <= cell.w - 12 then style.head else 1
			text(p, 0, 14, entry.name, sc, nil, cell.w, 0.5)
			-- rarity status line (mock): grey, under the name
			text(p, 0, 14 + 8 * sc + 4, entry.rarity, 1, RARITY_GREY, cell.w, 0.5)
			local spec = if entry.kind then `{entry.kind}:7` else nil
			local viewTop = 14 + 8 * sc + 16
			weaponView(p, 8, viewTop, cell.w - 16, cell.h - viewTop - (CARD_BTN_H + 14), spec)
			local equipped = if entry.kind then entry.kind == eqKind else current == nil
			local function apply()
				if opts.setWeaponSkin then
					for _, mdl in VIEWMODELS do
						opts.setWeaponSkin(mdl, spec)
					end
				end
				showPage() -- APPLY flips to EQUIPPED
			end
			cardButtons(p, cell.w, cell.h, {
				{ label = if equipped then "EQUIPPED" else "APPLY", onClick = if equipped then nil else apply },
			})
			-- whole-card click target (behind the render/button strip), same
			-- pattern as buildShop's card-wide apply
			if not equipped then
				clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, apply)
			end
		end
		local ci = 1
		if skinPage > 0 then
			arrowCell(cells[ci], "<", function()
				skinPage -= 1
				showPage()
			end)
			ci += 1
		end
		for k = 0, count - 1 do
			skinCell(cells[ci], list[first + k])
			ci += 1
		end
		if first + count - 1 < n then
			arrowCell(cells[ci], ">", function()
				skinPage += 1
				showPage()
			end)
			ci += 1
		end
		while ci <= #cells do
			emptyCell(cells[ci])
			ci += 1
		end
		-- nudge fresh players toward the shop while the locker is empty
		if shop and n == 1 then
			text(content, 0, TITLE_H - 8, "BUY SKINS IN THE SHOP WITH FRAGCOINS", style.body, RARITY_GREY, CANVAS_W, 0.5)
		end
	end

	local function buildFriends()
		-- first visit fetches in the background (placeholder below); later
		-- visits show the cache and quietly refresh it when >60s old, the
		-- fetch rebuilding this page as it lands
		if friendsCache == nil or os.clock() - friendsFetchedAt > 60 then
			fetchFriends()
		end
		local friends = friendsCache
		if friends == nil then
			local cell = layout1()[1]
			local p = cellPanel(cell)
			text(p, 0, cell.h / 2 - 8 * style.body, "LOADING FRIENDS...", style.body, RARITY_GREY, cell.w, 0.5)
			return
		end
		if #friends == 0 then
			local cell = layout1()[1]
			local p = cellPanel(cell)
			text(p, 0, cell.h / 2 - 8 * style.body, "NO FRIENDS FOUND", style.body, RARITY_GREY, cell.w, 0.5)
			if canInvite then
				-- untargeted sheet still works: Roblox suggests people there
				cardButtons(p, cell.w, cell.h, {
					{
						label = "OPEN INVITE MENU",
						onClick = function()
							promptInvite(nil)
						end,
					},
				})
			end
			return
		end

		-- friends already on this server first, then online, then offline
		local here: { [number]: boolean } = {}
		for _, plr in Players:GetPlayers() do
			here[plr.UserId] = true
		end
		local sorted = table.clone(friends)
		local function rank(f: FriendInfo): number
			return if here[f.id] then 0 elseif f.online then 1 else 2
		end
		table.sort(sorted, function(a, b)
			local ra, rb = rank(a), rank(b)
			if ra ~= rb then
				return ra < rb
			end
			return a.name < b.name
		end)

		local GREEN = Color3.fromRGB(120, 210, 120)
		local function friendCell(cell: Rect, f: FriendInfo)
			local p = cellPanel(cell)
			local name = f.name
			local sc = if #name * 8 * style.head <= cell.w - 12 then style.head else 1
			local maxChars = (cell.w - 12) // (8 * sc)
			if #name > maxChars then
				name = name:sub(1, maxChars)
			end
			text(p, 0, 14, name, sc, nil, cell.w, 0.5)
			-- headshot via rbxthumb (resolves async on its own, no yield)
			local side = 60
			local av = Instance.new("ImageLabel")
			av.BackgroundTransparency = 1
			av.Image = `rbxthumb://type=AvatarHeadShot&id={f.id}&w=100&h=100`
			av.Size = UDim2.fromOffset(side, side)
			av.Position = UDim2.fromOffset((cell.w - side) // 2, 34)
			av.ZIndex = 3
			av.Parent = p
			local statusY = 34 + side + 4
			-- status lines shrink to the card like names do ("IN THIS GAME"
			-- at body scale overflows the 8-grid cells)
			local function statusText(s: string, color: Color3)
				local ssc = if #s * 8 * style.body <= cell.w - 12 then style.body else 1
				text(p, 0, statusY + (8 * style.body - 8 * ssc) // 2, s, ssc, color, cell.w, 0.5)
			end
			if here[f.id] then
				statusText("IN THIS GAME", GREEN)
				return -- nothing to invite; no button row
			end
			statusText(if f.online then "ONLINE" else "OFFLINE", if f.online then COOL else RARITY_GREY)
			if canInvite == false then
				cardButtons(p, cell.w, cell.h, { { label = "INVITES OFF" } })
			else
				local function invite()
					promptInvite(f.id)
				end
				cardButtons(p, cell.w, cell.h, {
					{ label = "INVITE", onClick = invite },
				})
				-- whole-card click target (behind the headshot/button strip),
				-- same as the shop card firing its BUY action
				clickable(content, cell.x, BOX_Y + cell.y, cell.w, cell.h, p, invite)
			end
		end

		local cells = layout8()
		local starts, counts = pagerSplit(#sorted, #cells)
		friendsPage = math.clamp(friendsPage, 0, #starts - 1)
		local first = starts[friendsPage + 1]
		local count = counts[friendsPage + 1]
		local ci = 1
		if friendsPage > 0 then
			arrowCell(cells[ci], "<", function()
				friendsPage -= 1
				showPage()
			end)
			ci += 1
		end
		for k = 0, count - 1 do
			friendCell(cells[ci], sorted[first + k])
			ci += 1
		end
		if first + count - 1 < #sorted then
			arrowCell(cells[ci], ">", function()
				friendsPage += 1
				showPage()
			end)
			ci += 1
		end
		while ci <= #cells do
			emptyCell(cells[ci])
			ci += 1
		end
	end

	-- RANKINGS: the daily/weekly/all-time kill boards (leaderboardui data
	-- source) as one full-cell page — two rows of tab pickers over a scrolling
	-- list of ranked players. Restyled from the old standalone overlay into the
	-- menu's box/conchars look; the shared bottom nav gives it BACK TO MENU.
	local RK_PERIODS = { { key = "day", text = "TODAY" }, { key = "week", text = "THIS WEEK" }, { key = "all", text = "ALL-TIME" } }
	local RK_SCOPES =
		{ { key = "mode", text = "THIS MODE" }, { key = "global", text = "GLOBAL" }, { key = "friends", text = "FRIENDS" } }

	-- fetch the board for the current tabs, superseding any in-flight one. The
	-- gen guard drops a stale response when a newer tab pick has taken over;
	-- rkInflightKey stops a rebuild from firing a duplicate fetch for the same
	-- board. Paced to the server's per-player cooldown.
	local function rankingsFetch()
		local lb = opts.leaderboards
		if not lb or not lb.ready() then
			return
		end
		local key = rkPeriod .. "|" .. rkScope
		if rkInflightKey == key then
			return
		end
		rkGen += 1
		local gen = rkGen
		rkInflightKey = key
		task.spawn(function()
			local wait = 2.1 - (os.clock() - rkLastInvoke)
			if wait > 0 then
				task.wait(wait)
			end
			if gen ~= rkGen then
				return -- a newer tab pick superseded this fetch
			end
			rkLastInvoke = os.clock()
			local ok, res = lb.fetch(rkPeriod, rkScope)
			if gen ~= rkGen then
				return
			end
			rkInflightKey = nil
			rkFetchedKey = key
			if ok and typeof(res) == "table" then
				rkData, rkErr = res, false
			else
				rkData, rkErr = nil, true
			end
			if state == "rankings" and gui.Enabled then
				task.defer(showPage)
			end
		end)
	end

	local function buildRankings()
		local cell = layout1()[1]
		local p = cellPanel(cell)
		local WHITE = Color3.new(1, 1, 1)
		local bs = 8 * style.body

		if not opts.leaderboards then
			text(p, 0, cell.h // 2 - 4 * style.body, "RANKINGS UNAVAILABLE", style.body, RARITY_GREY, cell.w, 0.5)
			return
		end

		-- two rows of pressable tab labels (period, then scope); the active
		-- one shows orange. Picking one changes the selection and rebuilds; the
		-- render below then notices the board no longer matches and refetches.
		local pad = 24
		local tabH = 8 * style.head + 14
		local tabY = 14
		local function tabRow(ry: number, defs: { { key: string, text: string } }, current: string, pick: (string) -> ())
			local colW = (cell.w - 2 * pad) / #defs
			for i, d in defs do
				local lx = math.floor(pad + (i - 1) * colW)
				local t = text(p, lx, ry, d.text, style.head, if d.key == current then ORANGE else WHITE, colW, 0.5)
				clickable(content, cell.x + lx, BOX_Y + cell.y + ry, colW, tabH, t, function()
					pick(d.key)
					showPage()
				end)
			end
		end
		tabRow(tabY, RK_PERIODS, rkPeriod, function(k)
			rkPeriod = k
		end)
		tabRow(tabY + tabH, RK_SCOPES, rkScope, function(k)
			rkScope = k
		end)

		local key = rkPeriod .. "|" .. rkScope
		if rkFetchedKey ~= key then
			rankingsFetch()
		end

		-- list area sits below the tabs, above a one-line footer
		local listTop = tabY + 2 * tabH + 12
		local footerH = bs + 18
		local listW = cell.w - 2 * pad - 8 -- leave room for the scrollbar
		local listH = cell.h - listTop - footerH

		-- a centred one-liner covering the whole list area (loading / empty)
		local function listMessage(msg: string)
			text(p, pad, listTop + (listH - bs) // 2, msg, style.body, RARITY_GREY, listW, 0.5)
		end

		local footer: string? = nil
		if rkFetchedKey ~= key then
			listMessage("LOADING...")
		elseif rkErr then
			listMessage("LEADERBOARDS UNAVAILABLE - TRY AGAIN")
		elseif rkData and rkData.disabled then
			listMessage("STATS ARE OFF IN THIS SESSION")
		else
			local entries = (rkData and rkData.entries) or {}
			if #entries == 0 then
				listMessage(
					if rkScope == "friends" then "NONE OF YOUR FRIENDS ARE RANKED YET" else "NO ENTRIES YET - GO GET SOME FRAGS"
				)
			else
				-- conchars is monospaced, so rank / name / value line up as fixed
				-- columns without measuring: rank left, value right, name between
				local scroll = Instance.new("ScrollingFrame")
				scroll.BackgroundTransparency = 1
				scroll.BorderSizePixel = 0
				scroll.Position = UDim2.fromOffset(pad, listTop)
				scroll.Size = UDim2.fromOffset(cell.w - 2 * pad, listH)
				scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
				scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
				scroll.ScrollBarThickness = 4
				scroll.ScrollBarImageColor3 = ORANGE
				scroll.Active = true
				scroll.ZIndex = 3
				scroll.Parent = p
				local layout = Instance.new("UIListLayout")
				layout.Padding = UDim.new(0, 2)
				layout.SortOrder = Enum.SortOrder.LayoutOrder
				layout.Parent = scroll

				local me = Players.LocalPlayer.UserId
				local rowH = bs + 8
				local rankW = 5 * bs
				local nameMax = math.max(1, (listW - rankW - 8 * bs) // bs)
				local mineShown = false
				for i, e in entries :: { LbEntry } do
					local mine = e.userId == me
					mineShown = mineShown or mine
					local row = Instance.new("Frame")
					-- the local player's row gets a faint orange wash to pop out
					row.BackgroundColor3 = ORANGE
					row.BackgroundTransparency = if mine then 0.75 else 1
					row.BorderSizePixel = 0
					row.Size = UDim2.fromOffset(listW, rowH)
					row.LayoutOrder = i
					row.ZIndex = 3
					row.Parent = scroll
					-- conchars is ASCII-only; match the friends-list sanitising
					local nm = (tostring(e.name):upper():gsub("[^\32-\126]", "?"))
					if #nm > nameMax then
						nm = nm:sub(1, nameMax)
					end
					local nameCol = if mine then ORANGE else WHITE
					text(row, 0, 4, `#{i}`, style.body, if mine then ORANGE else RARITY_GREY)
					text(row, rankW, 4, nm, style.body, nameCol)
					text(row, 0, 4, commas(e.value), style.body, nameCol, listW, 1)
				end
				footer = if mineShown
					then `KILLS - {#entries} RANKED`
					else `KILLS - {#entries} RANKED - YOU'RE NOT ON THIS BOARD`
			end
		end

		if footer then
			text(p, pad, cell.h - footerH + 4, footer, style.body, RARITY_GREY, listW, 0.5)
		end
	end

	-- ---- AVATAR page: quake-style shirt/pants tint -----------------------
	-- Steppers drive the boot's `color` command (userinfo -> the server
	-- broadcasts it back), so scoreboard colors and every client's rig
	-- tint move together. Preview machinery (tintedAvatarClone /
	-- avatarViewport) is shared with the main page's hero card and defined
	-- above buildMain.
	local function buildAvatar()
		local ac = opts.avatarColors
		local cells = layout2()
		local left, right = cells[1], cells[2]
		local lp = cellPanel(left)
		if not ac then
			text(lp, 0, math.floor(left.h / 2) - 8, "UNAVAILABLE", style.body, RARITY_GREY, left.w, 0.5)
			return
		end
		local top, bottom = ac.get()

		if not avatarViewport(lp, 10, 10, left.w - 20, left.h - 20) then
			-- rig still replicating/loading: rebuild once it lands
			text(lp, 0, math.floor(left.h / 2) - 8, "LOADING...", style.body, RARITY_GREY, left.w, 0.5)
			task.spawn(function()
				local waiting = avatarPreviewEnt
				while waiting and waiting.loading do
					task.wait(0.25)
				end
				if state == "avatar" and gui.Enabled then
					task.defer(showPage)
				end
			end)
		end

		-- right column: SHIRT / PANTS stepper panels, stacked (mock layout)
		local rTop: Rect = { x = right.x, y = right.y, w = right.w, h = (right.h - GAP) // 2 }
		local rBot: Rect = { x = right.x, y = right.y + rTop.h + GAP, w = right.w, h = right.h - rTop.h - GAP }
		local function tintPanel(cell: Rect, title: string, value: number, apply: (n: number) -> ())
			local p = cellPanel(cell)
			text(p, 0, 20, title, style.head, nil, cell.w, 0.5)
			local bs = 8 * style.body
			local ty = math.floor((cell.h - bs) / 2) + 10
			local name = QUAKE_COLOR_NAMES[value + 1] or tostring(value)
			local arrowLX = 32
			local arrowRX = cell.w - 32 - bs
			local arrowL = text(p, arrowLX, ty, "<", style.body)
			text(p, arrowLX + bs, ty, name, style.body, quakeRowColor(value), arrowRX - arrowLX - bs, 0.5)
			local arrowR = text(p, arrowRX, ty, ">", style.body)
			local function hot(lx: number, visual: GuiObject, fn: () -> ())
				clickable(content, cell.x + lx, BOX_Y + cell.y + ty - 12, bs + 24, bs + 24, visual, function()
					fn()
					showPage()
				end)
			end
			hot(arrowLX - 12, arrowL, function()
				apply((value + 13) % 14)
			end)
			hot(arrowRX - 12, arrowR, function()
				apply((value + 1) % 14)
			end)
		end
		tintPanel(rTop, "SHIRT COLOR", top, function(n: number)
			ac.set(n, bottom)
		end)
		tintPanel(rBot, "PANTS COLOR", bottom, function(n: number)
			ac.set(top, n)
		end)
	end

	local PAGES: { [string]: { title: string, build: () -> () } } = {
		main = { title = "FRAG PARTY", build = buildMain },
		settings = { title = "SETTINGS", build = buildSettings },
		callvote = { title = "CHANGE MAP", build = buildCallVote },
		about = { title = "ABOUT", build = buildAbout },
		shop = { title = "SHOP", build = buildShop },
		skins = { title = "SKINS", build = buildSkins },
		friends = { title = "FRIENDS", build = buildFriends },
		rankings = { title = "RANKINGS", build = buildRankings },
		avatar = { title = "AVATAR", build = buildAvatar },
	}

	-- the bottom action: leave (main, and callvote — the MAP plaque's page
	-- is its own standalone menu, not reached from main) or back out
	local function navAction()
		if state == "main" or state == "callvote" then
			close()
		else
			state = "main"
			showPage()
		end
	end

	showPage = function()
		content:ClearAllChildren()
		local page = PAGES[state] or PAGES.main
		-- shared title (same position every page)
		text(content, 0, math.floor((TITLE_H - 8 * style.title) / 2), page.title, style.title, nil, CANVAS_W, 0.5)
		page.build()
		-- shared bottom nav
		local navLabel = if state == "main" or state == "callvote" then "RETURN TO GAME" else "BACK TO MENU"
		local ty = BOTTOM_Y + math.floor((BTN_H - 8 * style.title) / 2)
		local navText = text(content, 0, ty, navLabel, style.title, nil, CANVAS_W, 0.5)
		centerAnchor(navText)
		clickable(
			content,
			math.floor((CANVAS_W - #navLabel * 8 * style.title) / 2),
			BOTTOM_Y,
			#navLabel * 8 * style.title,
			BTN_H,
			navText,
			navAction
		)
	end

	catcher.Activated:Connect(function()
		playClick()
		navAction()
	end)

	-- ---- open/close ----------------------------------------------------
	local open = false
	local function setOpen(on: boolean, page: string?)
		if open == on then
			return
		end
		open = on
		gui.Enabled = on
		if on then
			state, skinPage = page or "main", 0
			showPage()
			fitCanvas()
		end
		if opts.onUiToggle then
			opts.onUiToggle(on)
		end
	end
	close = function()
		setOpen(false)
		if opts.onReturnToGame then
			opts.onReturnToGame()
		end
	end

	-- MAP plaque / M: straight onto CALL A VOTE with fresh pending values
	local function openCallVote()
		cvDeny, cvMapIdx, cvSelected = nil, 0, nil
		table.clear(cvPending)
		if open then
			state = "callvote"
			showPage()
		else
			setOpen(true, "callvote")
		end
	end
	-- L: straight onto the RANKINGS page with a fresh fetch (twin of the main
	-- page's RANKINGS block; keeps the old leaderboard hotkey working)
	local function openRankings()
		rkFetchedKey, rkData = nil, nil
		if open then
			state = "rankings"
			showPage()
		else
			setOpen(true, "rankings")
		end
	end

	-- wallet/ownership changes (kills earning coins, a Robux receipt landing)
	-- re-render any page that shows them, so the coin counter ticks live and
	-- a finished purchase flips its card to EQUIP without reopening the menu
	if opts.shop then
		opts.shop.onChanged(function()
			if gui.Enabled and (state == "main" or state == "shop" or state == "skins") then
				task.defer(showPage)
			end
		end)
	end

	-- server verdicts on proposals (fired by directorui): a deny reason
	-- lands on the page's footer row; a vote starting closes the menu so
	-- the yes/no banner is visible and usable
	local cvBridge = opts.callvote
	if cvBridge then
		cvBridge.hooks.onDeny = function(reason: string)
			cvDeny = reason
			if open and state == "callvote" then
				task.defer(showPage)
			end
		end
		cvBridge.hooks.onBegin = function()
			if open and state == "callvote" then
				close()
			end
		end
	end

	-- E toggles the menu, M calls a map vote, L opens the rankings (the
	-- engine's own Quake menu moved to backslash). Like the engine's hotkeys
	-- (init.client.luau's InputBegan ignores gameProcessed), raw keys drive
	-- these; suppressed only while a text field owns the keyboard.
	UserInputService.InputBegan:Connect(function(input)
		if opts.isTyping() or UserInputService:GetFocusedTextBox() then
			return
		end
		-- E and M are page hotkeys, not plain toggles: from the other page
		-- they SWITCH (E -> main, M -> call-a-vote); only from their own
		-- page do they close the menu
		if input.KeyCode == Enum.KeyCode.E then
			if not open then
				setOpen(true)
			elseif state == "main" then
				setOpen(false)
			else
				state = "main"
				showPage()
			end
		elseif input.KeyCode == Enum.KeyCode.M and opts.callvote then
			if open and state == "callvote" then
				setOpen(false)
			else
				openCallVote()
			end
		elseif input.KeyCode == Enum.KeyCode.L and opts.leaderboards then
			openRankings()
		end
	end)

	-- ---- top-right MENU/MAP plaques ---------------------------------------
	-- Always visible during play, sitting left of the director gear (which
	-- is 44px at (1,-12),(0,12) in its own inset-ignoring gui). Touch-only
	-- devices get bare labels: there is no key to hint at.
	local topGui = Instance.new("ScreenGui")
	topGui.Name = "QuakeTopButtons"
	topGui.ResetOnSpawn = false
	topGui.DisplayOrder = 24 -- under the menu's 25: its scrim + catcher swallow these while open
	topGui.IgnoreGuiInset = true
	topGui.Parent = opts.playerGui

	-- conchars scale only, so the pixel font stays crisp (integer upscales)
	local TOP_H, TOP_SCALE = 52, 2
	-- touch-only devices get bare labels (no key to hint at). RQDBG_ForceTouchUI
	-- overrides the device probe, same as controls.luau's touchWanted(), so the
	-- plaques and the on-screen controls agree and the touch look is testable
	-- from a desktop Studio session.
	local force = workspace:GetAttribute("RQDBG_ForceTouchUI")
	local touchOnly = if type(force) == "boolean"
		then force
		else UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- one plaque, right edge at `rightEdge` (offset from the screen's right);
	-- returns the right edge for the next plaque to its left. `name` renders
	-- white, the `key` hint (may be "") stays orange, drawn as one centred line
	local plaqueBtns: { TextButton } = {} -- right-to-left, for layoutPlaques
	local function topButton(name: string, key: string, rightEdge: number, onClick: () -> ()): number
		local label = if key ~= "" then name .. " " .. key else name
		local gw = 8 * TOP_SCALE
		local w = #label * gw + 24
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.BackgroundTransparency = 1
		btn.AnchorPoint = Vector2.new(1, 0)
		btn.Position = UDim2.new(1, rightEdge, 0, 8)
		btn.Size = UDim2.fromOffset(w, TOP_H)
		btn.Parent = topGui
		nineSlice(btn, pieces, w, TOP_H, true, trackFill)
		-- centre the ink, not the cells: glyph side margins are uneven (the
		-- trailing "]" is mostly blank on its right, especially LibreQuake's),
		-- which reads as extra right padding on the plaque
		local dx = 0
		local f = font
		if f then
			local l = confontlib.inkSpan(f, label:byte(1))
			local _, r = confontlib.inkSpan(f, label:byte(#label))
			dx = ((7 - r) - l) * TOP_SCALE / 2
		end
		local lineX = (w - #label * gw) / 2 + dx
		local ty = (TOP_H - 8 * TOP_SCALE) / 2
		text(btn, lineX, ty, name, TOP_SCALE, Color3.new(1, 1, 1))
		if key ~= "" then
			text(btn, lineX + #(name .. " ") * gw, ty, key, TOP_SCALE, ORANGE)
		end
		pressPulse(btn, btn)
		btn.Activated:Connect(function()
			playClick()
			onClick()
		end)
		table.insert(plaqueBtns, btn)
		return rightEdge - w - 10
	end

	-- MAP takes the rightmost slot, MENU sits to its left. The gear slot
	-- (-68) is reserved only while the local player is the match host
	-- (RQHost, server-stamped) — everyone else gets the plaques flush to
	-- the corner instead of a gap where the gear would be. The scoreboard
	-- lives on TAB (hold-to-show, default.cfg) with a touch toggle in
	-- controls.luau, so no plaque for it here
	local function layoutPlaques()
		local edge = if Players.LocalPlayer:GetAttribute("RQHost") == true then -68 else -12
		for _, btn in plaqueBtns do
			btn.Position = UDim2.new(1, edge, 0, 8)
			edge -= btn.Size.X.Offset + 10
		end
	end
	local rightEdge = -68
	if opts.callvote then
		rightEdge = topButton("LEVEL", if touchOnly then "" else "[M]", rightEdge, function()
			openCallVote()
		end)
	end
	topButton("MENU", if touchOnly then "" else "[E]", rightEdge, function()
		setOpen(not open)
	end)
	Players.LocalPlayer:GetAttributeChangedSignal("RQHost"):Connect(layoutPlaques)
	layoutPlaques()

	return {
		toggle = function()
			setOpen(not open)
		end,
		isOpen = function()
			return open
		end,
		setBigFont = function(on: boolean)
			style = if on then BIG_FONT else CLASSIC_FONT
			if open then
				showPage()
			end
		end,
		isBigFont = function()
			return style == BIG_FONT
		end,
		setGrainyBg = function(on: boolean)
			grainyBg = on
			pieces.box_mm = if on then grainyFill else woodFill
			-- rebuild-able cards pick this up next showPage; the top MENU/MAP
			-- plaques are built once, so re-skin their tracked fill labels
			-- in place here
			for i = #fillLabels, 1, -1 do
				local l = fillLabels[i]
				if not l.Parent then
					table.remove(fillLabels, i)
				else
					if pieces.box_mm.img then
						l.ImageContent = Content.fromObject(pieces.box_mm.img)
					end
					l.TileSize = UDim2.fromOffset(pieces.box_mm.w * BOXSCALE, pieces.box_mm.h * BOXSCALE)
				end
			end
			if open then
				showPage()
			end
		end,
		isGrainyBg = function()
			return grainyBg
		end,
	}
end

return pausemenu
