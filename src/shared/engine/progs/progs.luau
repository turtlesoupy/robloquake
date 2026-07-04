--!strict
--!optimize 2
-- progs.dat loading — port of PR_LoadProgs from pr_edict.c with the disk
-- structs from pr_comp.h. The interpreter itself lives in vm.luau.

local bufio = require("../common/bufio")
local com = require("../common/com")
local defs = require("./defs")

local progs = {}

export type Def = {
	type: number, -- etype_t, DEF_SAVEGLOBAL bit preserved for globaldefs
	ofs: number,
	name: string,
}

export type Function = {
	first_statement: number, -- negative numbers are builtins
	parm_start: number,
	locals: number, -- total cells of parms + locals
	name: string,
	file: string,
	numparms: number,
	parm_size: { number }, -- [8]
}

export type Progs = {
	crc: number, -- CRC16 of the whole file (pr_crc, sent to clients)
	headerCrc: number, -- progs->crc, must equal PROGHEADER_CRC
	numstatements: number,
	-- statements as parallel arrays, index = C statement number + 1
	st_op: { number },
	st_a: { number },
	st_b: { number },
	st_c: { number },
	functions: { Function }, -- index = C function number + 1
	functionsByName: { [string]: number }, -- name -> C function number
	globaldefs: { Def },
	globaldefsByName: { [string]: Def },
	fielddefs: { Def },
	fielddefsByName: { [string]: Def },
	strings: buffer, -- the static string blob; string_t = byte offset
	stringsSize: number,
	globals: buffer, -- numglobals 4-byte cells, mutated at runtime
	numglobals: number,
	entityfields: number,
}

function progs.load(buf: buffer, expectedHeaderCrc: number?): Progs
	local crc = com.crcBuffer(buf)

	local r = bufio.reader(buf)
	local version = r:i32()
	if version ~= defs.PROG_VERSION then
		error(`progs.dat has wrong version number ({version} should be {defs.PROG_VERSION})`)
	end
	local headerCrc = r:i32()
	if headerCrc ~= (expectedHeaderCrc or defs.PROGHEADER_CRC) then
		error("progs.dat system vars have been modified, progdefs.h is out of date")
	end

	local ofs_statements = r:i32()
	local numstatements = r:i32()
	local ofs_globaldefs = r:i32()
	local numglobaldefs = r:i32()
	local ofs_fielddefs = r:i32()
	local numfielddefs = r:i32()
	local ofs_functions = r:i32()
	local numfunctions = r:i32()
	local ofs_strings = r:i32()
	local numstrings = r:i32()
	local ofs_globals = r:i32()
	local numglobals = r:i32()
	local entityfields = r:i32()

	-- strings blob
	local strings = bufio.slice(buf, ofs_strings, numstrings)

	local function getString(sofs: number): string
		return bufio.cstring(strings, sofs)
	end

	-- statements
	local st_op = table.create(numstatements)
	local st_a = table.create(numstatements)
	local st_b = table.create(numstatements)
	local st_c = table.create(numstatements)
	r:seek(ofs_statements)
	for _ = 1, numstatements do
		table.insert(st_op, r:u16())
		table.insert(st_a, r:i16())
		table.insert(st_b, r:i16())
		table.insert(st_c, r:i16())
	end

	-- functions
	local functions: { Function } = table.create(numfunctions)
	local functionsByName: { [string]: number } = {}
	r:seek(ofs_functions)
	for i = 0, numfunctions - 1 do
		local first_statement = r:i32()
		local parm_start = r:i32()
		local locals = r:i32()
		r:skip(4) -- profile
		local s_name = r:i32()
		local s_file = r:i32()
		local numparms = r:i32()
		local parm_size = { r:u8(), r:u8(), r:u8(), r:u8(), r:u8(), r:u8(), r:u8(), r:u8() }
		local name = getString(s_name)
		table.insert(functions, {
			first_statement = first_statement,
			parm_start = parm_start,
			locals = locals,
			name = name,
			file = getString(s_file),
			numparms = numparms,
			parm_size = parm_size,
		})
		if functionsByName[name] == nil then
			functionsByName[name] = i
		end
	end

	local function readDefs(ofs: number, count: number, saveglobalAllowed: boolean): ({ Def }, { [string]: Def })
		local list: { Def } = table.create(count)
		local byName: { [string]: Def } = {}
		r:seek(ofs)
		for _ = 1, count do
			local typ = r:u16()
			if not saveglobalAllowed and bit32.band(typ, defs.DEF_SAVEGLOBAL) ~= 0 then
				error("PR_LoadProgs: fielddef type & DEF_SAVEGLOBAL")
			end
			local dofs = r:u16()
			local name = getString(r:i32())
			local def: Def = { type = typ, ofs = dofs, name = name }
			table.insert(list, def)
			if byName[name] == nil then
				byName[name] = def
			end
		end
		return list, byName
	end

	local globaldefs, globaldefsByName = readDefs(ofs_globaldefs, numglobaldefs, true)
	local fielddefs, fielddefsByName = readDefs(ofs_fielddefs, numfielddefs, false)

	-- globals (runtime-mutable copy)
	local globals = bufio.slice(buf, ofs_globals, numglobals * 4)

	return {
		crc = crc,
		headerCrc = headerCrc,
		numstatements = numstatements,
		st_op = st_op,
		st_a = st_a,
		st_b = st_b,
		st_c = st_c,
		functions = functions,
		functionsByName = functionsByName,
		globaldefs = globaldefs,
		globaldefsByName = globaldefsByName,
		fielddefs = fielddefs,
		fielddefsByName = fielddefsByName,
		strings = strings,
		stringsSize = numstrings,
		globals = globals,
		numglobals = numglobals,
		entityfields = entityfields,
	}
end

return progs
