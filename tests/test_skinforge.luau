--!strict
-- Procedural weapon skins (skinforge) against the real v_shot.mdl skin:
-- determinism, seed divergence, fullbright preservation, output shape.
-- Also dumps base/camo previews as raw RGBA for visual inspection when
-- SKINFORGE_DUMP is set (tools/preview_skin.py converts to PNG).

local fs = require("@lune/fs")
local process = require("@lune/process")

local t = require("./testutil")
local mdllib = require("../src/shared/engine/models/mdl")
local skinforge = require("../src/client/render/skinforge")
local textures = require("../src/client/render/textures")
local vfslib = require("../src/shared/engine/common/vfs")

local fsys = t.gameFs()
local palbuf = vfslib.loadFile(fsys, "gfx/palette.lmp")
assert(palbuf)
local pal = textures.parsePalette(palbuf)

local buf = vfslib.loadFile(fsys, "progs/v_shot.mdl")
assert(buf, "progs/v_shot.mdl missing from pak0")
local am = mdllib.load("progs/v_shot.mdl", buf)
local skin = am.skins[1]
local pixels = (if skin.group then (skin.frames :: { buffer })[1] else skin.pixels) :: buffer
local w, h = am.skinwidth, am.skinheight

--------------------------------------------------------------------------
-- recipe parsing
local r = skinforge.parse("camo:1234")
t.check(r ~= nil and r.kind == "camo" and r.seed == 1234, "parse camo:1234")
r = skinforge.parse("camo")
t.check(r ~= nil and r.seed == 0, "parse bare camo -> seed 0")
t.check(skinforge.parse("plaid:9") == nil, "unknown recipe kind rejected")
t.check(skinforge.parse("camo:x") == nil, "malformed seed rejected")

--------------------------------------------------------------------------
-- generation on the real shotgun skin
local a = skinforge.camoPixels(pixels, w, h, pal, 7)
t.check(buffer.len(a) == w * h * 4, `camo output is RGBA8 ({w}x{h})`)

local b = skinforge.camoPixels(pixels, w, h, pal, 7)
t.check(buffer.tostring(a) == buffer.tostring(b), "same seed -> identical pixels (deterministic)")

local c = skinforge.camoPixels(pixels, w, h, pal, 8)
t.check(buffer.tostring(a) ~= buffer.tostring(c), "different seed -> different pixels")

local opaque = true
for i = 0, w * h - 1 do
	if buffer.readu8(a, i * 4 + 3) ~= 255 then
		opaque = false
		break
	end
end
t.check(opaque, "camo skin fully opaque")

-- the recolor must actually change the skin
local base = textures.toRGBA(pixels, w * h, pal, false)
t.check(buffer.tostring(a) ~= buffer.tostring(base), "camo differs from the base skin")

--------------------------------------------------------------------------
-- every registered generator: deterministic, right shape, distinct output
local specs: { string } = {}
for _, kind in skinforge.kinds() do
	table.insert(specs, kind .. ":7")
end
t.check(#specs >= 18, `{#specs} generators registered`)
local outputs: { [string]: string } = {}
for _, spec in specs do
	local recipe = skinforge.parse(spec)
	t.check(recipe ~= nil, `parse {spec}`)
	assert(recipe)
	local px = skinforge.generatePixels(recipe, pixels, w, h, pal)
	t.check(buffer.len(px) == w * h * 4, `{spec} output shape`)
	local again = skinforge.generatePixels(recipe, pixels, w, h, pal)
	t.check(buffer.tostring(px) == buffer.tostring(again), `{spec} deterministic`)
	outputs[spec] = buffer.tostring(px)
end
-- pairwise-distinct across the whole set
local seen: { [string]: string } = {}
local allDistinct = true
for spec, px in outputs do
	for other, opx in seen do
		if px == opx then
			allDistinct = false
			print(`  identical output: {spec} == {other}`)
		end
	end
	seen[spec] = px
end
t.check(allDistinct, "all generators produce distinct pixels")

-- every skin renders lit (quake-style); unknown specs are never unlit
t.check(not skinforge.isUnlit("camo:7"), "camo renders lit")
t.check(not skinforge.isUnlit("zebra:7"), "zebra renders lit")
t.check(not skinforge.isUnlit("plaid:7"), "unknown spec not unlit")

--------------------------------------------------------------------------
-- fullbright pixels (palette 224+) pass through unrecolored: synthetic
-- 2x2 skin with one fullbright index
local tiny = buffer.create(4)
buffer.writeu8(tiny, 0, 100)
buffer.writeu8(tiny, 1, 240) -- fullbright
buffer.writeu8(tiny, 2, 100)
buffer.writeu8(tiny, 3, 100)
local tout = skinforge.camoPixels(tiny, 2, 2, pal, 1)
t.check(
	buffer.readu8(tout, 4) == pal.r[241] and buffer.readu8(tout, 5) == pal.g[241] and buffer.readu8(tout, 6) == pal.b[241],
	"fullbright index keeps its palette color"
)

--------------------------------------------------------------------------
-- optional preview dump for tools/preview_skin.py
if process.env.SKINFORGE_DUMP then
	local dir = process.env.SKINFORGE_DUMP
	fs.writeFile(`{dir}/v_shot_base_{w}x{h}.rgba`, buffer.tostring(base))
	fs.writeFile(`{dir}/v_shot_camo7_{w}x{h}.rgba`, buffer.tostring(a))
	fs.writeFile(`{dir}/v_shot_camo8_{w}x{h}.rgba`, buffer.tostring(c))
	for _, spec in specs do
		local label = spec:gsub(":%d+$", "")
		fs.writeFile(`{dir}/skin_{label}_{w}x{h}.rgba`, outputs[spec])
	end
	print(`dumped previews to {dir}`)
end

t.finish("test_skinforge")
