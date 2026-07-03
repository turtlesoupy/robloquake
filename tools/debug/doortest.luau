--!strict
-- Verify doors end-to-end: trigger a door's use function, run frames, and
-- confirm the client receives the moving origin.
local t = require("../../tests/testutil")
local cllib = require("../../src/shared/engine/client/cl")
local defs = require("../../src/shared/engine/progs/defs")
local vmlib = require("../../src/shared/engine/progs/vm")
local host = require("../../src/shared/engine/server/host")

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

local c = cllib.new("T", 0)
c.print = function(_s: string) end
local sc = svr.clients[1]
sc.sendUnreliable = function(d: buffer) cllib.parseServerMessage(c, d); return true end
sc.sendReliable = function(d: buffer) cllib.parseServerMessage(c, d); return true end
host.connectClient(svr, 1)
local function pump()
	local rel = cllib.takeReliable(c)
	if rel then table.insert(sc.inbox, rel) end
	host.frame(svr, 0.05)
end
for _ = 1, 8 do pump() end
assert(c.signon == cllib.SIGNONS, "signed on")

-- pick a door and fire its use function (like a trigger targeting it)
local doorNum, doorUse
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, defs.ent.classname) == "door" then
		local fn = vmlib.edInt(e, defs.ent.use)
		if fn ~= 0 then
			doorNum, doorUse = i, fn
			break
		end
	end
end
assert(doorNum, "found usable door")
print("door", doorNum, "use fn", vm.progs.functions[doorUse + 1].name)

local before = vmlib.edVector(vm.edicts[doorNum + 1], defs.ent.origin)
-- fire: self = door, other/activator = player
buffer.writef32(vm.globals, defs.glob.time * 4, svr.time)
buffer.writei32(vm.globals, defs.glob.self * 4, doorNum)
buffer.writei32(vm.globals, defs.glob.other * 4, 1)
-- activator is a QC global (not in progdefs); find by name
local adef = vm.progs.globaldefsByName["activator"]
if adef then
	buffer.writei32(vm.globals, adef.ofs * 4, 1)
end
vmlib.exec(vm, doorUse)

-- run 1.5s of frames; watch server origin and client entity
for _ = 1, 30 do pump() end
local after = vmlib.edVector(vm.edicts[doorNum + 1], defs.ent.origin)
print(("server door origin: (%g,%g,%g) -> (%g,%g,%g) moved=%g"):format(before.x,before.y,before.z,after.x,after.y,after.z,vector.magnitude(after-before)))
local clEnt = c.entities[doorNum]
if clEnt then
	print(("client door origin: (%g,%g,%g) fresh=%s"):format(clEnt.origin.x, clEnt.origin.y, clEnt.origin.z, tostring(clEnt.msgtime == c.mtime0)))
else
	print("client has no entity for door")
end
assert(vector.magnitude(after - before) > 10, "door moved on server")
