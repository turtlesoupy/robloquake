--!strict
-- Validates the PAK parser and vfs against the real shareware pak0.pak,
-- cross-checked against an independent Python parse of the same file.

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local base64 = require("../src/shared/engine/common/base64")

local pack = t.loadPak0()

t.eq(pack.numfiles, 339, "pak0.pak entry count")

local fsys = t.gameFs()

t.eq(vfs.fileLength(fsys, "progs.dat"), 413116, "progs.dat length")
t.eq(vfs.fileLength(fsys, "gfx/palette.lmp"), 768, "palette length")
t.eq(vfs.fileLength(fsys, "maps/e1m1.bsp"), 1365176, "e1m1.bsp length")
t.eq(vfs.fileLength(fsys, "maps/start.bsp"), 1433792, "start.bsp length")
t.eq(vfs.fileLength(fsys, "gfx.wad"), 112828, "gfx.wad length")
t.eq(vfs.fileLength(fsys, "does/not/exist.txt"), -1, "missing file")

-- total payload should match python sum
local total = 0
for _, e in pack.entries do
	total += e.filelen
end
t.eq(total, 18256911, "total payload bytes")

-- progs.dat starts with version 6
local progs = vfs.loadFile(fsys, "progs.dat")
assert(progs)
t.eq(buffer.readi32(progs, 0), 6, "progs.dat version")

-- BSPs start with version 29
local bsp = vfs.loadFile(fsys, "maps/e1m1.bsp")
assert(bsp)
t.eq(buffer.readi32(bsp, 0), 29, "e1m1.bsp version")

-- base64 roundtrip over a real binary file (odd length exercises padding)
local wav = vfs.loadFile(fsys, "sound/items/r_item1.wav")
assert(wav, "r_item1.wav present")
for _, data in { wav, buffer.fromstring("a"), buffer.fromstring("ab"), buffer.fromstring(""), progs } do
	local enc = base64.encode(data)
	local dec = base64.decode(enc)
	t.check(buffer.tostring(dec) == buffer.tostring(data), "base64 roundtrip len=" .. buffer.len(data))
end

t.finish("test_pak")
