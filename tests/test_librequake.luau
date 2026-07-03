--!strict
-- Verify the engine runs LibreQuake (copyright-free content) end to end.
local fs = require("@lune/fs")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local progslib = require("../src/shared/engine/progs/progs")
local cllib = require("../src/shared/engine/client/cl")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")

local DIR = "external_assets/librequake/full/id1/"
if not fs.isFile(DIR .. "pak0.pak") then
	print("test_librequake: SKIPPED (no LibreQuake assets extracted)")
	return
end
local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	local data = buffer.fromstring(fs.readFile(DIR .. name .. ".pak"))
	local pack = pak.load(name, data)
	vfs.addPack(fsys, pack)
	print(name .. ".pak: " .. pack.numfiles .. " files")
end

-- list maps
local maps = {}
for _, p in { "pak0", "pak1" } do
end
local progsbuf = vfs.loadFile(fsys, "progs.dat")
assert(progsbuf, "progs.dat present")
local pr = progslib.load(progsbuf)
print(("progs.dat: crc=%d functions=%d entityfields=%d"):format(pr.crc, #pr.functions, pr.entityfields))

-- find the start map name
local candidates = { "start", "lqstart", "e1m1", "lq1m1" }
local svr = host.newGame(fsys, 4)
svr.print = function(s) print("[sv] " .. s) end
local started = nil
for _, m in candidates do
	if vfs.fileLength(fsys, "maps/" .. m .. ".bsp") > 0 then
		started = m
		break
	end
end
assert(started, "found a start map")
print("spawning " .. started)
host.spawnServer(svr, started)
assert(svr.active, "spawned")

-- census
local vm = svr.vm
local count, monsters = 0, 0
for i = 0, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free then
		count += 1
		if bit32.band(vmlib.edFloat(e, defs.ent.flags), 32) ~= 0 then
			monsters += 1
		end
	end
end
print(("edicts=%d monsters=%d models=%d sounds=%d"):format(count, monsters, #svr.model_precache, #svr.sound_precache))

-- connect a client and run a few seconds
local c = cllib.new("Libre", 0)
c.print = function(_s) end
local sc = svr.clients[1]
sc.sendUnreliable = function(d: buffer) cllib.parseServerMessage(c, d); return true end
sc.sendReliable = function(d: buffer) cllib.parseServerMessage(c, d); return true end
host.connectClient(svr, 1)
local function pump()
	local rel = cllib.takeReliable(c)
	if rel then table.insert(sc.inbox, rel) end
	host.frame(svr, 0.05)
end
for _ = 1, 10 do pump() end
assert(c.signon == cllib.SIGNONS, "client signed on")
print("levelname: " .. c.levelname)
for _ = 1, 100 do
	local mv = cllib.buildMove(c, 200, 0, 0, false, false, 0)
	if mv then table.insert(sc.inbox, mv) end
	pump()
end
print(("player health=%d alive after 5s of play"):format(c.stats[cllib.STAT_HEALTH]))
print("LIBREQUAKE OK")
