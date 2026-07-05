--!strict
-- Pure render helpers vs C truth: CL_NewTranslation's colormap remap
-- (cl_parse.c / gl_rmisc.c "backwards ranges" quirk) and R_LightPoint /
-- RecursiveLightPoint sampling on real e1m1 lightdata.
local t = require("./testutil")
local textures = require("../src/client/render/textures")
local lightpoint = require("../src/shared/engine/client/lightpoint")
local vfslib = require("../src/shared/engine/common/vfs")
local bsplib = require("../src/shared/engine/bsp/bsp")

--------------------------------------------------------------------------
-- translatePixels: shirt rows 16..31 from (colors&0xf0), pants rows
-- 96..111 from (colors&15)<<4; ranges at 128+ are REVERSED (top+15-i)
local src = buffer.create(256)
for i = 0, 255 do
	buffer.writeu8(src, i, i)
end

-- colors 0x04: top 0 (ascending), bottom 4<<4=64 (ascending)
local out = textures.translatePixels(src, 256, 0x04)
local ok = true
for i = 0, 15 do
	if buffer.readu8(out, 16 + i) ~= 0 + i then
		ok = false
	end
	if buffer.readu8(out, 96 + i) ~= 64 + i then
		ok = false
	end
end
t.check(ok, "translate colors 0x04: shirt 0+i, pants 64+i (ascending ranges)")

-- colors 0xBB: top 0xB0=176 >= 128 -> reversed; bottom 11<<4=176 -> reversed
out = textures.translatePixels(src, 256, 0xBB)
ok = true
for i = 0, 15 do
	if buffer.readu8(out, 16 + i) ~= 176 + 15 - i then
		ok = false
	end
	if buffer.readu8(out, 96 + i) ~= 176 + 15 - i then
		ok = false
	end
end
t.check(ok, 'translate colors 0xBB: both ranges reversed ("backwards ranges" quirk at 128+)')

-- pixels outside the two 16-row bands pass through untouched
ok = true
for i = 0, 255 do
	if (i < 16 or i > 31) and (i < 96 or i > 111) then
		if buffer.readu8(out, i) ~= i then
			ok = false
		end
	end
end
t.check(ok, "translate: all non-shirt/pants indices identity")

--------------------------------------------------------------------------
-- R_LightPoint on e1m1
local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/e1m1.bsp")
assert(buf)
local models = bsplib.load("maps/e1m1.bsp", buf)
local world = models[1]

local base = function(_style: number): number
	return 264 -- "m"
end
local dark = function(_style: number): number
	return 0
end

-- no lightdata at all -> fullbright 255 (software renderer behaviour)
t.eq(lightpoint.at({ brush = { lightdata = nil } } :: any, vector.zero, base), 255, "no lightdata -> fullbright 255")

-- spawn hall floor: lit
local spawn = lightpoint.at(world, vector.create(480, -352, 100), base)
t.check(spawn > 20, `spawn hall floor lit ({spawn})`)

-- all styles at zero -> everything dark
t.eq(lightpoint.at(world, vector.create(480, -352, 100), dark), 0, "style values 0 -> light 0")

-- the style-10 alcove (688,80,80): brightness rides lightstyle 10
local alcoveOn = lightpoint.at(world, vector.create(688, 80, 80), base)
local alcoveOff = lightpoint.at(world, vector.create(688, 80, 80), function(style: number)
	return if style == 10 then 0 else 264
end)
t.check(alcoveOn > alcoveOff, `alcove floor rides style 10 (on={alcoveOn} off={alcoveOff})`)

-- -2048 downward reach: a point high above the start hall still lands
local high = lightpoint.at(world, vector.create(480, -352, 160), base)
t.check(high > 0, `trace reaches the floor from high up ({high})`)


--------------------------------------------------------------------------
-- R_InitSky / R_MakeSky layer semantics (r_sky.c): a sky texture is
-- 256x128; the LEFT half is the masked cloud layer (palette 0 =
-- transparent, C's bottomsky/bottommask), the RIGHT half the solid
-- background (topsky). Net scroll rates in the software pipeline are
-- front 16 px/s and back 8 px/s (R_MakeSky's skytime*skyspeed shift on
-- the front PLUS D_Sky_uv_To_st's skytime*skyspeed offset on the whole
-- composite; skyspeed = 8). Port delta on the row: horizontal-only
-- scroll vs C's diagonal (x AND y) drift, texture-space not projected.
local W, H = 256, 128
local sky = buffer.create(W * H)
for y = 0, H - 1 do
	for x = 0, 127 do
		-- front: transparent except a marker column at x=10 (index 50)
		buffer.writeu8(sky, y * W + x, if x == 10 then 50 else 0)
		-- back: gradient markers (index 100 + x%4)
		buffer.writeu8(sky, y * W + 128 + x, 100 + x % 4)
	end
end
local idPal = { r = {}, g = {}, b = {} }
for i = 0, 255 do
	idPal.r[i + 1] = i
	idPal.g[i + 1] = 0
	idPal.b[i + 1] = 0
end

local function px(out: buffer, x: number, y: number): number
	return buffer.readu8(out, (y * W + x) * 4) -- red channel = palette index
end

-- t=0: no shift. Front marker column 10 shows front color 50 at x=10;
-- everywhere else shows the back gradient sampled at the same column.
local out0 = textures.skyFramePixels(sky, W, H, idPal, 0) :: buffer
t.eq(px(out0, 10, 5), 50, "sky t=0: front cloud pixel wins where the mask is solid")
t.eq(px(out0, 11, 5), 100 + 11 % 4, "sky t=0: palette-0 front is transparent -> back layer shows")
t.eq(px(out0, 128 + 10, 5), 50, "sky: both output halves carry the same composite (right half too)")

-- t=1: front shifted 16, back 8. The marker column appears where
-- (x + 16) % 128 == 10 -> x = 122; back sample at x is (x+8)%128.
local out1 = textures.skyFramePixels(sky, W, H, idPal, 1) :: buffer
t.eq(px(out1, (10 - 16) % 128, 5), 50, "sky t=1: front layer scrolled at 16 px/s")
t.eq(px(out1, 0, 5), 100 + (0 + 8) % 128 % 4, "sky t=1: back layer scrolled at 8 px/s")

-- turb: perpendicular sine displacement with tiling wrap; the port's
-- constants (period 32 px, phase 2 rad/s, amp ±8 centered) are a stated
-- substitution vs C's CYCLE=128/SPEED=20/AMP 8±8 tile warp (r_surf.c
-- R_GenTurbTile) — asserted here so the substitution is pinned.
local TW = 64
local turbSrc = buffer.create(TW * TW)
for y = 0, TW - 1 do
	for x = 0, TW - 1 do
		buffer.writeu8(turbSrc, y * TW + x, x) -- column index = palette index
	end
end
local tout = textures.turbFramePixels(turbSrc, TW, TW, idPal, 0)
local okTurb = true
for y = 0, TW - 1 do
	-- at t=0 the row displacement for x sampling is siny[y] = round(8*sin(2pi*y/32))
	local disp = math.floor(8 * math.sin(2 * math.pi * (y / 32)) + 0.5)
	for x = 0, TW - 1, 7 do
		local want = (x + disp) % TW
		if buffer.readu8(tout, (y * TW + x) * 4) ~= want then
			okTurb = false
		end
	end
end
t.check(okTurb, "turb: x sampling displaced by the row sine (period 32, amp 8) with tiling wrap")


--------------------------------------------------------------------------
-- R_AliasSetupFrame framegroup selection (r_alias.c:652): group frame
-- picked by (time + syncbase) mod fullinterval against the interval
-- table; single frames pass through; out-of-range frame -> 0.
local mdllib = require("../src/shared/engine/models/mdl")
local flameBuf = vfslib.loadFile(fsys, "progs/flame2.mdl")
assert(flameBuf, "flame2.mdl missing")
local flame = mdllib.load("progs/flame2.mdl", flameBuf)
t.check(flame.numframes >= 1, `flame2.mdl loads ({flame.numframes} frames)`)

-- synthetic group: intervals {0.1, 0.2, 0.3, 0.4} over 4 frames
local fakeFrames = {}
for i = 1, 4 do
	fakeFrames[i] = flame.frames[1].frames[1]
end
local group = {
	group = true,
	intervals = { 0.1, 0.2, 0.3, 0.4 },
	frames = { "A", "B", "C", "D" } :: any,
	bboxmin = vector.zero,
	bboxmax = vector.zero,
}
local fakeAm = { numframes = 1, frames = { group } } :: any
t.eq(mdllib.selectFrame(fakeAm, 0, 0, 0.05) :: any, "A", "framegroup: t=0.05 -> interval 0.1 frame")
t.eq(mdllib.selectFrame(fakeAm, 0, 0, 0.15) :: any, "B", "framegroup: t=0.15 -> second frame")
t.eq(mdllib.selectFrame(fakeAm, 0, 0, 0.35) :: any, "D", "framegroup: t=0.35 -> last frame")
t.eq(mdllib.selectFrame(fakeAm, 0, 0, 0.45) :: any, "A", "framegroup: wraps at fullinterval (t=0.45 -> 0.05)")
t.eq(mdllib.selectFrame(fakeAm, 0, 0.1, 0.05) :: any, "B", "framegroup: syncbase offsets the phase")
t.eq(mdllib.selectFrame(fakeAm, 7, 0, 0.05) :: any, "A", "out-of-range frame falls back to frame 0 like C")

-- the real flame2.mdl: frame 0 is a group with equal intervals (0.1s
-- steps in id1); selection at k*0.1+0.05 walks the frames in order
local fd0 = flame.frames[1]
if fd0.group then
	local ivals = fd0.intervals :: { number }
	local seen = {}
	for k = 0, #ivals - 1 do
		local f = mdllib.selectFrame(flame, 0, 0, k * (ivals[1]) + ivals[1] / 2)
		table.insert(seen, f)
	end
	local distinct = 0
	local marks = {}
	for _, f in seen do
		if not marks[f] then
			marks[f] = true
			distinct += 1
		end
	end
	t.eq(distinct, #ivals, `flame2 framegroup cycles through all {#ivals} frames over one period`)
else
	t.check(true, "flame2 frame 0 not a group on this pak (skip)")
end

--------------------------------------------------------------------------
-- resamplePixelsPow2: GLQuake GL_ResampleTexture semantics — non-pow2
-- world textures stretch up to pow2 (MeshPart TextureContent renders
-- black for non-pow2 EditableImages, and padding would break tiling UVs)
do
	-- pow2 input passes through untouched (same buffer)
	local p64 = buffer.create(64 * 64)
	local same, sw, sh = textures.resamplePixelsPow2(p64, 64, 64)
	t.check(same == p64 and sw == 64 and sh == 64, "resample: 64x64 passes through")

	-- 3x2 -> 4x2: nearest-neighbour column map x2 -> floor(x2*3/4) = 0,0,1,2
	local p32 = buffer.create(3 * 2)
	for i = 0, 5 do
		buffer.writeu8(p32, i, i + 10)
	end
	local r, rw, rh = textures.resamplePixelsPow2(p32, 3, 2)
	t.eq(rw, 4, "resample: width 3 -> 4")
	t.eq(rh, 2, "resample: height 2 stays")
	local expect = { 10, 10, 11, 12, 13, 13, 14, 15 }
	local okr = true
	for i = 0, 7 do
		if buffer.readu8(r, i) ~= expect[i + 1] then
			okr = false
		end
	end
	t.check(okr, "resample: 3x2->4x2 nearest column map floor(x*3/4)")

	-- e1m1 census: the map really ships non-pow2 textures (the black-face
	-- bug's reach), and every resampled result is pow2-sized
	local fs = t.gameFs()
	local bspbuf = vfslib.loadFile(fs, "maps/e1m1.bsp")
	assert(bspbuf, "e1m1.bsp missing")
	local models = bsplib.load("maps/e1m1.bsp", bspbuf)
	local nonpow2 = 0
	local function isPow2(n: number): boolean
		return bit32.band(n, n - 1) == 0
	end
	for _, tex in models[1].brush.textures do
		if tex == nil then continue end
		if not (isPow2(tex.width) and isPow2(tex.height)) then
			nonpow2 += 1
			local _, w2, h2 = textures.resamplePixelsPow2(tex.pixels, tex.width, tex.height)
			t.check(isPow2(w2) and isPow2(h2) and w2 >= tex.width and h2 >= tex.height,
				`resample: {tex.name} {tex.width}x{tex.height} -> pow2 {w2}x{h2}`)
		end
	end
	t.check(nonpow2 > 0, `e1m1 ships {nonpow2} non-pow2 textures (the black-face bug's reach)`)
end

t.finish("test_render_misc")
