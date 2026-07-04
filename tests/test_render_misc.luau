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

t.finish("test_render_misc")
