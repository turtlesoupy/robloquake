--!strict
-- Validates the Mod_LoadTextures '+' animation sequencing (bsp.luau) and the
-- R_TextureAnimation frame selection against real pak0 maps: e1m2 has the
-- 4-frame +0button..+3button chain with the +abutton alternate, start has
-- the 7-frame +0slip..+6slip chain with no alternate.

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local bsp = require("../src/shared/engine/bsp/bsp")

local fsys = t.gameFs()

local function loadWorld(map: string): bsp.BspData
	local buf = vfs.loadFile(fsys, `maps/{map}.bsp`)
	assert(buf, `{map}.bsp present`)
	return bsp.load(`maps/{map}.bsp`, buf)[1].brush
end

local function findTexture(data: bsp.BspData, name: string): bsp.Texture
	for _, tex in data.textures do
		if tex and tex.name == name then
			return tex
		end
	end
	error(`texture {name} not found`)
end

-- R_TextureAnimation for a world surface (currententity->frame == 0)
local function textureAnimation(base: bsp.Texture, time: number): bsp.Texture
	if base.anim_total == 0 then
		return base
	end
	local reletive = math.floor(time * 10) % base.anim_total
	local tex = base
	local count = 0
	while tex.anim_min > reletive or tex.anim_max <= reletive do
		local nxt = tex.anim_next
		assert(nxt, "R_TextureAnimation: broken cycle")
		tex = nxt
		count += 1
		assert(count <= 100, "R_TextureAnimation: infinite cycle")
	end
	return tex
end

--------------------------------------------------------------------------
-- e1m2: base chain +0button..+3button, alternate chain +abutton

local e1m2 = loadWorld("e1m2")
local button = findTexture(e1m2, "+0button")

-- (1) the chain is a cycle with anim_total = 4 frames * ANIM_CYCLE (2)
t.eq(button.anim_total, 8, "+0button anim_total")
local names = {}
local cur: bsp.Texture? = button
for _ = 1, 4 do
	assert(cur, "chain link present")
	table.insert(names, cur.name)
	cur = cur.anim_next
end
t.eq(table.concat(names, ","), "+0button,+1button,+2button,+3button", "base chain order")
t.eq(cur, button, "base chain closes back on +0button")

-- (2) chain ordering matches the +N digits: frame j owns [2j, 2j+2)
cur = button
for j = 0, 3 do
	assert(cur)
	t.eq(cur.anim_min, j * 2, `{cur.name} anim_min`)
	t.eq(cur.anim_max, (j + 1) * 2, `{cur.name} anim_max`)
	t.eq(cur.anim_total, 8, `{cur.name} anim_total`)
	cur = cur.anim_next
end

-- (3) the alternate (+a) chain links from every base frame and back
local alt = button.alternate_anims
assert(alt, "+0button has an alternate chain")
t.eq(alt.name, "+abutton", "alternate is +abutton")
t.eq(alt.anim_total, 2, "+abutton anim_total (1 frame)")
t.eq(alt.anim_min, 0, "+abutton anim_min")
t.eq(alt.anim_max, 2, "+abutton anim_max")
t.eq(alt.anim_next, alt, "+abutton single-frame chain cycles to itself")
local altBack = alt.alternate_anims
assert(altBack, "+abutton links back to the base chain")
t.eq(altBack.name, "+0button", "+abutton alternate is +0button")
cur = button
for _ = 1, 4 do
	assert(cur)
	t.eq(cur.alternate_anims, alt, `{cur.name} alternate_anims`)
	cur = cur.anim_next
end

-- R_TextureAnimation picks frame floor(tick/2) % 4 of the base chain
for tick = 0, 15 do
	local want = `+{math.floor(tick / 2) % 4}button`
	t.eq(textureAnimation(button, tick / 10).name, want, `tick {tick} frame`)
end
-- entering the chain from a non-zero frame lands on the same tick frame
local button2 = findTexture(e1m2, "+2button")
t.eq(textureAnimation(button2, 0).name, "+0button", "chain entry from +2button, tick 0")
t.eq(textureAnimation(button2, 0.7).name, "+3button", "chain entry from +2button, tick 7")

--------------------------------------------------------------------------
-- start: 7-frame +slip chain, no alternate

local start = loadWorld("start")
local slip = findTexture(start, "+0slip")
t.eq(slip.anim_total, 14, "+0slip anim_total (7 frames)")
t.check(slip.alternate_anims == nil, "+0slip has no alternate chain")
names = {}
cur = slip
for _ = 1, 7 do
	assert(cur, "slip chain link present")
	table.insert(names, cur.name)
	t.check(cur.alternate_anims == nil, `{cur.name} has no alternate chain`)
	cur = cur.anim_next
end
t.eq(table.concat(names, ","), "+0slip,+1slip,+2slip,+3slip,+4slip,+5slip,+6slip", "slip chain order")
t.eq(cur, slip, "slip chain closes back on +0slip")

t.finish("test_texanim")
