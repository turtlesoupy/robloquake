--!strict
--!optimize 2
-- WAD2 archive and qpic loading — port of WinQuake wad.c plus the qpic_t
-- format used by gfx/*.lmp files (draw.c Draw_CachePic). Also loads the
-- raw gfx/palette.lmp and gfx/colormap.lmp tables.

local bufio = require("../common/bufio")

local wad = {}

wad.TYP_QPIC = 66

export type LumpInfo = {
	name: string, -- cleaned (lowercased) name
	filepos: number,
	disksize: number,
	size: number, -- uncompressed
	type: number,
}

export type Wad = {
	data: buffer,
	lumps: { LumpInfo },
	byName: { [string]: LumpInfo },
	numlumps: number,
}

-- Pixel image with the qpic_t layout: width/height then w*h palette indices.
export type QPic = {
	width: number,
	height: number,
	pixels: buffer,
}

-- W_CleanupName: lowercase; stops at NUL (names are at most 16 chars)
local function cleanupName(name: string): string
	return name:lower()
end

-- W_LoadWadFile
function wad.load(data: buffer): Wad
	local r = bufio.reader(data)
	local id = r:strz(4)
	if id ~= "WAD2" then
		error("wad file doesn't have WAD2 id")
	end
	local numlumps = r:i32()
	local infotableofs = r:i32()

	local lumps: { LumpInfo } = table.create(numlumps)
	local byName: { [string]: LumpInfo } = {}
	r:seek(infotableofs)
	for _ = 1, numlumps do
		local filepos = r:i32()
		local disksize = r:i32()
		local size = r:i32()
		local typ = r:u8()
		r:skip(3) -- compression + pad (never used by the engine)
		local name = cleanupName(r:strz(16))
		local lump: LumpInfo = {
			name = name,
			filepos = filepos,
			disksize = disksize,
			size = size,
			type = typ,
		}
		table.insert(lumps, lump)
		byName[name] = lump
	end

	return { data = data, lumps = lumps, byName = byName, numlumps = numlumps }
end

-- W_GetLumpinfo / W_GetLumpName
function wad.getLump(w: Wad, name: string): LumpInfo
	local lump = w.byName[cleanupName(name)]
	if not lump then
		error(`W_GetLumpinfo: {name} not found`)
	end
	return lump
end

-- Read a TYP_QPIC lump as a picture.
function wad.getPic(w: Wad, name: string): QPic
	local lump = wad.getLump(w, name)
	return wad.parseQPic(bufio.slice(w.data, lump.filepos, lump.size))
end

-- Read a raw (non-qpic) lump, e.g. conchars which is bare 128x128 pixels.
function wad.getRaw(w: Wad, name: string): buffer
	local lump = wad.getLump(w, name)
	return bufio.slice(w.data, lump.filepos, lump.size)
end

-- qpic_t: int width, int height, byte data[]. Used both for wad lumps and
-- standalone gfx/*.lmp files.
function wad.parseQPic(data: buffer): QPic
	local r = bufio.reader(data)
	local width = r:i32()
	local height = r:i32()
	return {
		width = width,
		height = height,
		pixels = r:bytes(width * height),
	}
end

-- gfx/palette.lmp: 256 RGB triples. Returns arrays of 0-255 r,g,b indexed
-- by palette index + 1.
export type Palette = { r: { number }, g: { number }, b: { number } }

function wad.parsePalette(data: buffer): Palette
	if buffer.len(data) < 768 then
		error("palette.lmp too short")
	end
	local pr = table.create(256)
	local pg = table.create(256)
	local pb = table.create(256)
	for i = 0, 255 do
		table.insert(pr, buffer.readu8(data, i * 3))
		table.insert(pg, buffer.readu8(data, i * 3 + 1))
		table.insert(pb, buffer.readu8(data, i * 3 + 2))
	end
	return { r = pr, g = pg, b = pb }
end

return wad
