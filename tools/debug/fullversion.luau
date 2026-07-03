--!strict
local t = require("../../tests/testutil")
local vfs = require("../../src/shared/engine/common/vfs")
local pak = require("../../src/shared/engine/common/pak")
local fslib = require("@lune/fs")
local host = require("../../src/shared/engine/server/host")
local cvarlib = require("../../src/shared/engine/common/cvar")

local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	local data = buffer.fromstring(fslib.readFile("external_assets/quake106/extracted/id1/" .. name .. ".pak"))
	local pack = pak.load(name, data)
	vfs.addPack(fsys, pack)
	print(name .. ": " .. pack.numfiles .. " files")
end
print("pop.lmp:", vfs.fileLength(fsys, "gfx/pop.lmp"))
print("e2m1:", vfs.fileLength(fsys, "maps/e2m1.bsp"), "e4m8:", vfs.fileLength(fsys, "maps/e4m8.bsp"))

local svr = host.newGame(fsys, 4)
svr.print = function(s: string) print("[sv] " .. s) end
print("registered cvar:", cvarlib.value(svr.cvars, "registered"))
host.spawnServer(svr, "e2m1")
print("e2m1 spawned:", svr.active, "edicts:", svr.vm.num_edicts)
host.spawnServer(svr, "e4m3")
print("e4m3 spawned:", svr.active, "edicts:", svr.vm.num_edicts)
host.spawnServer(svr, "start")
print("start spawned:", svr.active)
