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

t.finish("test_render_misc")
