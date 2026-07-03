--!strict
local t = require("../../tests/testutil")
local defs = require("../../src/shared/engine/progs/defs")
local vmlib = require("../../src/shared/engine/progs/vm")
local host = require("../../src/shared/engine/server/host")
local svlib = require("../../src/shared/engine/server/sv")
local msg = require("../../src/shared/engine/common/msg")
local bsp = require("../../src/shared/engine/bsp/bsp")

local ent = defs.ent
local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

-- how many non-free entities have modelindex and leafnums?
local withModel, withLeafs = 0, 0
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if e.free then continue end
	if vmlib.edFloat(e, ent.modelindex) ~= 0 then
		withModel += 1
		if e.num_leafs > 0 then withLeafs += 1 end
	end
end
print("withModel", withModel, "withLeafs", withLeafs)

-- pvs from spawn point
local spawn = vector.create(480, -352, 88 + 22)
local pvs = svlib.fatPVS(svr, spawn)
local bits = 0
for i = 0, buffer.len(pvs) - 1 do
	local b = buffer.readu8(pvs, i)
	while b ~= 0 do
		bits += b % 2
		b = math.floor(b / 2)
	end
end
print("fatpvs bits set:", bits, "of", svr.worldmodel.numleafs)

-- count entities passing the pvs test
local pass = 0
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if e.free or vmlib.edFloat(e, ent.modelindex) == 0 then continue end
	for j = 1, e.num_leafs do
		local ln = e.leafnums[j]
		if bit32.band(buffer.readu8(pvs, bit32.rshift(ln, 3)), bit32.lshift(1, bit32.band(ln, 7))) ~= 0 then
			pass += 1
			break
		end
	end
end
print("entities in pvs:", pass)

-- statics: count svc_spawnstatic (20) in signon
local sg = svr.signon
local count20, count29, count22 = 0, 0, 0
local i = 0
-- crude scan (statics/ambients written before baselines)
print("signon size", sg.cursize)
