--!strict
-- SHIP BUNDLE CHECK: the chunked assets/arena bundle (built by
-- tools/build_assets.py --game arena --source external_assets/rocketarena)
-- boots the QW server exactly the way the runtime consumes it: base64
-- chunk reassembly -> pak.load -> searchpath qwprogs.dat -> spawnServer.
-- Also proves the mod's rotate.cfg rotation cycle is closed and every map
-- in it ships in the bundle (qwserver applies those localinfo pairs at
-- boot). Skips when the bundle or the base-game assets aren't built.
local t = require("./testutil")
local fs = require("@lune/fs")
local base64 = require("../src/shared/engine/common/base64")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local cvarlib = require("../src/shared/engine/common/cvar")
local qwsv = require("../src/shared/engine/qw/qwsv")

if not fs.isDir("assets/arena") or not fs.isDir("assets/id1") then
	print("test_arena_bundle: SKIPPED (assets/arena or assets/id1 not built)")
	return
end

local function loadChunked(dir: string): buffer
	local names = {}
	for _, n in fs.readDir(dir) do
		if n:match("^c%d+%.txt$") then
			table.insert(names, n)
		end
	end
	table.sort(names)
	local parts = {}
	for _, n in names do
		table.insert(parts, buffer.tostring(base64.decode(fs.readFile(dir .. "/" .. n))))
	end
	return buffer.fromstring(table.concat(parts))
end

local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("id1/" .. name, loadChunked("assets/id1/" .. name)))
end
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("arena/" .. name, loadChunked("assets/arena/" .. name)))
end

-- qwprogs.dat must resolve to RA's from the synthetic pak (mod over base)
local bundleProgs = vfs.loadFile(fsys, "qwprogs.dat")
t.check(bundleProgs ~= nil, "qwprogs.dat resolves from the bundle searchpath")
if fs.isFile("external_assets/rocketarena/qwprogs.dat") then
	local raProgs = fs.readFile("external_assets/rocketarena/qwprogs.dat")
	t.eq(buffer.len(bundleProgs :: buffer), #raProgs, "searchpath qwprogs.dat is RA's build")
end

local svr = qwsv.newGame(fsys)
svr.print = function(_s: string) end
cvarlib.setValue(svr.cvars, "deathmatch", 1)
qwsv.spawnServer(svr, "crandome")
t.check(svr.active == true, "arena bundle spawns the preset startmap (crandome)")

-- walk the rotate.cfg cycle (same parse as the qwserver boot step):
-- starting from the preset startmap, every hop must name a map shipped in
-- the bundle, and the chain must loop back to the start
local rotate = buffer.tostring(vfs.loadFile(fsys, "rotate.cfg") :: buffer)
local chain: { [string]: string } = {}
for k, v in rotate:gmatch("localinfo%s+(%S+)%s+(%S+)") do
	chain[k] = v
end
local start = "crandome"
local cur = start
local hops = 0
local broken: string? = nil
repeat
	local nxt = chain[cur]
	if not nxt or not vfs.loadFile(fsys, `maps/{nxt}.bsp`) then
		broken = cur
		break
	end
	cur = nxt
	hops += 1
until cur == start or hops >= 100
t.check(broken == nil and cur == start, `rotate.cfg cycle closed with all maps in bundle (broke at: {broken})`)
t.check(hops >= 40, "rotation cycle covers the Final Arena map set")

t.finish("test_arena_bundle")
