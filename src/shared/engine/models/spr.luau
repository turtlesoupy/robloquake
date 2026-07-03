--!strict
--!optimize 2
-- Sprite model (.spr) loading — port of Mod_LoadSpriteModel from WinQuake
-- model.c with the disk structs from spritegn.h.

local bufio = require("../common/bufio")

local spr = {}

spr.SPRITE_VERSION = 1
spr.IDENT = 0x50534449 -- "IDSP"

spr.SPR_VP_PARALLEL_UPRIGHT = 0
spr.SPR_FACING_UPRIGHT = 1
spr.SPR_VP_PARALLEL = 2
spr.SPR_ORIENTED = 3
spr.SPR_VP_PARALLEL_ORIENTED = 4

local SPR_SINGLE = 0

export type SpriteFrame = {
	width: number,
	height: number,
	-- screen-space bounds relative to the origin (software renderer names)
	up: number,
	down: number,
	left: number,
	right: number,
	pixels: buffer, -- width*height palette indices
}

export type SpriteFrameDesc = {
	group: boolean,
	intervals: { number }?,
	frames: { SpriteFrame },
}

export type SpriteModel = {
	name: string,
	type: number, -- SPR_* orientation
	maxwidth: number,
	maxheight: number,
	beamlength: number,
	synctype: number,
	numframes: number,
	frames: { SpriteFrameDesc },
	mins: vector,
	maxs: vector,
}

-- Mod_LoadSpriteFrame
local function loadFrame(r: bufio.Reader): SpriteFrame
	local ox = r:i32()
	local oy = r:i32()
	local width = r:i32()
	local height = r:i32()
	return {
		width = width,
		height = height,
		up = oy,
		down = oy - height,
		left = ox,
		right = width + ox,
		pixels = r:bytes(width * height),
	}
end

function spr.load(name: string, buf: buffer): SpriteModel
	local r = bufio.reader(buf)
	local ident = r:i32()
	if ident ~= spr.IDENT then
		error(`{name} is not a sprite model`)
	end
	local version = r:i32()
	if version ~= spr.SPRITE_VERSION then
		error(`{name} has wrong version number ({version} should be {spr.SPRITE_VERSION})`)
	end

	local typ = r:i32()
	r:skip(4) -- boundingradius (never used by the engine)
	local maxwidth = r:i32()
	local maxheight = r:i32()
	local numframes = r:i32()
	local beamlength = r:f32()
	local synctype = r:i32()

	if numframes < 1 then
		error(`invalid # of frames: {numframes}`)
	end

	local frames: { SpriteFrameDesc } = table.create(numframes)
	for _ = 1, numframes do
		local frametype = r:i32()
		if frametype == SPR_SINGLE then
			table.insert(frames, { group = false, frames = { loadFrame(r) } })
		else
			local groupcount = r:i32()
			local intervals = table.create(groupcount)
			for _ = 1, groupcount do
				local interval = r:f32()
				if interval <= 0 then
					error("sprite interval<=0")
				end
				table.insert(intervals, interval)
			end
			local groupframes = table.create(groupcount)
			for _ = 1, groupcount do
				table.insert(groupframes, loadFrame(r))
			end
			table.insert(frames, { group = true, intervals = intervals, frames = groupframes })
		end
	end

	return {
		name = name,
		type = typ,
		maxwidth = maxwidth,
		maxheight = maxheight,
		beamlength = beamlength,
		synctype = synctype,
		numframes = numframes,
		frames = frames,
		mins = vector.create(-maxwidth / 2, -maxwidth / 2, -maxheight / 2),
		maxs = vector.create(maxwidth / 2, maxwidth / 2, maxheight / 2),
	}
end

return spr
