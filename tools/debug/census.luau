--!strict
local t = require("../../tests/testutil")
local defs = require("../../src/shared/engine/progs/defs")
local vmlib = require("../../src/shared/engine/progs/vm")
local host = require("../../src/shared/engine/server/host")

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(s: string)
	print("[sv] " .. s)
end
host.spawnServer(svr, "e1m1")
local vm = svr.vm
local counts: { [string]: number } = {}
for i = 0, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free then
		local cn = vmlib.edString(vm, e, defs.ent.classname)
		counts[cn] = (counts[cn] or 0) + 1
	end
end
local keys = {}
for k in counts do
	table.insert(keys, k)
end
table.sort(keys)
for _, k in keys do
	print(k, counts[k])
end
print("num_edicts", vm.num_edicts)
local styles = {}
for k in svr.lightstyles do
	table.insert(styles, k)
end
table.sort(styles)
print("styles set:", table.concat(styles, ","))
