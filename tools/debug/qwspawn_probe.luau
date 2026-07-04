local t = require("../../tests/testutil")
local fs = require("@lune/fs")
local vmlib = require("../../src/shared/engine/progs/vm")
local defs = require("../../src/shared/engine/progs/defs")
local qwsv = require("../../src/shared/engine/qw/qwsv")

local fsys = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(fsys, qwprogs)
qwsv.spawnServer(svr, "e1m1")
qwsv.connectClient(svr, 1, { name = "ranger" })
local vm = svr.vm
local player = svr.clients[1].edict
-- ED_Print: every nonzero field by the progs' own defs
for _, d in vm.progs.fielddefs do
	local typ = bit32.band(d.type, 0x7fff)
	local ofs = d.ofs
	if typ == defs.ev_float then
		local v = buffer.readf32(player.fields, ofs * 4)
		if v ~= 0 and (d.name == "health" or d.name == "max_health" or d.name == "takedamage" or d.name == "movetype" or d.name == "solid" or d.name == "gravity") then
			print(("%-14s %s"):format(d.name, v))
		end
	elseif typ == defs.ev_string then
		local id = buffer.readi32(player.fields, ofs * 4)
		if id ~= 0 and (d.name == "classname" or d.name == "netname" or d.name == "model") then
			print(("%-14s %q"):format(d.name, vmlib.getString(vm, id)))
		end
	end
end
print("origin:", vmlib.edVector(player, svr.qdefs.ent.origin))
print("qdefs health ofs:", svr.qdefs.ent.health)
