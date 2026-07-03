--!strict
-- Validates the WAD2/qpic/palette loaders against the real shareware gfx.wad
-- and gfx/*.lmp files.

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local wad = require("../src/shared/engine/gfx/wad")

local fsys = t.gameFs()

local wadbuf = vfs.loadFile(fsys, "gfx.wad")
assert(wadbuf)
local w = wad.load(wadbuf)

-- known lumps the status bar / console rely on
for _, name in { "conchars", "ibar", "sbar", "scorebar", "num_0", "num_9", "sb_shells", "disc" } do
	local ok = pcall(wad.getLump, w, name)
	t.check(ok, "lump present: " .. name)
end

-- CONCHARS is stored uppercase on disk; cleanup must find it lowercase
local conchars = wad.getLump(w, "CONCHARS")
t.eq(conchars.size, 128 * 128, "conchars size")

local sbar = wad.getPic(w, "sbar")
t.eq(sbar.width, 320, "sbar width")
t.eq(sbar.height, 24, "sbar height")
t.eq(buffer.len(sbar.pixels), 320 * 24, "sbar pixels")

local num0 = wad.getPic(w, "num_0")
t.eq(num0.height, 24, "num_0 height")

-- palette
local palbuf = vfs.loadFile(fsys, "gfx/palette.lmp")
assert(palbuf)
local pal = wad.parsePalette(palbuf)
t.eq(pal.r[1], 0, "palette entry 0 black r")
t.eq(pal.g[1], 0, "palette entry 0 black g")
t.eq(pal.b[1], 0, "palette entry 0 black b")
-- entry 254 is the full-bright pink/white end of the quake palette
t.check(pal.r[255] > 200, "palette bright end")
-- entry 15 (index 14) in quake palette is white-ish grey ramp end
t.check(pal.r[16] == pal.g[16] and pal.g[16] == pal.b[16], "grey ramp is grey")

-- standalone qpic lmp files
local complete = vfs.loadFile(fsys, "gfx/complete.lmp")
assert(complete)
local pic = wad.parseQPic(complete)
t.check(pic.width > 0 and pic.height > 0, "complete.lmp dims")
t.eq(buffer.len(complete), 8 + pic.width * pic.height, "complete.lmp exact size")

local conback = vfs.loadFile(fsys, "gfx/conback.lmp")
assert(conback)
local cb = wad.parseQPic(conback)
t.eq(cb.width, 320, "conback width")
t.eq(cb.height, 200, "conback height")

t.finish("test_wad")
