--!strict
-- Validates the BSP29 loader against real e1m1.bsp data. Expected values come
-- from tools/dump_bsp_truth.py, an independent struct-level parse of the
-- same file (no shared code with the Luau port).

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local bsp = require("../src/shared/engine/bsp/bsp")

local fsys = t.gameFs()
local buf = vfs.loadFile(fsys, "maps/e1m1.bsp")
assert(buf, "e1m1.bsp present")

local models = bsp.load("maps/e1m1.bsp", buf)
local world = models[1]
local data = world.brush

t.eq(#models, 58, "model count")
t.eq(#data.planes, 1810, "plane count")
t.eq(#data.vertexes, 7358, "vertex count")
t.eq(#data.nodes, 2750, "node count")
t.eq(#data.texinfo, 489, "texinfo count")
t.eq(#data.surfaces, 5516, "face count")
t.eq(data.numclipnodes, 5408, "clipnode count")
t.eq(#data.leafs, 1531, "leaf count")
t.eq(#data.marksurfaces, 7073, "marksurface count")
t.eq(#data.edges0, 13497, "edge count")
t.eq(#data.surfedges, 26702, "surfedge count")
local lightdata = data.lightdata
assert(lightdata)
t.eq(buffer.len(lightdata), 168590, "light bytes")
local visdata = data.visdata
assert(visdata)
t.eq(buffer.len(visdata), 40843, "vis bytes")
t.eq(data.numtextures, 81, "miptex count")

-- textures
local tex0 = data.textures[1]
assert(tex0)
t.eq(tex0.name, "slipbotsd", "tex0 name")
t.eq(tex0.width, 16, "tex0 width")
t.eq(tex0.height, 64, "tex0 height")
t.eq(buffer.len(tex0.pixels), 16 * 64 / 64 * 85, "tex0 mip chain size")
t.eq(tex0.offsets[1], 0, "tex0 mip0 offset")
local tex40 = data.textures[41]
assert(tex40)
t.eq(tex40.name, "tech11_2", "tex40 name")
local tex80 = data.textures[81]
assert(tex80)
t.eq(tex80.name, "+abasebtn", "tex80 name")
t.check(tex80.anim_total > 0, "+abasebtn sequenced")

-- spot values
local p100 = data.planes[101]
t.check(math.abs(p100.normal.x - 0.707107) < 1e-6, "plane100 nx")
t.check(math.abs(p100.normal.y + 0.707107) < 1e-6, "plane100 ny")
t.eq(p100.normal.z, 0, "plane100 nz")
t.check(math.abs(p100.dist - -1991.21) < 0.01, "plane100 dist")
t.eq(p100.type, 3, "plane100 type")
t.eq(p100.signbits, 2, "plane100 signbits")

local v500 = data.vertexes[501]
t.check(v500 == vector.create(1392, 2048, -456), "vert500")

local n200 = data.nodes[201]
t.eq(n200.planenum, 119, "node200 plane")
t.eq(n200.children[1], 201, "node200 child0")
t.eq(n200.children[2], -66, "node200 child1")

t.eq(data.clipnodes.planenum[301], 290, "clipnode300 plane")
t.eq(data.clipnodes.child0[301], 301, "clipnode300 child0")
t.eq(data.clipnodes.child1[301], 316, "clipnode300 child1")

local l100 = data.leafs[101]
t.eq(l100.contents, -1, "leaf100 contents")
t.eq(l100.visofs, 3241, "leaf100 visofs")

-- world model setup (mins/maxs spread by 1 pixel: -608 vs disk -607)
t.check(world.mins == vector.create(-608, -432, -608), "world mins")
t.check(world.maxs == vector.create(1520, 3072, 288), "world maxs")
t.eq(world.numleafs, 1148, "world visleafs")
t.eq(world.firstmodelsurface, 0, "world firstface")
t.eq(world.nummodelsurfaces, 5059, "world numfaces")
t.eq(world.hulls[1].firstclipnode, 0, "world hull0 head")
t.eq(world.hulls[2].firstclipnode, 0, "world hull1 head")
t.eq(world.hulls[3].firstclipnode, 2970, "world hull2 head")
t.eq(world.hulls[1].lastclipnode, 2749, "hull0 lastclipnode")
t.eq(world.hulls[2].lastclipnode, 5407, "hull1 lastclipnode")
t.check(world.hulls[2].clip_mins == vector.create(-16, -16, -24), "hull1 clip_mins")
t.check(world.hulls[3].clip_maxs == vector.create(32, 32, 64), "hull2 clip_maxs")

-- submodel *1
local m1 = models[2]
t.eq(m1.name, "*1", "model1 name")
t.eq(m1.hulls[1].firstclipnode, 2355, "model1 hull0 head")
t.eq(m1.hulls[2].firstclipnode, 2556, "model1 hull1 head")
t.eq(m1.hulls[3].firstclipnode, 4994, "model1 hull2 head")
t.eq(m1.firstmodelsurface, 5059, "model1 firstface")
t.eq(m1.nummodelsurfaces, 14, "model1 numfaces")
t.check(m1.brush == data, "submodels share BspData")

-- faces incl. CalcSurfaceExtents
local function checkFace(fi: number, planenum: number, sideback: boolean, numedges: number, ti: number, tm0: number, tm1: number, e0: number, e1: number, lightofs: number)
	local f = data.surfaces[fi + 1]
	t.eq(f.planenum, planenum, `face{fi} plane`)
	t.eq(bit32.band(f.flags, bsp.SURF_PLANEBACK) ~= 0, sideback, `face{fi} side`)
	t.eq(f.numedges, numedges, `face{fi} edges`)
	t.eq(f.texinfonum, ti, `face{fi} texinfo`)
	t.eq(f.texturemins[1], tm0, `face{fi} tmins0`)
	t.eq(f.texturemins[2], tm1, `face{fi} tmins1`)
	t.eq(f.extents[1], e0, `face{fi} extents0`)
	t.eq(f.extents[2], e1, `face{fi} extents1`)
	t.eq(f.styles[1], 0, `face{fi} style0`)
	t.eq(f.styles[2], 255, `face{fi} style1`)
	t.eq(f.lightofs, lightofs, `face{fi} lightofs`)
end
checkFace(0, 0, false, 6, 13, 384, -192, 32, 192, 152)
checkFace(1000, 165, false, 5, 170, 2112, 352, 128, 112, 31144)
checkFace(2000, 312, true, 5, 61, 736, -1872, 16, 16, 69516)

-- entities lump
t.check(data.entities:find('"classname" "worldspawn"', 1, true) ~= nil, "worldspawn present")
t.check(data.entities:find('"origin" "480 -352 88"', 1, true) ~= nil, "player start present")

-- pointInLeaf: the player spawn is in empty space, deep solid is leaf 0
local spawn = vector.create(480, -352, 88)
local spawnLeaf = bsp.pointInLeaf(spawn, world)
t.eq(spawnLeaf.contents, bsp.CONTENTS_EMPTY, "spawn leaf empty")
local solidLeaf = bsp.pointInLeaf(vector.create(-10000, -10000, -10000), world)
t.eq(solidLeaf.num, 0, "far point in solid leaf 0")
t.eq(solidLeaf.contents, bsp.CONTENTS_SOLID, "solid leaf contents")

-- PVS: row length, self-visibility, and solid leaf gives all-visible
local pvs = bsp.leafPVS(spawnLeaf, world)
t.eq(buffer.len(pvs), bit32.rshift(1148 + 7, 3), "pvs row size")
local selfBit = spawnLeaf.num - 1
t.check(bit32.band(buffer.readu8(pvs, bit32.rshift(selfBit, 3)), bit32.lshift(1, bit32.band(selfBit, 7))) ~= 0, "leaf sees itself")
local novis = bsp.leafPVS(solidLeaf, world)
t.eq(buffer.readu8(novis, 0), 0xff, "solid leaf pvs all visible")

-- hull0 decode: children that were leaves must now be contents (< 0 means
-- CONTENTS_*, never an encoded leaf reference that could exceed -15)
for i = 1, #data.nodes do
	local c0 = data.hull0.child0[i]
	local c1 = data.hull0.child1[i]
	t.check(c0 >= -14 and c0 <= #data.nodes - 1, "hull0 child0 range " .. i)
	t.check(c1 >= -14 and c1 <= #data.nodes - 1, "hull0 child1 range " .. i)
end

-- load every other map in the pak to shake out format assumptions
for _, e in t.loadPak0().entries do
	if e.name:sub(1, 5) == "maps/" and e.name:sub(-4) == ".bsp" then
		local mbuf = vfs.loadFile(fsys, e.name)
		assert(mbuf)
		local ms = bsp.load(e.name, mbuf)
		t.check(#ms >= 1, e.name .. " loads")
	end
end

t.finish("test_bsp")
