--!strict
local t = require("../../tests/testutil")
local vfs = require("../../src/shared/engine/common/vfs")
local bsp = require("../../src/shared/engine/bsp/bsp")

local fsys = t.gameFs()
local buf = vfs.loadFile(fsys, "maps/e1m1.bsp") :: buffer
local models = bsp.load("maps/e1m1.bsp", buf)
local data = models[1].brush

for i = 1, #data.surfaces do
	local s = data.surfaces[i]
	local plane = data.planes[s.planenum + 1]
	if plane.type ~= 2 then -- PLANE_Z
		continue
	end
	local verts = {}
	local minx, maxx, miny, maxy, z = math.huge, -math.huge, math.huge, -math.huge, 0
	for e = 0, s.numedges - 1 do
		local se = data.surfedges[s.firstedge + e + 1]
		local v
		if se >= 0 then
			v = data.vertexes[data.edges0[se + 1] + 1]
		else
			v = data.vertexes[data.edges1[-se + 1] + 1]
		end
		table.insert(verts, v)
		minx = math.min(minx, v.x); maxx = math.max(maxx, v.x)
		miny = math.min(miny, v.y); maxy = math.max(maxy, v.y)
		z = v.z
	end
	if not (480 >= minx and 480 <= maxx and -352 >= miny and -352 <= maxy and math.abs(z - 48) < 20) then
		continue
	end
	local back = bit32.band(s.flags, bsp.SURF_PLANEBACK) ~= 0
	print(`face {i - 1} z={z} PLANEBACK={back} nverts={#verts} planeN={plane.normal} dist={plane.dist}`)
	local a, b, c = verts[1], verts[2], verts[3]
	print("quake fan normal:", vector.cross(b - a, c - a))
	local function rb(v: vector): vector
		return vector.create(v.x, v.z, -v.y)
	end
	local rn = vector.cross(rb(b) - rb(a), rb(c) - rb(a))
	print("roblox fan normal (v1,v2,v3 order):", rn, "→ visible from above needs +Y")
	break
end
