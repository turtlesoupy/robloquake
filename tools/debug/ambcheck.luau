local t = require("../../tests/testutil")
local vfslib = require("../../src/shared/engine/common/vfs")
local bsplib = require("../../src/shared/engine/bsp/bsp")
local fsys = t.gameFs()
for _, mapname in { "maps/e1m1.bsp", "maps/dm3.bsp" } do
	local buf = vfslib.loadFile(fsys, mapname)
	if buf then
		local model = bsplib.load(mapname, buf)[1]
		local counts = { 0, 0, 0, 0 }
		local n = 0
		for _, leaf in model.brush.leafs do
			local a = leaf.ambient
			if a then
				for i = 1, 4 do
					if a[i] > 0 then counts[i] += 1 end
				end
				n += 1
			end
		end
		print(mapname, "leafs:", n, "water/sky/slime/lava ambient counts:", table.concat(counts, "/"))
		-- find a few strong water-ambient leafs and print standable centers
		local shown = 0
		for _, leaf in model.brush.leafs do
			if leaf.ambient and leaf.ambient[1] > 150 and leaf.contents == -1 and shown < 4 then
				local mm = leaf.minmaxs
				print(("  loud water leaf: center=(%d,%d,%d) level=%d"):format(
					(mm[1] + mm[4]) / 2, (mm[2] + mm[5]) / 2, (mm[3] + mm[6]) / 2, leaf.ambient[1]))
				shown += 1
			end
		end
	end
end
