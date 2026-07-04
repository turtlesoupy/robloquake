local fs = require("@lune/fs")
local progslib = require("../../src/shared/engine/progs/progs")
local qwdefslib = require("../../src/shared/engine/qw/qwdefs")
local data = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local progs = progslib.load(data, 54730)
local ok, defsOrErr = pcall(qwdefslib.build, progs)
if not ok then
	print("BUILD FAILED:", defsOrErr)
else
	local d = defsOrErr
	local ng, ne, nf = 0, 0, 0
	for _ in d.glob do ng += 1 end
	for _ in d.ent do ne += 1 end
	for _ in d.func do nf += 1 end
	print(("qwdefs OK: %d globals, %d fields, %d entry funcs"):format(ng, ne, nf))
	print("self:", d.glob.self, "time:", d.glob.time, "origin:", d.ent.origin, "PutClientInServer:", d.func.PutClientInServer)
end
