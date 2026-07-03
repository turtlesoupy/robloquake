--!strict
-- Validates the progs.dat loader and QuakeC interpreter against the real
-- shareware progs.dat. Ground truth from an independent Python struct parse.

local t = require("./testutil")
local vfs = require("../src/shared/engine/common/vfs")
local com = require("../src/shared/engine/common/com")
local progslib = require("../src/shared/engine/progs/progs")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")

local fsys = t.gameFs()
local buf = vfs.loadFile(fsys, "progs.dat")
assert(buf)

local pr = progslib.load(buf)

-- header / counts
t.eq(pr.headerCrc, 5927, "header crc")
t.eq(pr.crc, 46133, "file crc16")
t.eq(pr.numstatements, 20940, "statements")
t.eq(#pr.globaldefs, 4287, "globaldefs")
t.eq(#pr.fielddefs, 218, "fielddefs")
t.eq(#pr.functions, 2091, "functions")
t.eq(pr.numglobals, 11471, "globals")
t.eq(pr.entityfields, 195, "entityfields")

-- the transcribed ABI offsets must match the real progs' def tables
local function gdefAt(ofs: number): string?
	for _, d in pr.globaldefs do
		if d.ofs == ofs then
			return d.name
		end
	end
	return nil
end
for name, ofs in defs.glob :: { [string]: number } do
	t.eq(gdefAt(ofs), name, `globaldef @{ofs}`)
end
for name, ofs in defs.ent :: { [string]: number } do
	local d = pr.fielddefsByName[name]
	assert(d, "fielddef " .. name)
	t.eq(d.ofs, ofs, `fielddef {name} ofs`)
end

-- function table
local anglemod = pr.functionsByName.anglemod
assert(anglemod)
t.eq(anglemod, 90, "anglemod index")
t.eq(pr.functions[anglemod + 1].first_statement, 656, "anglemod first statement")
t.eq(pr.functionsByName.worldspawn, 209, "worldspawn index")
t.eq(pr.functionsByName.SUB_Null, 66, "SUB_Null index")

-- interpreter: anglemod is pure bytecode (loops + arithmetic, no builtins)
local vm = vmlib.new(pr, 600, 0)
vmlib.initEdicts(vm, 1)

local function callAnglemod(v: number): number
	vmlib.setGlobalFloat(vm, defs.OFS_PARM0, v)
	vmlib.exec(vm, anglemod)
	return vmlib.globalFloat(vm, defs.OFS_RETURN)
end
t.eq(callAnglemod(725), 5, "anglemod(725)")
t.eq(callAnglemod(-90), 270, "anglemod(-90)")
t.eq(callAnglemod(360), 0, "anglemod(360)")
t.eq(callAnglemod(359.5), 359.5, "anglemod(359.5)")
t.eq(callAnglemod(0), 0, "anglemod(0)")

-- SUB_Null runs and returns
vmlib.exec(vm, pr.functionsByName.SUB_Null :: number)
t.check(vm.depth == 0, "stack balanced after calls")

-- strings
t.eq(vmlib.getString(vm, 0), "", "null string")
local dyn = vmlib.newString(vm, "hello\\nworld")
t.eq(vmlib.getString(vm, dyn), "hello\nworld", "newString escape n")
local dyn2 = vmlib.newString(vm, "a\\tb")
t.eq(vmlib.getString(vm, dyn2), "a\\b", "newString other escape keeps backslash only")

-- COM_Parse
local sample = '// comment\n{ "classname" "worldspawn" }\n'
local tok, pos = com.parse(sample, 1)
t.eq(tok, "{", "parse brace")
tok, pos = com.parse(sample, pos)
t.eq(tok, "classname", "parse quoted key")
tok, pos = com.parse(sample, pos)
t.eq(tok, "worldspawn", "parse quoted value")
tok, pos = com.parse(sample, pos)
t.eq(tok, "}", "parse close")
tok = com.parse(sample, pos)
t.eq(tok, nil, "parse eof")

-- ED_ParseEdict on a real entity block (with anglehack)
local block = '"classname" "info_player_start"\n"origin" "480 -352 88"\n"angle" "90"\n}'
local ed2 = vmlib.alloc(vm)
vmlib.parseEdict(vm, block, 1, ed2)
t.eq(vmlib.edString(vm, ed2, defs.ent.classname), "info_player_start", "parsed classname")
t.check(vmlib.edVector(ed2, defs.ent.origin) == vector.create(480, -352, 88), "parsed origin")
t.check(vmlib.edVector(ed2, defs.ent.angles) == vector.create(0, 90, 0), "anglehack applied")

-- edict alloc/free
local before = vm.num_edicts
local e = vmlib.alloc(vm)
t.eq(vm.num_edicts, before + 1, "alloc grows")
vmlib.edSetFloat(e, defs.ent.solid, 3)
vmlib.free(vm, e)
t.check(e.free, "freed flag")
t.eq(vmlib.edFloat(e, defs.ent.solid), 0, "free clears solid")
t.eq(vmlib.edFloat(e, defs.ent.nextthink), -1, "free sets nextthink -1")

-- type punning: a float write must be readable as the same int bits
vmlib.setGlobalFloat(vm, defs.OFS_PARM0, -0.0)
t.check(vmlib.globalInt(vm, defs.OFS_PARM0) ~= 0, "-0.0 is a nonzero int (IFNOT semantics)")

t.finish("test_vm")
