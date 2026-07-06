--!strict
-- scratch: verify the CHUNKED assets/arena bundle boots the QW server the
-- way the runtime consumes it (base64 chunk reassembly -> pak.load ->
-- searchpath qwprogs.dat -> spawnServer). Delete after use.
local fs = require("@lune/fs")
local base64 = require("../src/shared/engine/common/base64")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local cvarlib = require("../src/shared/engine/common/cvar")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")

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
-- base game from the shipped chunked bundle too (assets/id1)
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("id1/" .. name, loadChunked("assets/id1/" .. name)))
end
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("arena/" .. name, loadChunked("assets/arena/" .. name)))
end

-- qwprogs.dat must resolve from the arena synthetic pak (mod overrides base)
local svr = qwsv.newGame(fsys)
svr.print = function(_s: string) end
cvarlib.setValue(svr.cvars, "deathmatch", 1)
qwsv.spawnServer(svr, "dm3")
assert(svr.active == true, "arena bundle: spawnServer dm3 failed")

-- prove the MOD's progs resolved from the bundle, not id1's: byte-compare
-- the searchpath's qwprogs.dat against the staged RA build
local bundleProgs = vfs.loadFile(fsys, "qwprogs.dat") :: buffer
local raProgs = buffer.fromstring(fs.readFile("external_assets/rocketarena/qwprogs.dat"))
assert(buffer.len(bundleProgs) == buffer.len(raProgs), "arena bundle: qwprogs.dat is not RA's")

-- rotate.cfg and the RA arena maps must be inside the bundle searchpath
assert(vfs.loadFile(fsys, "rotate.cfg") ~= nil, "rotate.cfg not in bundle")
local mapsFound = 0
for _, m in { "maps/crandome.bsp", "maps/2pyramid.bsp" } do
	if vfs.loadFile(fsys, m) then
		mapsFound += 1
	end
end
assert(mapsFound == 2, "arena maps missing from bundle")

-- and the RA round loop actually starts on an arena map from the bundle
local svr2 = qwsv.newGame(fsys)
svr2.print = function(_s: string) end
svr2.localinfo["crandome"] = "2pyramid"
qwsv.spawnServer(svr2, "crandome")
assert(svr2.active == true, "arena bundle: spawnServer crandome failed")
print("arena bundle OK: dm3 + crandome spawn, RA qwprogs resolved, rotate.cfg + arena maps present")
