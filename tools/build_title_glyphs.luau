--!strict
-- One-off: extract the LibreQuake conchars glyphs for "FRAG PARTY" and
-- emit a baked Luau pixel table for the ReplicatedFirst loading screen
-- (which must stay free of remote assets). Regenerate after changing the title text; run from repo root:
--   lune run tools/build_title_glyphs.luau

local fs = require("@lune/fs")
local pak = require("../src/shared/engine/common/pak")
local vfslib = require("../src/shared/engine/common/vfs")
local wadlib = require("../src/shared/engine/gfx/wad")

local ROOT = "/Users/tdimson/projects/robloquake"
local gamefs = vfslib.new()
for i = 0, 2 do
	local path = `{ROOT}/external_assets/librequake/full/id1/pak{i}.pak`
	if fs.isFile(path) then
		vfslib.addPack(gamefs, pak.load(`id1/pak{i}.pak`, buffer.fromstring(fs.readFile(path))))
	end
end

local wadbuf = assert(vfslib.loadFile(gamefs, "gfx.wad"), "gfx.wad missing")
local conchars = wadlib.getRaw(wadlib.load(wadbuf), "conchars")
local palbuf = assert(vfslib.loadFile(gamefs, "gfx/palette.lmp"), "palette missing")

-- gold plaque tint carried over from the old TextLabel title
local TINT = { 214 / 255, 168 / 255, 116 / 255 }

local TITLE = "FRAG PARTY"
local seen: { [string]: boolean } = {}
local colorList: { string } = {}
local colorIdx: { [string]: number } = {}
local glyphOut: { string } = {}

for ci = 1, #TITLE do
	local ch = TITLE:sub(ci, ci)
	if ch == " " or seen[ch] then
		continue
	end
	seen[ch] = true
	local code = ch:byte()
	local row, col = math.floor(code / 16), code % 16
	local px: { string } = {}
	for y = 0, 7 do
		for x = 0, 7 do
			local idx = buffer.readu8(conchars, (row * 8 + y) * 128 + (col * 8 + x))
			if idx ~= 0 then
				local r = buffer.readu8(palbuf, idx * 3)
				local g = buffer.readu8(palbuf, idx * 3 + 1)
				local b = buffer.readu8(palbuf, idx * 3 + 2)
				local key = string.format(
					"Color3.fromRGB(%d, %d, %d)",
					math.floor(r * TINT[1] + 0.5),
					math.floor(g * TINT[2] + 0.5),
					math.floor(b * TINT[3] + 0.5)
				)
				if not colorIdx[key] then
					table.insert(colorList, key)
					colorIdx[key] = #colorList
				end
				table.insert(px, string.format("%d,%d,%d", x, y, colorIdx[key]))
			end
		end
	end
	table.insert(glyphOut, string.format('\t["%s"] = "%s",', ch, table.concat(px, ";")))
end

print("local TITLE_COLORS = {")
for _, c in colorList do
	print("\t" .. c .. ",")
end
print("}")
print('-- "x,y,colorIndex" triples per lit pixel of each 8x8 conchars glyph')
print("local TITLE_GLYPHS: { [string]: string } = {")
for _, l in glyphOut do
	print(l)
end
print("}")
