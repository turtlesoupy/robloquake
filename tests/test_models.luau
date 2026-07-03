--!strict
-- Validates the MDL/SPR loaders against real shareware models. Ground truth
-- from an independent Python struct parse (see session tooling).

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local mdl = require("../src/shared/engine/models/mdl")
local spr = require("../src/shared/engine/models/spr")

local fsys = t.gameFs()

local function loadMdl(name: string): mdl.AliasModel
	local buf = vfs.loadFile(fsys, name)
	assert(buf, name .. " present")
	return mdl.load(name, buf)
end

-- player.mdl
local player = loadMdl("progs/player.mdl")
t.eq(#player.skins, 1, "player skins")
t.eq(player.skinwidth, 296, "player skinwidth")
t.eq(player.skinheight, 194, "player skinheight")
t.eq(player.numverts, 212, "player verts")
t.eq(player.numtris, 408, "player tris")
t.eq(player.numframes, 143, "player frames")
t.eq(player.synctype, 1, "player synctype")
t.eq(player.flags, 0, "player flags")
t.check(math.abs(player.scale.x - 0.385473) < 1e-5, "player scale x")
t.check(math.abs(player.scale_origin.x - -52.7654) < 1e-3, "player scale_origin x")
t.check(math.abs(player.boundingradius - 85.0587) < 1e-3, "player radius")
t.check(math.abs(player.size - 9.78998 / 11) < 1e-4, "player size (ratio applied)")
t.eq(player.frames[1].name, "axrun1", "player frame0 name")
t.check(player.frames[1].bboxmin == vector.create(68, 96, 23), "player frame0 bboxmin")
t.check(player.frames[1].bboxmax == vector.create(200, 181, 186), "player frame0 bboxmax")
local skin0 = player.skins[1]
local pixels = skin0.pixels
assert(pixels)
t.eq(buffer.len(pixels), 296 * 194, "player skin size")
-- vert0 = (124, 141, 105, ni=29)
local pos0, ni0 = mdl.frameVert(player, player.frames[1].frames[1], 1)
t.eq(ni0, 29, "player vert0 normal index")
t.check(math.abs(pos0.x - (124 * 0.385473 + -52.7654)) < 1e-3, "player vert0 x unpack")

-- armor.mdl: 3 skins, EF_ROTATE flag
local armor = loadMdl("progs/armor.mdl")
t.eq(#armor.skins, 3, "armor skins")
t.eq(armor.flags, mdl.EF_ROTATE, "armor EF_ROTATE")
t.eq(armor.numframes, 1, "armor frames")
t.eq(armor.frames[1].name, "armor", "armor frame name")

-- soldier.mdl
local soldier = loadMdl("progs/soldier.mdl")
t.eq(soldier.numverts, 170, "soldier verts")
t.eq(soldier.numtris, 328, "soldier tris")
t.eq(soldier.numframes, 114, "soldier frames")
t.eq(soldier.frames[1].name, "stand1", "soldier frame0 name")
t.eq(#soldier.vertindex, 328 * 3, "soldier vertindex len")
-- all vertex indices must be in range
local maxIdx = 0
for _, vi in soldier.vertindex do
	if vi > maxIdx then
		maxIdx = vi
	end
	t.check(vi >= 0 and vi < 170, "soldier vertindex range")
end
t.check(maxIdx == 169, "soldier uses all verts")

-- every mdl in the pak loads
local count = 0
for _, e in t.loadPak0().entries do
	if e.name:sub(-4) == ".mdl" then
		local ok, err = pcall(loadMdl, e.name)
		t.check(ok, e.name .. " loads: " .. tostring(err))
		count += 1
	end
end
t.eq(count, 61, "mdl count in pak0")

-- sprites
local function loadSpr(name: string): spr.SpriteModel
	local buf = vfs.loadFile(fsys, name)
	assert(buf, name .. " present")
	return spr.load(name, buf)
end

local explod = loadSpr("progs/s_explod.spr")
t.eq(explod.type, spr.SPR_VP_PARALLEL, "s_explod type")
t.eq(explod.maxwidth, 56, "s_explod maxwidth")
t.eq(explod.numframes, 6, "s_explod frames")
local ef0 = explod.frames[1].frames[1]
t.eq(ef0.width, 56, "s_explod f0 w")
t.eq(ef0.left, -28, "s_explod f0 left")
t.eq(ef0.up, 28, "s_explod f0 up")
t.eq(ef0.down, 28 - 56, "s_explod f0 down")
t.eq(buffer.len(ef0.pixels), 56 * 56, "s_explod f0 pixels")

for _, name in { "progs/s_bubble.spr", "progs/s_light.spr" } do
	local ok = pcall(loadSpr, name)
	t.check(ok, name .. " loads")
end

t.finish("test_models")
