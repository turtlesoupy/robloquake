--!strict
-- M2 opener: can our progs loader digest qwprogs.dat, and what ABI does it carry?
local fs = require("@lune/fs")
local progslib = require("../../src/shared/engine/progs/progs")

local data = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local ok, progsOrErr = pcall(progslib.load, data, 54730)
if not ok then
	print("LOAD FAILED:", progsOrErr)
	return
end
local progs = progsOrErr
print("loaded qwprogs.dat")
print("crc:", progs.crc)
print("entityfields:", progs.entityfields)
print("functions:", #progs.functions, "globaldefs:", #progs.globaldefs, "fielddefs:", #progs.fielddefs)
-- NQ-vs-QW field offset comparison for a few load-bearing fields
for _, name in { "health", "origin", "velocity", "movetype", "solid", "touch", "think", "nextthink", "frame", "modelindex", "effects", "items" } do
	local d = progs.fielddefsByName[name]
	print(("field %-12s ofs=%s"):format(name, d and d.ofs or "MISSING"))
end
for _, name in { "self", "other", "time", "frametime", "force_retouch", "deathmatch", "coop", "serverflags" } do
	local d = progs.globaldefsByName[name]
	print(("global %-14s ofs=%s"):format(name, d and d.ofs or "MISSING"))
end
