--!strict
-- QuakeC introspection — port of the pr_edict.c debug printers
-- (PR_ValueString/PR_UglyValueString/PR_GlobalString(NoContents),
-- ED_Print/ED_PrintNum/ED_PrintEdicts/ED_Count) and the pr_exec.c
-- trace/profile tools (PR_PrintStatement, PR_StackTrace, PR_Profile_f).
-- One implementation serves both engines through the shared VM.
-- Functions return strings; callers print (Con_Printf is the caller's).

local defs = require("./defs")
local vmlib = require("./vm")

local prdebug = {}

local DEF_SAVEGLOBAL = 0x8000

-- pr_exec.c pr_opnames (INDIRECT = the 6 load ops)
local OPNAMES = {
	[0] = "DONE",
	"MUL_F", "MUL_V", "MUL_FV", "MUL_VF", "DIV",
	"ADD_F", "ADD_V", "SUB_F", "SUB_V",
	"EQ_F", "EQ_V", "EQ_S", "EQ_E", "EQ_FNC",
	"NE_F", "NE_V", "NE_S", "NE_E", "NE_FNC",
	"LE", "GE", "LT", "GT",
	"INDIRECT", "INDIRECT", "INDIRECT", "INDIRECT", "INDIRECT", "INDIRECT",
	"ADDRESS",
	"STORE_F", "STORE_V", "STORE_S", "STORE_ENT", "STORE_FLD", "STORE_FNC",
	"STOREP_F", "STOREP_V", "STOREP_S", "STOREP_ENT", "STOREP_FLD", "STOREP_FNC",
	"RETURN",
	"NOT_F", "NOT_V", "NOT_S", "NOT_ENT", "NOT_FNC",
	"IF", "IFNOT",
	"CALL0", "CALL1", "CALL2", "CALL3", "CALL4", "CALL5", "CALL6", "CALL7", "CALL8",
	"STATE", "GOTO", "AND", "OR", "BITAND", "BITOR",
}
prdebug.OPNAMES = OPNAMES

-- ED_FieldAtOfs / ED_GlobalAtOfs
function prdebug.fieldAtOfs(vm: vmlib.VM, ofs: number)
	for _, d in vm.progs.fielddefs do
		if d.ofs == ofs then
			return d
		end
	end
	return nil
end

function prdebug.globalAtOfs(vm: vmlib.VM, ofs: number)
	for _, d in vm.progs.globaldefs do
		if d.ofs == ofs then
			return d
		end
	end
	return nil
end

-- PR_ValueString: value at cell `ofs` of `buf`, formatted by etype
function prdebug.valueString(vm: vmlib.VM, dtype: number, buf: buffer, ofs: number): string
	local t = bit32.band(dtype, bit32.bnot(DEF_SAVEGLOBAL))
	if t == defs.ev_string then
		return vmlib.getString(vm, buffer.readi32(buf, ofs * 4))
	elseif t == defs.ev_entity then
		return ("entity %i"):format(buffer.readi32(buf, ofs * 4))
	elseif t == defs.ev_function then
		local f = vm.progs.functions[buffer.readi32(buf, ofs * 4) + 1]
		return (if f then f.name else "?") .. "()"
	elseif t == defs.ev_field then
		local d = prdebug.fieldAtOfs(vm, buffer.readi32(buf, ofs * 4))
		return "." .. (if d then d.name else "?")
	elseif t == defs.ev_void then
		return "void"
	elseif t == defs.ev_float then
		return ("%5.1f"):format(buffer.readf32(buf, ofs * 4))
	elseif t == defs.ev_vector then
		return ("'%5.1f %5.1f %5.1f'"):format(buffer.readf32(buf, ofs * 4), buffer.readf32(buf, ofs * 4 + 4), buffer.readf32(buf, ofs * 4 + 8))
	elseif t == defs.ev_pointer then
		return "pointer"
	end
	return ("bad type %i"):format(t)
end

-- PR_UglyValueString: savegame/coredump variant (no padding, %f floats)
function prdebug.uglyValueString(vm: vmlib.VM, dtype: number, buf: buffer, ofs: number): string
	local t = bit32.band(dtype, bit32.bnot(DEF_SAVEGLOBAL))
	if t == defs.ev_string then
		return vmlib.getString(vm, buffer.readi32(buf, ofs * 4))
	elseif t == defs.ev_entity then
		return ("%i"):format(buffer.readi32(buf, ofs * 4))
	elseif t == defs.ev_function then
		local f = vm.progs.functions[buffer.readi32(buf, ofs * 4) + 1]
		return if f then f.name else "?"
	elseif t == defs.ev_field then
		local d = prdebug.fieldAtOfs(vm, buffer.readi32(buf, ofs * 4))
		return if d then d.name else "?"
	elseif t == defs.ev_void then
		return "void"
	elseif t == defs.ev_float then
		return ("%f"):format(buffer.readf32(buf, ofs * 4))
	elseif t == defs.ev_vector then
		return ("%f %f %f"):format(buffer.readf32(buf, ofs * 4), buffer.readf32(buf, ofs * 4 + 4), buffer.readf32(buf, ofs * 4 + 8))
	end
	return ("bad type %i"):format(t)
end

local function padTo21(line: string): string
	if #line < 20 then
		line ..= (" "):rep(20 - #line)
	end
	return line .. " "
end

-- PR_GlobalString: "%i(%s)%s" padded to 20 chars + a space
function prdebug.globalString(vm: vmlib.VM, ofs: number): string
	local d = prdebug.globalAtOfs(vm, ofs)
	local line
	if not d then
		line = ("%i(???)"):format(ofs)
	else
		line = ("%i(%s)%s"):format(ofs, d.name, prdebug.valueString(vm, d.type, vm.globals, ofs))
	end
	return padTo21(line)
end

function prdebug.globalStringNoContents(vm: vmlib.VM, ofs: number): string
	local d = prdebug.globalAtOfs(vm, ofs)
	local line = if d then ("%i(%s)"):format(ofs, d.name) else ("%i(???)"):format(ofs)
	return padTo21(line)
end

-- ED_Print: every non-zero field, name padded to 15 (skips _x/_y/_z)
function prdebug.edPrint(vm: vmlib.VM, ed: vmlib.Edict): string
	if ed.free then
		return "FREE\n"
	end
	local out = { ("\nEDICT %i:\n"):format(ed.num) }
	local fd = vm.progs.fielddefs
	for i = 2, #fd do -- C starts at fielddef 1
		local d = fd[i]
		local name = d.name
		if name:sub(-2, -2) == "_" then
			continue -- skip _x, _y, _z vars
		end
		local t = bit32.band(d.type, bit32.bnot(DEF_SAVEGLOBAL))
		local size = defs.type_size[t] or 1
		local nonzero = false
		for j = 0, size - 1 do
			if buffer.readi32(ed.fields, (d.ofs + j) * 4) ~= 0 then
				nonzero = true
				break
			end
		end
		if not nonzero then
			continue
		end
		-- C pads the name to exactly 15 columns, value follows directly
		local pad = if #name < 15 then (" "):rep(15 - #name) else ""
		table.insert(out, name .. pad .. prdebug.valueString(vm, d.type, ed.fields, d.ofs) .. "\n")
	end
	return table.concat(out)
end

-- ED_PrintNum
function prdebug.edPrintNum(vm: vmlib.VM, n: number): string
	local ed = vm.edicts[n + 1]
	if not ed then
		return ("bad edict %i\n"):format(n)
	end
	return prdebug.edPrint(vm, ed)
end

-- ED_PrintEdicts: "%i entities" then every edict
function prdebug.edPrintEdicts(vm: vmlib.VM): string
	local out = { ("%i entities\n"):format(vm.num_edicts) }
	for i = 0, vm.num_edicts - 1 do
		table.insert(out, prdebug.edPrintNum(vm, i))
	end
	return table.concat(out)
end

-- ED_Count: active/view/touch/step tallies (field offsets resolved by
-- name so the same code serves NQ and QW progs layouts)
function prdebug.edCount(vm: vmlib.VM): string
	local byName = vm.progs.fielddefsByName
	local fModel, fSolid, fMove = byName.model, byName.solid, byName.movetype
	local active, models, solid, step = 0, 0, 0, 0
	for i = 0, vm.num_edicts - 1 do
		local ed = vm.edicts[i + 1]
		if not ed or ed.free then
			continue
		end
		active += 1
		if fSolid and buffer.readf32(ed.fields, fSolid.ofs * 4) ~= 0 then
			solid += 1
		end
		if fModel and buffer.readi32(ed.fields, fModel.ofs * 4) ~= 0 then
			models += 1
		end
		if fMove and buffer.readf32(ed.fields, fMove.ofs * 4) == 4 then -- MOVETYPE_STEP
			step += 1
		end
	end
	return ("num_edicts:%3i\nactive    :%3i\nview      :%3i\ntouch     :%3i\nstep      :%3i\n"):format(vm.num_edicts, active, models, solid, step)
end

-- PR_PrintStatement: opcode name padded to 10, operands as global strings
function prdebug.statementString(vm: vmlib.VM, s: number): string
	local pr = vm.progs
	local si = s + 1
	local op, a, b, c = pr.st_op[si], pr.st_a[si], pr.st_b[si], pr.st_c[si]
	local out = ""
	local name = OPNAMES[op]
	if name then
		out = name .. " "
		if #name < 10 then
			out ..= (" "):rep(10 - #name)
		end
	end
	if op == 49 or op == 50 then -- OP_IF / OP_IFNOT
		out ..= prdebug.globalString(vm, a) .. ("branch %i"):format(b)
	elseif op == 61 then -- OP_GOTO
		out ..= ("branch %i"):format(a)
	elseif op >= 31 and op <= 36 then -- OP_STORE_F..OP_STORE_FNC
		out ..= prdebug.globalString(vm, a)
		out ..= prdebug.globalStringNoContents(vm, b)
	else
		if a ~= 0 then
			out ..= prdebug.globalString(vm, a)
		end
		if b ~= 0 then
			out ..= prdebug.globalString(vm, b)
		end
		if c ~= 0 then
			out ..= prdebug.globalStringNoContents(vm, c)
		end
	end
	return out
end

-- PR_StackTrace: "%12s : %s" per frame, current function on top
function prdebug.stackTrace(vm: vmlib.VM): string
	if vm.depth == 0 then
		return "<NO STACK>\n"
	end
	local out = {}
	-- pr_stack[pr_depth].f = pr_xfunction, then walk down
	local frames = table.clone(vm.stack_f)
	frames[vm.depth + 1] = vm.xfunction
	for i = vm.depth + 1, 1, -1 do
		local f = vm.progs.functions[frames[i] + 1]
		if not f then
			table.insert(out, "<NO FUNCTION>\n")
		else
			table.insert(out, ("%12s : %s\n"):format(f.file, f.name))
		end
	end
	return table.concat(out)
end

-- PR_Profile_f: repeatedly print the max-profile function (top 10 shown),
-- zeroing every counter — exactly the C selection loop
function prdebug.profileReport(vm: vmlib.VM): string
	local out = {}
	local num = 0
	while true do
		local max = 0
		local best: any = nil
		for _, f in vm.progs.functions do
			local p = (f :: any).profile or 0
			if p > max then
				max = p
				best = f
			end
		end
		if not best then
			break
		end
		if num < 10 then
			table.insert(out, ("%7i %s\n"):format((best :: any).profile, (best :: any).name))
		end
		num += 1
		;(best :: any).profile = 0
	end
	return table.concat(out)
end

-- install the tracer hook (PR_PrintStatement while pr_trace); the VM
-- calls it per statement when vm.trace is set (PF_traceon)
function prdebug.installTracer(vm: vmlib.VM)
	(vm :: any).statementPrinter = function(v: vmlib.VM, s: number)
		v.print(prdebug.statementString(v, s))
	end
end

return prdebug
