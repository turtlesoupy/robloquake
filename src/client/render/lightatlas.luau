--!strict
--!optimize 2
--!native
-- Per-texel lightmap atlas — the software renderer's surface lighting
-- (R_BuildLightMap / R_AddDynamicLights / R_MarkLights) realized as black
-- alpha-overlay pages multiplied over fullbright base textures:
--   framebuffer = texture * (1 - alpha),  alpha = 1 - brightness
-- Lightmap texels sample every 16 units exactly like blocklights; the
-- GPU's bilinear filter reproduces the interpolated light steps.

local AssetService = game:GetService("AssetService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local engine = ReplicatedStorage:WaitForChild("Shared").engine
local bsp = require(engine.bsp.bsp)

local lightatlas = {}

local PAGE = 1024

export type Dlight = {
	key: number,
	origin: vector,
	radius: number,
	die: number,
	decay: number,
	minlight: number,
}

export type Region = {
	page: number,
	x: number, -- outer origin (includes 1px gutter)
	y: number,
	smax: number,
	tmax: number,
	surf: bsp.Surface,
	data: bsp.BspData,
	animated: boolean, -- any non-zero style layer
	dlightframe: number,
	dlightbits: number,
}

type Page = {
	img: EditableImage,
	cpu: buffer, -- CPU mirror; initial build batches into one upload
	live: boolean, -- after flush, region writes also hit the image
	shelfY: number,
	shelfX: number,
	shelfH: number,
	-- dirty rect accumulated by live writeRegion calls; flushDirty uploads
	-- one WritePixelsBuffer per page per frame instead of one per region
	dirtyX0: number,
	dirtyY0: number,
	dirtyX1: number, -- exclusive; dirtyX1 == 0 means clean
	dirtyY1: number,
}

export type Atlas = {
	pages: { Page },
	regions: { Region },
	bySurf: { [bsp.Surface]: Region },
	animated: { Region },
	framecount: number,
	denied: boolean, -- editable budget refused a page; stop asking for more
}

function lightatlas.new(): Atlas
	return { pages = {}, regions = {}, bySurf = {}, animated = {}, framecount = 0, denied = false }
end

local function newPage(a: Atlas): Page?
	-- once the device budget denies a page, every further attempt this map
	-- would fail the same way (refunds land ~15-25s later, long after the
	-- build): latch and go quiet, or a big map burns thousands of failed
	-- CreateEditableImage calls + two warns each (866k lines in one
	-- playtest log). Affected surfaces render fullbright; the next map
	-- gets a fresh atlas and tries again.
	if a.denied then
		return nil
	end
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(PAGE, PAGE) })
	end)
	if not ok or not img then
		a.denied = true
		warn(`[fragparty] light atlas page allocation failed (have {#a.pages} pages); lightmaps degrade to fullbright for this map`)
		return nil
	end
	local page: Page = {
		img = img :: EditableImage,
		cpu = buffer.create(PAGE * PAGE * 4),
		live = false,
		shelfY = 0,
		shelfX = 0,
		shelfH = 0,
		dirtyX0 = 0,
		dirtyY0 = 0,
		dirtyX1 = 0,
		dirtyY1 = 0,
	}
	table.insert(a.pages, page)
	return page
end

-- shelf packer; w/h include the 1px gutter ring
local function allocRect(a: Atlas, w: number, h: number): (number, number, number)
	for pi, page in a.pages do
		if page.shelfX + w <= PAGE and page.shelfY + h <= PAGE then
			local x, y = page.shelfX, page.shelfY
			page.shelfX += w
			page.shelfH = math.max(page.shelfH, h)
			return pi, x, y
		end
		if page.shelfY + page.shelfH + h <= PAGE then
			page.shelfY += page.shelfH
			page.shelfX = w
			page.shelfH = h
			return pi, 0, page.shelfY
		end
	end
	local page = newPage(a)
	if not page then
		return 0, 0, 0
	end
	page.shelfX = w
	page.shelfH = h
	return #a.pages, 0, 0
end

-- combineLight semantics shared with the old per-vertex path: blocklights
-- total (sum sample*stylevalue) >> 8, overbright x2, gamma 0.7
local function brightness(total: number): number
	local linear = math.min(total / 256 * 2, 255) / 255
	return linear ^ 0.7
end

-- R_AddDynamicLights: accumulate dlight falloff into blocklights (adds in
-- the same *256 scale the style layers use)
local function addDynamicLights(region: Region, blocklights: { number }, dlights: { Dlight })
	local surf = region.surf
	local data = region.data
	local plane = data.planes[surf.planenum + 1]
	local normal = plane.normal
	local planedist = plane.dist
	local ti = data.texinfo[surf.texinfonum + 1]
	local vecs = ti.vecs
	local smax, tmax = region.smax, region.tmax

	for lnum, dl in dlights do
		if bit32.band(region.dlightbits, bit32.lshift(1, lnum - 1)) == 0 then
			continue
		end
		local rad = dl.radius
		local dist = vector.dot(dl.origin, normal) - planedist
		rad -= math.abs(dist)
		local minlight = dl.minlight
		if rad < minlight then
			continue
		end
		minlight = rad - minlight

		local impact = dl.origin - normal * dist
		local local0 = impact.x * vecs[1] + impact.y * vecs[2] + impact.z * vecs[3] + vecs[4] - surf.texturemins[1]
		local local1 = impact.x * vecs[5] + impact.y * vecs[6] + impact.z * vecs[7] + vecs[8] - surf.texturemins[2]

		for t = 0, tmax - 1 do
			local td = math.abs(local1 - t * 16)
			for s = 0, smax - 1 do
				local sd = math.abs(local0 - s * 16)
				local d
				if sd > td then
					d = sd + td / 2
				else
					d = td + sd / 2
				end
				if d < minlight then
					local i = t * smax + s + 1
					blocklights[i] += (rad - d) * 256
				end
			end
		end
	end
end

local blocklightsScratch: { number } = {}
local lastLit: { [Region]: boolean } = {} -- regions lit by dlights last frame

-- R_BuildLightMap → alpha bytes, written with a replicated 1px gutter so
-- bilinear sampling never bleeds a neighbour region
function lightatlas.writeRegion(a: Atlas, region: Region, styleValue: (style: number) -> number, dlights: { Dlight }?)
	local surf = region.surf
	local data = region.data
	local lightdata = data.lightdata :: buffer
	local smax, tmax = region.smax, region.tmax
	local size = smax * tmax

	-- C's static `int blocklights[18*18]` — module scratch, zeroed per call
	local blocklights = blocklightsScratch
	for i = 1, size do
		blocklights[i] = 0
	end
	for layer = 1, 4 do
		local style = surf.styles[layer]
		if style == 255 then
			break
		end
		local scale = styleValue(style)
		local ofs = surf.lightofs + (layer - 1) * size
		if ofs + size > buffer.len(lightdata) then
			break
		end
		for i = 1, size do
			blocklights[i] += buffer.readu8(lightdata, ofs + i - 1) * scale
		end
	end

	if dlights and region.dlightframe == a.framecount then
		addDynamicLights(region, blocklights, dlights)
	end

	-- alpha = 1 - brightness, black RGB; +2 for the gutter ring. Writes land
	-- in the page's CPU mirror; live pages also upload the touched rect
	-- (WritePixelsBuffer requires the buffer length to match exactly).
	local page = a.pages[region.page]
	if not page then
		return
	end
	local w, h = smax + 2, tmax + 2
	local cpu = page.cpu
	for py = 0, h - 1 do
		local ly = math.clamp(py - 1, 0, tmax - 1)
		local rowbase = ((region.y + py) * PAGE + region.x) * 4
		for px = 0, w - 1 do
			local lx = math.clamp(px - 1, 0, smax - 1)
			local alpha = math.floor((1 - brightness(blocklights[ly * smax + lx + 1])) * 255 + 0.5)
			buffer.writeu32(cpu, rowbase + px * 4, bit32.lshift(alpha, 24)) -- RGBA LE: 0,0,0,alpha
		end
	end
	if page.live then
		-- accumulate the page dirty rect; lightatlas.flushDirty (called at
		-- the end of updateStyles/updateDlights) uploads once per page
		if page.dirtyX1 == 0 then
			page.dirtyX0, page.dirtyY0 = region.x, region.y
			page.dirtyX1, page.dirtyY1 = region.x + w, region.y + h
		else
			page.dirtyX0 = math.min(page.dirtyX0, region.x)
			page.dirtyY0 = math.min(page.dirtyY0, region.y)
			page.dirtyX1 = math.max(page.dirtyX1, region.x + w)
			page.dirtyY1 = math.max(page.dirtyY1, region.y + h)
		end
	end
end

-- upload accumulated dirty rects, one WritePixelsBuffer per touched page
-- (WritePixelsBuffer needs an exact-length buffer, so this is the one
-- remaining alloc: per page per frame, not per region)
function lightatlas.flushDirty(a: Atlas)
	for _, page in a.pages do
		if page.dirtyX1 == 0 then
			continue
		end
		local x0, y0, x1, y1 = page.dirtyX0, page.dirtyY0, page.dirtyX1, page.dirtyY1
		page.dirtyX1 = 0
		local w, h = x1 - x0, y1 - y0
		local out = buffer.create(w * h * 4)
		local cpu = page.cpu
		for py = 0, h - 1 do
			buffer.copy(out, py * w * 4, cpu, ((y0 + py) * PAGE + x0) * 4, w * 4)
		end
		page.img:WritePixelsBuffer(Vector2.new(x0, y0), Vector2.new(w, h), out)
	end
end

-- upload whole pages once after a build; subsequent region writes stream
function lightatlas.flushPages(a: Atlas)
	for _, page in a.pages do
		if not page.live then
			page.live = true
			page.img:WritePixelsBuffer(Vector2.zero, Vector2.new(PAGE, PAGE), page.cpu)
		end
	end
end

-- returns nil for unlit surfaces (sky/water/no lightdata: fullbright)
function lightatlas.alloc(a: Atlas, data: bsp.BspData, surf: bsp.Surface, styleValue: (style: number) -> number): Region?
	if bit32.band(surf.flags, bsp.SURF_DRAWTILED) ~= 0 then
		return nil
	end
	if not data.lightdata or surf.lightofs < 0 then
		return nil
	end
	local existing = a.bySurf[surf]
	if existing then
		return existing
	end

	local smax = bit32.rshift(surf.extents[1], 4) + 1
	local tmax = bit32.rshift(surf.extents[2], 4) + 1
	if smax + 2 > PAGE or tmax + 2 > PAGE then
		warn(`[fragparty] lightmap region exceeds atlas page: {smax}x{tmax} (extents {surf.extents[1]}x{surf.extents[2]})`)
		return nil
	end
	local pi, x, y = allocRect(a, smax + 2, tmax + 2)
	if pi == 0 then
		return nil
	end

	local animated = false
	for layer = 1, 4 do
		local style = surf.styles[layer]
		if style == 255 then
			break
		end
		if style ~= 0 or layer > 1 then
			animated = true
		end
	end

	local region: Region = {
		page = pi,
		x = x,
		y = y,
		smax = smax,
		tmax = tmax,
		surf = surf,
		data = data,
		animated = animated,
		dlightframe = -1,
		dlightbits = 0,
	}
	table.insert(a.regions, region)
	a.bySurf[surf] = region
	if animated then
		table.insert(a.animated, region)
	end
	lightatlas.writeRegion(a, region, styleValue)
	return region
end

function lightatlas.destroy(a: Atlas)
	for _, page in a.pages do
		page.img:Destroy()
	end
	table.clear(a.pages)
	table.clear(a.regions)
	table.clear(a.animated)
	table.clear(lastLit) -- stale regions must not rebake into the next atlas
end

function lightatlas.pageImage(a: Atlas, pi: number): EditableImage?
	local page = a.pages[pi]
	return if page then page.img else nil
end

-- atlas UV for a vertex: light coords ls/lt in [0, smax-1]; texel i's
-- centre sits at outer origin + 1 (gutter) + i + 0.5
function lightatlas.uv(region: Region, ls: number, lt: number): (number, number)
	return (region.x + 1 + ls + 0.5) / PAGE, (region.y + 1 + lt + 0.5) / PAGE
end

-- restyle pass: rewrite regions whose styles changed this tick
function lightatlas.updateStyles(a: Atlas, styleValue: (style: number) -> number, changed: { [number]: boolean })
	for _, region in a.animated do
		for layer = 1, 4 do
			local style = region.surf.styles[layer]
			if style == 255 then
				break
			end
			if changed[style] then
				lightatlas.writeRegion(a, region, styleValue)
				break
			end
		end
	end
	lightatlas.flushDirty(a)
end

-- R_MarkLights over the world nodes
local function markLights(a: Atlas, data: bsp.BspData, dl: Dlight, bitnum: number, nodenum: number)
	if nodenum < 0 then
		return
	end
	local node = data.nodes[nodenum + 1]
	local plane = data.planes[node.planenum + 1]
	local dist = vector.dot(dl.origin, plane.normal) - plane.dist
	if dist > dl.radius then
		markLights(a, data, dl, bitnum, node.children[1])
		return
	end
	if dist < -dl.radius then
		markLights(a, data, dl, bitnum, node.children[2])
		return
	end
	for i = 0, node.numsurfaces - 1 do
		local surf = data.surfaces[node.firstsurface + i + 1]
		local region = a.bySurf[surf]
		if region then
			if region.dlightframe ~= a.framecount then
				region.dlightbits = 0
				region.dlightframe = a.framecount
			end
			region.dlightbits = bit32.bor(region.dlightbits, bit32.lshift(1, bitnum - 1))
		end
	end
	markLights(a, data, dl, bitnum, node.children[1])
	markLights(a, data, dl, bitnum, node.children[2])
end

-- per-frame dynamic light pass: mark, rebake marked, and rebake surfaces
-- lit last frame so dead lights clear
function lightatlas.updateDlights(a: Atlas, data: bsp.BspData, dlights: { Dlight }, styleValue: (style: number) -> number)
	if #dlights == 0 and next(lastLit) == nil then
		return
	end
	a.framecount += 1
	for i, dl in dlights do
		markLights(a, data, dl, i, 0)
	end
	local nowLit: { [Region]: boolean } = {}
	for _, region in a.regions do
		if region.dlightframe == a.framecount then
			nowLit[region] = true
			lightatlas.writeRegion(a, region, styleValue, dlights)
		end
	end
	for region in lastLit do
		if not nowLit[region] then
			lightatlas.writeRegion(a, region, styleValue) -- light left: restore
		end
	end
	lastLit = nowLit
	lightatlas.flushDirty(a)
end

return lightatlas
