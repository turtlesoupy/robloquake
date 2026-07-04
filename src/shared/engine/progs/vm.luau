--!strict
--!optimize 2
-- The QuakeC virtual machine — port of pr_exec.c and pr_edict.c from
-- WinQuake. Executes progs.dat bytecode over a globals buffer and per-edict
-- field buffers, reproducing the C engine's type-punning semantics exactly
-- (every cell is 4 bytes readable as float or int).
--
-- Representation:
--   * globals: one buffer, cell n at byte n*4.
--   * edicts: Luau array, edicts[n+1] is edict number n (0 = world); each
--     holds its own fields buffer of progs.entityfields cells.
--   * entity values in cells are edict NUMBERS (C stores byte offsets into
--     a contiguous edict arena; the number is the portable equivalent).
--   * strings: non-negative values are offsets into the static blob;
--     negative values index vm.dynstrings (ED_NewString allocations,
--     engine-created strings, and the ftos/vtos temp buffer).
--   * OP_ADDRESS pointers: edictnum * PTR_STRIDE + fieldofs.

local bufio = require("../common/bufio")
local com = require("../common/com")
local defs = require("./defs")
local progslib = require("./progs")

local vmlib = {}

local OFS_RETURN = defs.OFS_RETURN
local OFS_PARM0 = defs.OFS_PARM0

local MAX_STACK_DEPTH = 32
local LOCALSTACK_SIZE = 2048
local PTR_STRIDE = 4096

-- movetype/solid/etc. constants live with the server; the VM needs none.

export type Edict = {
	num: number,
	free: boolean,
	freetime: number,
	fields: buffer,
	-- world.c linkage, managed by world.luau
	area: any?,
	num_leafs: number,
	leafnums: { number },
	baseline: any?,
}

export type Builtin = (vm: VM) -> ()

export type VM = {
	progs: progslib.Progs,
	globals: buffer,
	edicts: { Edict },
	num_edicts: number,
	max_edicts: number,
	maxclients: number,
	time: number, -- mirror of sv.time for ED_Alloc/ED_Free policies
	serverActive: boolean, -- ss_active: guards world-entity assignment
	dynstrings: { string },
	builtins: { [number]: Builtin },
	builtinNames: { [number]: string },
	argc: number,
	trace: boolean,
	-- execution state
	depth: number,
	stack_s: { number },
	stack_f: { number },
	localstack: buffer,
	localstack_used: number,
	xfunction: number, -- C function index currently executing
	xstatement: number,
	-- hooks the server installs
	unlinkEdict: (ed: Edict) -> (),
	print: (s: string) -> (),
	-- string decode cache for the static blob
	_strcache: { [number]: string },
}

--------------------------------------------------------------------------
-- construction

function vmlib.new(pr: progslib.Progs, maxEdicts: number, maxclients: number): VM
	assert(pr.entityfields <= PTR_STRIDE, "entityfields exceeds pointer stride")
	assert(pr.numglobals < 32768, "too many globals for short operands")
	local vm: VM = {
		progs = pr,
		globals = pr.globals,
		edicts = {},
		num_edicts = 0,
		max_edicts = maxEdicts,
		maxclients = maxclients,
		time = 0,
		serverActive = false,
		dynstrings = {},
		builtins = {},
		builtinNames = {},
		argc = 0,
		trace = false,
		depth = 0,
		stack_s = table.create(MAX_STACK_DEPTH, 0),
		stack_f = table.create(MAX_STACK_DEPTH, 0),
		localstack = buffer.create(LOCALSTACK_SIZE * 4),
		localstack_used = 0,
		xfunction = 0,
		xstatement = 0,
		unlinkEdict = function(_ed) end,
		print = print,
		_strcache = {},
	}
	vm.stateOffsets = {
		globSelf = defs.glob.self,
		globTime = defs.glob.time,
		nextthink = defs.ent.nextthink,
		frame = defs.ent.frame,
		think = defs.ent.think,
	}
	return vm
end

--------------------------------------------------------------------------
-- strings

-- pr_strings + ofs
function vmlib.getString(vm: VM, ofs: number): string
	if ofs < 0 then
		return vm.dynstrings[-ofs] or ""
	end
	local cached = vm._strcache[ofs]
	if cached then
		return cached
	end
	local s = bufio.cstring(vm.progs.strings, ofs)
	vm._strcache[ofs] = s
	return s
end

-- Allocate a dynamic string; returns its (negative) string_t value.
function vmlib.allocString(vm: VM, s: string): number
	table.insert(vm.dynstrings, s)
	return -#vm.dynstrings
end

-- Overwrite an existing dynamic string slot (the ftos/vtos temp buffer).
function vmlib.setDynString(vm: VM, id: number, s: string)
	vm.dynstrings[-id] = s
end

-- ED_NewString: copies with \n escape processing.
function vmlib.newString(vm: VM, s: string): number
	local out = s:gsub("\\(.)", function(c)
		return if c == "n" then "\n" else "\\"
	end)
	return vmlib.allocString(vm, out)
end

--------------------------------------------------------------------------
-- globals / edict field access

function vmlib.globalFloat(vm: VM, ofs: number): number
	return buffer.readf32(vm.globals, ofs * 4)
end

function vmlib.setGlobalFloat(vm: VM, ofs: number, v: number)
	buffer.writef32(vm.globals, ofs * 4, v)
end

function vmlib.globalInt(vm: VM, ofs: number): number
	return buffer.readi32(vm.globals, ofs * 4)
end

function vmlib.setGlobalInt(vm: VM, ofs: number, v: number)
	buffer.writei32(vm.globals, ofs * 4, v)
end

function vmlib.globalVector(vm: VM, ofs: number): vector
	local g = vm.globals
	return vector.create(buffer.readf32(g, ofs * 4), buffer.readf32(g, ofs * 4 + 4), buffer.readf32(g, ofs * 4 + 8))
end

function vmlib.setGlobalVector(vm: VM, ofs: number, v: vector)
	local g = vm.globals
	buffer.writef32(g, ofs * 4, v.x)
	buffer.writef32(g, ofs * 4 + 4, v.y)
	buffer.writef32(g, ofs * 4 + 8, v.z)
end

function vmlib.globalString(vm: VM, ofs: number): string
	return vmlib.getString(vm, buffer.readi32(vm.globals, ofs * 4))
end

function vmlib.edFloat(ed: Edict, ofs: number): number
	return buffer.readf32(ed.fields, ofs * 4)
end

function vmlib.edSetFloat(ed: Edict, ofs: number, v: number)
	buffer.writef32(ed.fields, ofs * 4, v)
end

function vmlib.edInt(ed: Edict, ofs: number): number
	return buffer.readi32(ed.fields, ofs * 4)
end

function vmlib.edSetInt(ed: Edict, ofs: number, v: number)
	buffer.writei32(ed.fields, ofs * 4, v)
end

function vmlib.edVector(ed: Edict, ofs: number): vector
	local f = ed.fields
	return vector.create(buffer.readf32(f, ofs * 4), buffer.readf32(f, ofs * 4 + 4), buffer.readf32(f, ofs * 4 + 8))
end

function vmlib.edSetVector(ed: Edict, ofs: number, v: vector)
	local f = ed.fields
	buffer.writef32(f, ofs * 4, v.x)
	buffer.writef32(f, ofs * 4 + 4, v.y)
	buffer.writef32(f, ofs * 4 + 8, v.z)
end

function vmlib.edString(vm: VM, ed: Edict, ofs: number): string
	return vmlib.getString(vm, buffer.readi32(ed.fields, ofs * 4))
end

--------------------------------------------------------------------------
-- edicts

function vmlib.edictNum(vm: VM, n: number): Edict
	local ed = vm.edicts[n + 1]
	if not ed then
		error(`EDICT_NUM: bad number {n}`)
	end
	return ed
end

-- G_EDICT: edict referenced by an entity global
function vmlib.globalEdict(vm: VM, ofs: number): Edict
	return vmlib.edictNum(vm, buffer.readi32(vm.globals, ofs * 4))
end

local function makeEdict(vm: VM, num: number): Edict
	return {
		num = num,
		free = false,
		freetime = 0,
		fields = buffer.create(vm.progs.entityfields * 4),
		num_leafs = 0,
		leafnums = {},
	}
end

-- Create the initial edict pool: world + client slots (SV_SpawnServer
-- allocates all of them up front).
function vmlib.initEdicts(vm: VM, initial: number)
	table.clear(vm.edicts)
	for n = 0, vm.max_edicts - 1 do
		vm.edicts[n + 1] = makeEdict(vm, n)
	end
	vm.num_edicts = initial
end

local function clearEdict(vm: VM, e: Edict)
	buffer.fill(e.fields, 0, 0, vm.progs.entityfields * 4)
	e.free = false
end

-- ED_Alloc
function vmlib.alloc(vm: VM): Edict
	local i = vm.maxclients + 1
	while i < vm.num_edicts do
		local e = vm.edicts[i + 1]
		-- the first couple seconds of server time can involve a lot of
		-- freeing and allocating, so relax the replacement policy
		if e.free and (e.freetime < 2 or vm.time - e.freetime > 0.5) then
			clearEdict(vm, e)
			return e
		end
		i += 1
	end

	if i == vm.max_edicts then
		error("ED_Alloc: no free edicts")
	end

	vm.num_edicts += 1
	local e = vm.edicts[i + 1]
	clearEdict(vm, e)
	return e
end

-- ED_Free
function vmlib.free(vm: VM, ed: Edict)
	vm.unlinkEdict(ed)

	ed.free = true
	local ent = defs.ent
	vmlib.edSetInt(ed, ent.model, 0)
	vmlib.edSetFloat(ed, ent.takedamage, 0)
	vmlib.edSetFloat(ed, ent.modelindex, 0)
	vmlib.edSetFloat(ed, ent.colormap, 0)
	vmlib.edSetFloat(ed, ent.skin, 0)
	vmlib.edSetFloat(ed, ent.frame, 0)
	vmlib.edSetVector(ed, ent.origin, vector.zero)
	vmlib.edSetVector(ed, ent.angles, vector.zero)
	vmlib.edSetFloat(ed, ent.nextthink, -1)
	vmlib.edSetFloat(ed, ent.solid, 0)

	ed.freetime = vm.time
end

--------------------------------------------------------------------------
-- errors

local function runError(vm: VM, msg: string): never
	local fname = if vm.xfunction > 0 then vm.progs.functions[vm.xfunction + 1].name else "?"
	error(`PR_RunError: {msg} (function {fname}, statement {vm.xstatement})`)
end

--------------------------------------------------------------------------
-- function calls

-- PR_EnterFunction: returns the new statement counter
local function enterFunction(vm: VM, fnum: number): number
	local f = vm.progs.functions[fnum + 1]
	local depth = vm.depth
	vm.stack_s[depth + 1] = vm.xstatement
	vm.stack_f[depth + 1] = vm.xfunction
	vm.depth = depth + 1
	if vm.depth >= MAX_STACK_DEPTH then
		runError(vm, "stack overflow")
	end

	-- save off any locals that the new function steps on
	local c = f.locals
	if vm.localstack_used + c > LOCALSTACK_SIZE then
		runError(vm, "PR_ExecuteProgram: locals stack overflow")
	end
	buffer.copy(vm.localstack, vm.localstack_used * 4, vm.globals, f.parm_start * 4, c * 4)
	vm.localstack_used += c

	-- copy parameters
	local g = vm.globals
	local o = f.parm_start
	for i = 0, f.numparms - 1 do
		local sz = f.parm_size[i + 1]
		buffer.copy(g, o * 4, g, (OFS_PARM0 + i * 3) * 4, sz * 4)
		o += sz
	end

	vm.xfunction = fnum
	return f.first_statement - 1 -- offset the s++
end

-- PR_LeaveFunction
local function leaveFunction(vm: VM): number
	if vm.depth <= 0 then
		error("prog stack underflow")
	end

	-- restore locals from the stack
	local f = vm.progs.functions[vm.xfunction + 1]
	local c = f.locals
	vm.localstack_used -= c
	if vm.localstack_used < 0 then
		runError(vm, "PR_ExecuteProgram: locals stack underflow")
	end
	buffer.copy(vm.globals, f.parm_start * 4, vm.localstack, vm.localstack_used * 4, c * 4)

	vm.depth -= 1
	vm.xfunction = vm.stack_f[vm.depth + 1]
	return vm.stack_s[vm.depth + 1]
end

--------------------------------------------------------------------------
-- PR_ExecuteProgram

function vmlib.exec(vm: VM, fnum: number)
	local pr = vm.progs
	if fnum <= 0 or fnum >= #pr.functions then
		error(`PR_ExecuteProgram: NULL function ({fnum})`)
	end

	local g = vm.globals
	local st_op, st_a, st_b, st_c = pr.st_op, pr.st_a, pr.st_b, pr.st_c
	local edicts = vm.edicts
	local strings = pr.strings

	local runaway = 100000
	vm.trace = false

	local exitdepth = vm.depth
	local s = enterFunction(vm, fnum)

	while true do
		s += 1 -- next statement
		local si = s + 1 -- 1-based index into the statement arrays
		local op = st_op[si]
		local a = st_a[si]
		local b = st_b[si]
		local c = st_c[si]

		runaway -= 1
		if runaway == 0 then
			runError(vm, "runaway loop error")
		end
		vm.xstatement = s

		if op == 0 or op == 43 then -- OP_DONE / OP_RETURN
			buffer.copy(g, OFS_RETURN * 4, g, a * 4, 12)
			s = leaveFunction(vm)
			if vm.depth == exitdepth then
				return -- all done
			end
		elseif op == 1 then -- OP_MUL_F
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) * buffer.readf32(g, b * 4))
		elseif op == 2 then -- OP_MUL_V (dot product)
			buffer.writef32(
				g,
				c * 4,
				buffer.readf32(g, a * 4) * buffer.readf32(g, b * 4)
					+ buffer.readf32(g, a * 4 + 4) * buffer.readf32(g, b * 4 + 4)
					+ buffer.readf32(g, a * 4 + 8) * buffer.readf32(g, b * 4 + 8)
			)
		elseif op == 3 then -- OP_MUL_FV
			local f = buffer.readf32(g, a * 4)
			buffer.writef32(g, c * 4, f * buffer.readf32(g, b * 4))
			buffer.writef32(g, c * 4 + 4, f * buffer.readf32(g, b * 4 + 4))
			buffer.writef32(g, c * 4 + 8, f * buffer.readf32(g, b * 4 + 8))
		elseif op == 4 then -- OP_MUL_VF
			local f = buffer.readf32(g, b * 4)
			buffer.writef32(g, c * 4, f * buffer.readf32(g, a * 4))
			buffer.writef32(g, c * 4 + 4, f * buffer.readf32(g, a * 4 + 4))
			buffer.writef32(g, c * 4 + 8, f * buffer.readf32(g, a * 4 + 8))
		elseif op == 5 then -- OP_DIV_F
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) / buffer.readf32(g, b * 4))
		elseif op == 6 then -- OP_ADD_F
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) + buffer.readf32(g, b * 4))
		elseif op == 7 then -- OP_ADD_V
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) + buffer.readf32(g, b * 4))
			buffer.writef32(g, c * 4 + 4, buffer.readf32(g, a * 4 + 4) + buffer.readf32(g, b * 4 + 4))
			buffer.writef32(g, c * 4 + 8, buffer.readf32(g, a * 4 + 8) + buffer.readf32(g, b * 4 + 8))
		elseif op == 8 then -- OP_SUB_F
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) - buffer.readf32(g, b * 4))
		elseif op == 9 then -- OP_SUB_V
			buffer.writef32(g, c * 4, buffer.readf32(g, a * 4) - buffer.readf32(g, b * 4))
			buffer.writef32(g, c * 4 + 4, buffer.readf32(g, a * 4 + 4) - buffer.readf32(g, b * 4 + 4))
			buffer.writef32(g, c * 4 + 8, buffer.readf32(g, a * 4 + 8) - buffer.readf32(g, b * 4 + 8))
		elseif op == 10 then -- OP_EQ_F
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) == buffer.readf32(g, b * 4) then 1 else 0)
		elseif op == 11 then -- OP_EQ_V
			local eq = buffer.readf32(g, a * 4) == buffer.readf32(g, b * 4)
				and buffer.readf32(g, a * 4 + 4) == buffer.readf32(g, b * 4 + 4)
				and buffer.readf32(g, a * 4 + 8) == buffer.readf32(g, b * 4 + 8)
			buffer.writef32(g, c * 4, if eq then 1 else 0)
		elseif op == 12 then -- OP_EQ_S
			local sa = vmlib.getString(vm, buffer.readi32(g, a * 4))
			local sb = vmlib.getString(vm, buffer.readi32(g, b * 4))
			buffer.writef32(g, c * 4, if sa == sb then 1 else 0)
		elseif op == 13 or op == 14 then -- OP_EQ_E / OP_EQ_FNC
			buffer.writef32(g, c * 4, if buffer.readi32(g, a * 4) == buffer.readi32(g, b * 4) then 1 else 0)
		elseif op == 15 then -- OP_NE_F
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) ~= buffer.readf32(g, b * 4) then 1 else 0)
		elseif op == 16 then -- OP_NE_V
			local ne = buffer.readf32(g, a * 4) ~= buffer.readf32(g, b * 4)
				or buffer.readf32(g, a * 4 + 4) ~= buffer.readf32(g, b * 4 + 4)
				or buffer.readf32(g, a * 4 + 8) ~= buffer.readf32(g, b * 4 + 8)
			buffer.writef32(g, c * 4, if ne then 1 else 0)
		elseif op == 17 then -- OP_NE_S
			local sa = vmlib.getString(vm, buffer.readi32(g, a * 4))
			local sb = vmlib.getString(vm, buffer.readi32(g, b * 4))
			buffer.writef32(g, c * 4, if sa ~= sb then 1 else 0)
		elseif op == 18 or op == 19 then -- OP_NE_E / OP_NE_FNC
			buffer.writef32(g, c * 4, if buffer.readi32(g, a * 4) ~= buffer.readi32(g, b * 4) then 1 else 0)
		elseif op == 20 then -- OP_LE
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) <= buffer.readf32(g, b * 4) then 1 else 0)
		elseif op == 21 then -- OP_GE
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) >= buffer.readf32(g, b * 4) then 1 else 0)
		elseif op == 22 then -- OP_LT
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) < buffer.readf32(g, b * 4) then 1 else 0)
		elseif op == 23 then -- OP_GT
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) > buffer.readf32(g, b * 4) then 1 else 0)
		elseif op >= 24 and op <= 29 then -- OP_LOAD_F/V/S/ENT/FLD/FNC
			local ed = edicts[buffer.readi32(g, a * 4) + 1]
			local fofs = buffer.readi32(g, b * 4)
			if op == 25 then -- OP_LOAD_V
				buffer.copy(g, c * 4, ed.fields, fofs * 4, 12)
			else
				buffer.copy(g, c * 4, ed.fields, fofs * 4, 4)
			end
		elseif op == 30 then -- OP_ADDRESS
			local enum_ = buffer.readi32(g, a * 4)
			if enum_ == 0 and vm.serverActive then
				runError(vm, "assignment to world entity")
			end
			buffer.writei32(g, c * 4, enum_ * PTR_STRIDE + buffer.readi32(g, b * 4))
		elseif op >= 31 and op <= 36 then -- OP_STORE_F/V/S/ENT/FLD/FNC
			if op == 32 then -- OP_STORE_V
				buffer.copy(g, b * 4, g, a * 4, 12)
			else
				buffer.copy(g, b * 4, g, a * 4, 4)
			end
		elseif op >= 37 and op <= 42 then -- OP_STOREP_F/V/S/ENT/FLD/FNC
			local ptr = buffer.readi32(g, b * 4)
			local ed = edicts[math.floor(ptr / PTR_STRIDE) + 1]
			local fofs = ptr % PTR_STRIDE
			if op == 38 then -- OP_STOREP_V
				buffer.copy(ed.fields, fofs * 4, g, a * 4, 12)
			else
				buffer.copy(ed.fields, fofs * 4, g, a * 4, 4)
			end
		elseif op == 44 then -- OP_NOT_F
			buffer.writef32(g, c * 4, if buffer.readf32(g, a * 4) == 0 then 1 else 0)
		elseif op == 45 then -- OP_NOT_V
			local z = buffer.readf32(g, a * 4) == 0
				and buffer.readf32(g, a * 4 + 4) == 0
				and buffer.readf32(g, a * 4 + 8) == 0
			buffer.writef32(g, c * 4, if z then 1 else 0)
		elseif op == 46 then -- OP_NOT_S
			local sofs = buffer.readi32(g, a * 4)
			local empty = sofs == 0 or #vmlib.getString(vm, sofs) == 0
			buffer.writef32(g, c * 4, if empty then 1 else 0)
		elseif op == 47 then -- OP_NOT_ENT
			buffer.writef32(g, c * 4, if buffer.readi32(g, a * 4) == 0 then 1 else 0)
		elseif op == 48 then -- OP_NOT_FNC
			buffer.writef32(g, c * 4, if buffer.readi32(g, a * 4) == 0 then 1 else 0)
		elseif op == 49 then -- OP_IF
			if buffer.readi32(g, a * 4) ~= 0 then
				s += b - 1 -- offset the s++
			end
		elseif op == 50 then -- OP_IFNOT
			if buffer.readi32(g, a * 4) == 0 then
				s += b - 1 -- offset the s++
			end
		elseif op >= 51 and op <= 59 then -- OP_CALL0..OP_CALL8
			vm.argc = op - 51
			local fn = buffer.readi32(g, a * 4)
			if fn == 0 then
				runError(vm, "NULL function")
			end
			local newf = pr.functions[fn + 1]
			if not newf then
				runError(vm, `bad function number {fn}`)
			end
			if newf.first_statement < 0 then
				-- negative statements are built in functions
				local bnum = -newf.first_statement
				local builtin = vm.builtins[bnum]
				if not builtin then
					runError(vm, `bad builtin call number {bnum} ({newf.name})`)
				end
				builtin(vm)
			else
				s = enterFunction(vm, fn)
			end
		elseif op == 60 then -- OP_STATE
			-- offsets are per-VM: the QW progs ABI differs from NQ's
			local so = vm.stateOffsets
			local self_ = edicts[buffer.readi32(g, so.globSelf * 4) + 1]
			vmlib.edSetFloat(self_, so.nextthink, buffer.readf32(g, so.globTime * 4) + 0.1)
			vmlib.edSetFloat(self_, so.frame, buffer.readf32(g, a * 4))
			vmlib.edSetInt(self_, so.think, buffer.readi32(g, b * 4))
		elseif op == 61 then -- OP_GOTO
			s += a - 1 -- offset the s++
		elseif op == 62 then -- OP_AND
			local r = buffer.readf32(g, a * 4) ~= 0 and buffer.readf32(g, b * 4) ~= 0
			buffer.writef32(g, c * 4, if r then 1 else 0)
		elseif op == 63 then -- OP_OR
			local r = buffer.readf32(g, a * 4) ~= 0 or buffer.readf32(g, b * 4) ~= 0
			buffer.writef32(g, c * 4, if r then 1 else 0)
		elseif op == 64 then -- OP_BITAND
			local ia = buffer.readf32(g, a * 4)
			local ib = buffer.readf32(g, b * 4)
			local r = bit32.band(if ia >= 0 then math.floor(ia) else -math.floor(-ia), if ib >= 0 then math.floor(ib) else -math.floor(-ib))
			if r >= 0x80000000 then
				r -= 0x100000000
			end
			buffer.writef32(g, c * 4, r)
		elseif op == 65 then -- OP_BITOR
			local ia = buffer.readf32(g, a * 4)
			local ib = buffer.readf32(g, b * 4)
			local r = bit32.bor(if ia >= 0 then math.floor(ia) else -math.floor(-ia), if ib >= 0 then math.floor(ib) else -math.floor(-ib))
			if r >= 0x80000000 then
				r -= 0x100000000
			end
			buffer.writef32(g, c * 4, r)
		else
			runError(vm, `bad opcode {op}`)
		end
	end
end

-- Convenience wrappers ----------------------------------------------------

function vmlib.findFunction(vm: VM, name: string): number?
	return vm.progs.functionsByName[name]
end

function vmlib.execByName(vm: VM, name: string)
	local fnum = vm.progs.functionsByName[name]
	if not fnum then
		error(`no function {name}`)
	end
	vmlib.exec(vm, fnum)
end

--------------------------------------------------------------------------
-- entity parsing (ED_ParseEpair / ED_ParseEdict / ED_LoadFromFile)

-- ED_ParseEpair writing into an arbitrary cell buffer
function vmlib.parseEpair(vm: VM, target: buffer, def: progslib.Def, s: string): boolean
	local d = def.ofs * 4
	local typ = bit32.band(def.type, 0x7fff)

	if typ == defs.ev_string then
		buffer.writei32(target, d, vmlib.newString(vm, s))
	elseif typ == defs.ev_float then
		buffer.writef32(target, d, com.atof(s))
	elseif typ == defs.ev_vector then
		local parts = { 0, 0, 0 }
		local i = 1
		for w in s:gmatch("[^ ]+") do
			if i > 3 then
				break
			end
			parts[i] = com.atof(w)
			i += 1
		end
		buffer.writef32(target, d, parts[1])
		buffer.writef32(target, d + 4, parts[2])
		buffer.writef32(target, d + 8, parts[3])
	elseif typ == defs.ev_entity then
		buffer.writei32(target, d, com.atoi(s))
	elseif typ == defs.ev_field then
		local fdef = vm.progs.fielddefsByName[s]
		if not fdef then
			vm.print(`Can't find field {s}`)
			return false
		end
		buffer.writei32(target, d, buffer.readi32(vm.globals, fdef.ofs * 4))
	elseif typ == defs.ev_function then
		local fnum = vm.progs.functionsByName[s]
		if not fnum then
			vm.print(`Can't find function {s}`)
			return false
		end
		buffer.writei32(target, d, fnum)
	end
	return true
end

-- ED_ParseEdict: parses one entity dictionary starting after its '{'.
-- Returns the new parse position.
function vmlib.parseEdict(vm: VM, data: string, pos: number, ent: Edict): number
	local init = false

	-- clear it
	if ent.num ~= 0 then -- hack: world edict keeps its parsed globals
		buffer.fill(ent.fields, 0, 0, vm.progs.entityfields * 4)
	end

	while true do
		-- parse key
		local token
		token, pos = com.parse(data, pos)
		if token == nil then
			error("ED_ParseEntity: EOF without closing brace")
		end
		if token:sub(1, 1) == "}" then
			break
		end

		-- anglehack is to allow QuakeEd to write single scalar angles
		local anglehack = false
		if token == "angle" then
			token = "angles"
			anglehack = true
		end
		if token == "light" then
			token = "light_lev" -- hack for single light def
		end
		local keyname = token:gsub(" +$", "") -- trailing-space keynames

		-- parse value
		token, pos = com.parse(data, pos)
		if token == nil then
			error("ED_ParseEntity: EOF without closing brace")
		end
		if token:sub(1, 1) == "}" then
			error("ED_ParseEntity: closing brace without data")
		end

		init = true

		-- keynames with a leading underscore are utility comments
		if keyname:sub(1, 1) == "_" then
			continue
		end

		local def = vm.progs.fielddefsByName[keyname]
		if not def then
			vm.print(`'{keyname}' is not a field`)
			continue
		end

		if anglehack then
			token = `0 {token} 0`
		end

		if not vmlib.parseEpair(vm, ent.fields, def, token) then
			error("ED_ParseEdict: parse error")
		end
	end

	if not init then
		ent.free = true
	end

	return pos
end

local SPAWNFLAG_NOT_EASY = 256
local SPAWNFLAG_NOT_MEDIUM = 512
local SPAWNFLAG_NOT_HARD = 1024
local SPAWNFLAG_NOT_DEATHMATCH = 2048

-- ED_LoadFromFile: spawn all entities from a map's entity string.
function vmlib.loadFromFile(vm: VM, data: string, deathmatch: number, skill: number)
	local ent: Edict? = nil
	local inhibit = 0
	local pos = 1
	buffer.writef32(vm.globals, defs.glob.time * 4, vm.time)

	while true do
		-- parse the opening brace
		local token
		token, pos = com.parse(data, pos)
		if token == nil then
			break
		end
		if token:sub(1, 1) ~= "{" then
			error(`ED_LoadFromFile: found {token} when expecting \{`)
		end

		if not ent then
			ent = vmlib.edictNum(vm, 0)
		else
			ent = vmlib.alloc(vm)
		end
		pos = vmlib.parseEdict(vm, data, pos, ent)

		-- remove things from different skill levels or deathmatch
		local spawnflags = vmlib.edFloat(ent, defs.ent.spawnflags)
		if deathmatch ~= 0 then
			if bit32.band(spawnflags, SPAWNFLAG_NOT_DEATHMATCH) ~= 0 then
				vmlib.free(vm, ent)
				inhibit += 1
				continue
			end
		elseif
			(skill == 0 and bit32.band(spawnflags, SPAWNFLAG_NOT_EASY) ~= 0)
			or (skill == 1 and bit32.band(spawnflags, SPAWNFLAG_NOT_MEDIUM) ~= 0)
			or (skill >= 2 and bit32.band(spawnflags, SPAWNFLAG_NOT_HARD) ~= 0)
		then
			vmlib.free(vm, ent)
			inhibit += 1
			continue
		end

		-- immediately call the spawn function
		local classofs = vmlib.edInt(ent, defs.ent.classname)
		if classofs == 0 then
			vm.print("No classname for edict")
			vmlib.free(vm, ent)
			continue
		end
		local classname = vmlib.getString(vm, classofs)

		local fnum = vm.progs.functionsByName[classname]
		if not fnum then
			vm.print(`No spawn function for: {classname}`)
			vmlib.free(vm, ent)
			continue
		end

		buffer.writei32(vm.globals, defs.glob.self * 4, ent.num)
		vmlib.exec(vm, fnum)
	end

	vm.print(`{inhibit} entities inhibited`)
end

-- QW ED_LoadFromFile: same parse loop with the QW ABI injected and
-- deathmatch-only inhibiting (QW has no skill levels)
function vmlib.loadFromFileQW(vm: VM, data: string, deathmatch: number, qglob: { [string]: number }, qent: { [string]: number })
	local ent: Edict? = nil
	local inhibit = 0
	local pos = 1
	buffer.writef32(vm.globals, qglob.time * 4, vm.time)

	while true do
		local token
		token, pos = com.parse(data, pos)
		if token == nil then
			break
		end
		if token:sub(1, 1) ~= "{" then
			error(`ED_LoadFromFile: found {token} when expecting \{`)
		end

		if not ent then
			ent = vmlib.edictNum(vm, 0)
		else
			ent = vmlib.alloc(vm)
		end
		pos = vmlib.parseEdict(vm, data, pos, ent)

		local spawnflags = vmlib.edFloat(ent, qent.spawnflags)
		if deathmatch ~= 0 and bit32.band(spawnflags, SPAWNFLAG_NOT_DEATHMATCH) ~= 0 then
			vmlib.free(vm, ent)
			inhibit += 1
			continue
		end

		local classofs = vmlib.edInt(ent, qent.classname)
		if classofs == 0 then
			vm.print("No classname for edict")
			vmlib.free(vm, ent)
			continue
		end
		local classname = vmlib.getString(vm, classofs)
		local fnum = vm.progs.functionsByName[classname]
		if not fnum then
			vm.print(`No spawn function for: {classname}`)
			vmlib.free(vm, ent)
			continue
		end

		buffer.writei32(vm.globals, qglob.self * 4, ent.num)
		vmlib.exec(vm, fnum)
	end

	vm.print(`{inhibit} entities inhibited`)
end

-- GetEdictFieldValue equivalent: field def lookup for engine code.
function vmlib.findFieldDef(vm: VM, name: string): progslib.Def?
	return vm.progs.fielddefsByName[name]
end

return vmlib
