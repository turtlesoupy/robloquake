--!strict
--!optimize 2
-- Alias model (.mdl) loading — port of Mod_LoadAliasModel and friends from
-- WinQuake model.c with the disk structs from modelgen.h.
--
-- Frame vertex data stays as the raw packed trivertx_t stream (byte x,y,z,
-- lightnormalindex per vertex); real coordinates are
-- v * scale + scale_origin, exactly as the software renderer computes them.

local bufio = require("../common/bufio")

local mdl = {}

mdl.ALIAS_VERSION = 6
mdl.IDENT = 0x4F504449 -- "IDPO"
mdl.ALIAS_ONSEAM = 0x0020

-- model flags (EF_* in model.h, stored in mdl header flags)
mdl.EF_ROCKET = 1
mdl.EF_GRENADE = 2
mdl.EF_GIB = 4
mdl.EF_ROTATE = 8
mdl.EF_TRACER = 16
mdl.EF_ZOMGIB = 32
mdl.EF_TRACER2 = 64
mdl.EF_TRACER3 = 128

local ALIAS_SKIN_SINGLE = 0
local ALIAS_SINGLE = 0

export type Skin = {
	-- single skin: pixels only; group: intervals + one pixel buffer per frame
	group: boolean,
	pixels: buffer?, -- skinwidth*skinheight palette indices (single)
	intervals: { number }?,
	frames: { buffer }?,
}

export type Frame = {
	name: string,
	bboxmin: vector, -- packed byte coords (0-255 space)
	bboxmax: vector,
	verts: buffer, -- numverts * 4 bytes: x,y,z,lightnormalindex
}

export type FrameDesc = {
	group: boolean,
	-- single frames have exactly one entry in frames and no intervals
	intervals: { number }?,
	frames: { Frame },
	name: string, -- first frame's name (used by frame lookups)
	bboxmin: vector,
	bboxmax: vector,
}

export type StVert = {
	onseam: boolean,
	s: number, -- pixel coords (not the <<16 fixed point used internally)
	t: number,
}

export type AliasModel = {
	name: string,
	scale: vector,
	scale_origin: vector,
	boundingradius: number,
	eyeposition: vector,
	skinwidth: number,
	skinheight: number,
	numverts: number,
	numtris: number,
	numframes: number,
	synctype: number,
	flags: number,
	size: number, -- already scaled by ALIAS_BASE_SIZE_RATIO (1/11)
	skins: { Skin },
	stverts: { StVert },
	-- triangles as parallel arrays: facesfront flag and 3 C vertex indices
	facesfront: { boolean },
	vertindex: { number }, -- 3 per triangle, flattened
	frames: { FrameDesc },
	mins: vector, -- always -16/+16 like WinQuake (FIXME upstream)
	maxs: vector,
}

local function readTrivertxBounds(r: bufio.Reader): (vector, vector)
	local minv = vector.create(r:u8(), r:u8(), r:u8())
	r:skip(1) -- lightnormal isn't used
	local maxv = vector.create(r:u8(), r:u8(), r:u8())
	r:skip(1)
	return minv, maxv
end

-- Mod_LoadAliasFrame
local function loadFrame(r: bufio.Reader, numverts: number): Frame
	local bboxmin, bboxmax = readTrivertxBounds(r)
	local name = r:strz(16)
	return {
		name = name,
		bboxmin = bboxmin,
		bboxmax = bboxmax,
		verts = r:bytes(numverts * 4),
	}
end

function mdl.load(name: string, buf: buffer): AliasModel
	local r = bufio.reader(buf)
	local ident = r:i32()
	if ident ~= mdl.IDENT then
		error(`{name} is not an alias model`)
	end
	local version = r:i32()
	if version ~= mdl.ALIAS_VERSION then
		error(`{name} has wrong version number ({version} should be {mdl.ALIAS_VERSION})`)
	end

	local scale = r:vec3()
	local scale_origin = r:vec3()
	local boundingradius = r:f32()
	local eyeposition = r:vec3()
	local numskins = r:i32()
	local skinwidth = r:i32()
	local skinheight = r:i32()
	local numverts = r:i32()
	local numtris = r:i32()
	local numframes = r:i32()
	local synctype = r:i32()
	local flags = r:i32()
	local size = r:f32() * (1 / 11) -- ALIAS_BASE_SIZE_RATIO

	if numverts <= 0 then
		error(`model {name} has no vertices`)
	end
	if numtris <= 0 then
		error(`model {name} has no triangles`)
	end
	if numskins < 1 then
		error(`invalid # of skins: {numskins}`)
	end
	if numframes < 1 then
		error(`invalid # of frames: {numframes}`)
	end
	if skinwidth % 4 ~= 0 then
		error("skinwidth not multiple of 4")
	end

	-- skins
	local skinsize = skinwidth * skinheight
	local skins: { Skin } = table.create(numskins)
	for _ = 1, numskins do
		local skintype = r:i32()
		if skintype == ALIAS_SKIN_SINGLE then
			table.insert(skins, { group = false, pixels = r:bytes(skinsize) })
		else
			local groupcount = r:i32()
			local intervals = table.create(groupcount)
			for _ = 1, groupcount do
				local interval = r:f32()
				if interval <= 0 then
					error("skin interval<=0")
				end
				table.insert(intervals, interval)
			end
			local frames = table.create(groupcount)
			for _ = 1, groupcount do
				table.insert(frames, r:bytes(skinsize))
			end
			table.insert(skins, { group = true, intervals = intervals, frames = frames })
		end
	end

	-- base s and t vertices
	local stverts: { StVert } = table.create(numverts)
	for _ = 1, numverts do
		local onseam = r:i32()
		table.insert(stverts, {
			onseam = bit32.band(onseam, mdl.ALIAS_ONSEAM) ~= 0,
			s = r:i32(),
			t = r:i32(),
		})
	end

	-- triangles
	local facesfront: { boolean } = table.create(numtris)
	local vertindex: { number } = table.create(numtris * 3)
	for _ = 1, numtris do
		table.insert(facesfront, r:i32() ~= 0)
		table.insert(vertindex, r:i32())
		table.insert(vertindex, r:i32())
		table.insert(vertindex, r:i32())
	end

	-- frames
	local frames: { FrameDesc } = table.create(numframes)
	for _ = 1, numframes do
		local frametype = r:i32()
		if frametype == ALIAS_SINGLE then
			local f = loadFrame(r, numverts)
			table.insert(frames, {
				group = false,
				frames = { f },
				name = f.name,
				bboxmin = f.bboxmin,
				bboxmax = f.bboxmax,
			})
		else
			local groupcount = r:i32()
			local bboxmin, bboxmax = readTrivertxBounds(r)
			local intervals = table.create(groupcount)
			for _ = 1, groupcount do
				local interval = r:f32()
				if interval <= 0 then
					error("frame interval<=0")
				end
				table.insert(intervals, interval)
			end
			local groupframes = table.create(groupcount)
			for _ = 1, groupcount do
				table.insert(groupframes, loadFrame(r, numverts))
			end
			table.insert(frames, {
				group = true,
				intervals = intervals,
				frames = groupframes,
				name = groupframes[1].name,
				bboxmin = bboxmin,
				bboxmax = bboxmax,
			})
		end
	end

	return {
		name = name,
		scale = scale,
		scale_origin = scale_origin,
		boundingradius = boundingradius,
		eyeposition = eyeposition,
		skinwidth = skinwidth,
		skinheight = skinheight,
		numverts = numverts,
		numtris = numtris,
		numframes = numframes,
		synctype = synctype,
		flags = flags,
		size = size,
		skins = skins,
		stverts = stverts,
		facesfront = facesfront,
		vertindex = vertindex,
		frames = frames,
		mins = vector.create(-16, -16, -16),
		maxs = vector.create(16, 16, 16),
	}
end

-- Unpack one frame vertex: returns model-space position and normal index.
function mdl.frameVert(m: AliasModel, frame: Frame, i: number): (vector, number)
	local o = (i - 1) * 4
	local packed = vector.create(
		buffer.readu8(frame.verts, o),
		buffer.readu8(frame.verts, o + 1),
		buffer.readu8(frame.verts, o + 2)
	)
	return packed * m.scale + m.scale_origin, buffer.readu8(frame.verts, o + 3)
end

-- R_AliasSetupFrame's framegroup selection: pick the group frame whose
-- interval bounds (time + syncbase) mod fullinterval. C's fallthrough to
-- the last frame is unreachable (targettime < fullinterval by
-- construction) in both C and this port.
function mdl.selectFrame(am: AliasModel, frame: number, syncbase: number, time: number): Frame
	if frame >= am.numframes or frame < 0 then
		frame = 0
	end
	local fd = am.frames[frame + 1]
	if fd.group then
		local intervals = fd.intervals :: { number }
		local fullinterval = intervals[#intervals]
		local targettime = (time + syncbase) - math.floor((time + syncbase) / fullinterval) * fullinterval
		for i, interval in intervals do
			if interval > targettime then
				return fd.frames[i]
			end
		end
	end
	return fd.frames[1]
end

return mdl
