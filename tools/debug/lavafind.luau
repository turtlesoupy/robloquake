--!strict
-- find CONTENTS_LAVA leafs in maps/start.bsp and print points inside them
local t = require("../../tests/testutil")
local vfslib = require("../../src/shared/engine/common/vfs")
local bsplib = require("../../src/shared/engine/bsp/bsp")

local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/start.bsp")
assert(buf, "no start.bsp")
local models = bsplib.load("maps/start.bsp", buf)
local model = models[1]

local found = 0
for i, leaf in model.brush.leafs do
	if leaf.contents == -5 and found < 8 then -- CONTENTS_LAVA
		local mm = leaf.minmaxs
		local cx = (mm[1] + mm[4]) / 2
		local cy = (mm[2] + mm[5]) / 2
		local cz = (mm[3] + mm[6]) / 2
		print(("lava leaf %d center=(%.0f, %.0f, %.0f) size=(%.0f, %.0f, %.0f)"):format(
			i, cx, cy, cz, mm[4] - mm[1], mm[5] - mm[2], mm[6] - mm[3]))
		found += 1
	end
end
print("total shown:", found)
