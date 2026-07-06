--!strict
-- QuakeC introspection (prdebug.luau = pr_edict.c/pr_exec.c debug tools)
-- against a real booted e1m1 server: PR_ValueString/PR_UglyValueString/
-- PR_GlobalString(NoContents), ED_Print/ED_PrintNum/ED_PrintEdicts/
-- ED_Count, PR_PrintStatement, PR_StackTrace, PR_Profile_f, and the
-- PF_coredump/traceon/traceoff/eprint builtins that drive them.
local t = require("./testutil")
local defs = require("../src/shared/engine/progs/defs")
local prdebug = require("../src/shared/engine/progs/prdebug")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
local printed: { string } = {}
svr.print = function(s: string)
	table.insert(printed, s)
end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

--------------------------------------------------------------------------
-- PR_ValueString formats (a scratch buffer stands in for eval_t*)
local scratch = buffer.create(16)
buffer.writef32(scratch, 0, 90)
t.eq(prdebug.valueString(vm, defs.ev_float, scratch, 0), " 90.0", "valueString: float %5.1f")
buffer.writef32(scratch, 0, 1)
buffer.writef32(scratch, 4, -2.5)
buffer.writef32(scratch, 8, 300)
t.eq(prdebug.valueString(vm, defs.ev_vector, scratch, 0), "'  1.0  -2.5 300.0'", "valueString: vector quoted %5.1f triple")
buffer.writei32(scratch, 0, 23)
t.eq(prdebug.valueString(vm, defs.ev_entity, scratch, 0), "entity 23", "valueString: entity %i")
t.eq(prdebug.valueString(vm, defs.ev_void, scratch, 0), "void", "valueString: void")
t.eq(prdebug.valueString(vm, defs.ev_pointer, scratch, 0), "pointer", "valueString: pointer")
t.eq(prdebug.valueString(vm, 12, scratch, 0), "bad type 12", "valueString: bad type")

-- string type through a dynstring id
local sid = vmlib.newString(vm, "shambler")
buffer.writei32(scratch, 0, sid)
t.eq(prdebug.valueString(vm, defs.ev_string, scratch, 0), "shambler", "valueString: string via blob/dynstrings")

-- function type: worldspawn's own index round-trips to "worldspawn()"
local wsNum = vmlib.findFunction(vm, "worldspawn") :: number
t.check(wsNum ~= nil, "fixture: worldspawn exists")
buffer.writei32(scratch, 0, wsNum)
t.eq(prdebug.valueString(vm, defs.ev_function, scratch, 0), "worldspawn()", "valueString: function name()")
t.eq(prdebug.uglyValueString(vm, defs.ev_function, scratch, 0), "worldspawn", "uglyValueString: bare function name")

-- field type: the origin fielddef resolves back by offset
local originDef = vm.progs.fielddefsByName.origin
buffer.writei32(scratch, 0, originDef.ofs)
t.eq(prdebug.valueString(vm, defs.ev_field, scratch, 0), ".origin", "valueString: .fieldname by ofs")

-- ugly variants (savegame formats, no padding)
buffer.writef32(scratch, 0, 90)
t.eq(prdebug.uglyValueString(vm, defs.ev_float, scratch, 0), "90.000000", "uglyValueString: float %f")
buffer.writei32(scratch, 0, 7)
t.eq(prdebug.uglyValueString(vm, defs.ev_entity, scratch, 0), "7", "uglyValueString: bare entity number")

-- DEF_SAVEGLOBAL bit is masked off like C
t.eq(prdebug.valueString(vm, defs.ev_float + 0x8000, scratch, 0), prdebug.valueString(vm, defs.ev_float, scratch, 0), "valueString: DEF_SAVEGLOBAL masked")

--------------------------------------------------------------------------
-- PR_GlobalString / PR_GlobalStringNoContents: 20-char pad + 1 space
local timeDef = vm.progs.globaldefsByName.time
local gs = prdebug.globalString(vm, timeDef.ofs)
t.check(gs:find("(time)", 1, true) ~= nil, "globalString: %i(name)value")
t.check(#gs >= 21 and gs:sub(-1) == " ", "globalString: padded to 20 + trailing space")
local gnc = prdebug.globalStringNoContents(vm, timeDef.ofs)
t.check(gnc:find("(time)", 1, true) ~= nil and gnc:find("%d") == 1, "globalStringNoContents: %i(name)")
t.check(prdebug.globalString(vm, 32767):find("(???)", 1, true) ~= nil, "globalString: unknown ofs -> (???)")

--------------------------------------------------------------------------
-- ED_Print family on the booted world
local wp = prdebug.edPrint(vm, vm.edicts[1])
t.check(wp:find("\nEDICT 0:\n", 1, true) == 1, "edPrint: EDICT %i header")
t.check(wp:find("classname      worldspawn", 1, true) ~= nil, "edPrint: 15-char name column + value")
t.check(wp:find("wad", 1, true) ~= nil, "edPrint: non-zero fields listed")
t.check(wp:find("_x") == nil, "edPrint: _x/_y/_z vars skipped")

local freed = vmlib.alloc(vm)
vmlib.free(vm, freed)
t.eq(prdebug.edPrint(vm, freed), "FREE\n", "edPrint: FREE for freed edicts")
t.check(prdebug.edPrintNum(vm, 0):find("EDICT 0:") ~= nil, "edPrintNum: routes by number")

local all = prdebug.edPrintEdicts(vm)
t.check(all:find(("%i entities\n"):format(vm.num_edicts), 1, true) == 1, "edPrintEdicts: '%i entities' header")
t.check(select(2, all:gsub("EDICT ", "")) > 50, "edPrintEdicts: every edict printed (e1m1 has many)")

local count = prdebug.edCount(vm)
local numEdicts = tonumber(count:match("num_edicts:%s*(%d+)"))
local active = tonumber(count:match("active%s*:%s*(%d+)"))
local step = tonumber(count:match("step%s*:%s*(%d+)"))
t.eq(numEdicts, vm.num_edicts, "edCount: num_edicts")
t.check(active ~= nil and active > 50, "edCount: active tally")
t.check(step ~= nil and step > 0, "edCount: MOVETYPE_STEP monsters counted")

--------------------------------------------------------------------------
-- PR_PrintStatement: opname padded to 10 + operand global strings
do
	-- find a STORE_F (op 31): two operand strings, no branch text
	local pr = vm.progs
	local sF, sGoto, sIf
	for i = 1, pr.numstatements do
		local op = pr.st_op[i]
		if not sF and op == 31 then
			sF = i - 1
		elseif not sGoto and op == 61 then
			sGoto = i - 1
		elseif not sIf and op == 50 then
			sIf = i - 1
		end
		if sF and sGoto and sIf then
			break
		end
	end
	local line = prdebug.statementString(vm, sF :: number)
	t.check(line:sub(1, 8) == "STORE_F ", "printStatement: opname first")
	t.check(line:find("(", 1, true) ~= nil, "printStatement: operand global strings")
	t.check(prdebug.statementString(vm, sGoto :: number):find("branch %-?%d+") ~= nil, "printStatement: GOTO branch %i")
	t.check(prdebug.statementString(vm, sIf :: number):find("branch %-?%d+") ~= nil, "printStatement: IFNOT branch %i")
end

--------------------------------------------------------------------------
-- PR_StackTrace + the tracer: captured from INSIDE execution by wrapping
-- the remove builtin (#15), then exercised via SUB_Remove
t.eq(prdebug.stackTrace(vm), "<NO STACK>\n", "stackTrace: <NO STACK> outside execution")

local subRemove = vmlib.findFunction(vm, "SUB_Remove") :: number
t.check(subRemove ~= nil, "fixture: SUB_Remove exists")
local victim = vmlib.alloc(vm)
local capturedTrace = ""
local origRemove = vm.builtins[15]
vm.builtins[15] = function(v: vmlib.VM)
	capturedTrace = prdebug.stackTrace(v)
	-- PF_traceon equivalent: statements print from here until DONE
	v.builtins[29](v)
	origRemove(v)
end
vmlib.setGlobalInt(vm, defs.glob.self, victim.num)
table.clear(printed)
vmlib.exec(vm, subRemove)
vm.builtins[15] = origRemove
t.check(capturedTrace:find("SUB_Remove", 1, true) ~= nil, "stackTrace: current function on top (%12s : %s)")
t.check(capturedTrace:find(" : ", 1, true) ~= nil, "stackTrace: file : name format")
t.check(#printed > 0, "traceon: statements printed until DONE")
local sawOp = false
for _, line in printed do
	if line:find("DONE") or line:find("RETURN") or line:find("STORE") then
		sawOp = true
	end
end
t.check(sawOp, "traceon: lines carry opnames")
-- pr_trace resets at the NEXT exec entry (C sets pr_trace=false at the
-- top of PR_ExecuteProgram), so a fresh run prints nothing
local victim2 = vmlib.alloc(vm)
vmlib.setGlobalInt(vm, defs.glob.self, victim2.num)
table.clear(printed)
vmlib.exec(vm, subRemove)
t.check(not vm.trace and #printed == 0, "exec: pr_trace reset on entry (next run silent)")

--------------------------------------------------------------------------
-- PR_Profile_f: statements attributed per function, top list, zeroed
host.frame(svr, 0.1) -- run some QC (thinks) to accumulate profile
local report = prdebug.profileReport(vm)
t.check(report ~= "", "profile: functions accumulated statement counts")
local count1, name1 = report:match("^%s*(%d+) (%S+)\n")
t.check(count1 ~= nil and tonumber(count1) > 0, "profile: '%7i %s' lines")
local secondLine = report:match("\n%s*(%d+)")
if secondLine then
	t.check(tonumber(count1) >= tonumber(secondLine), "profile: descending by count")
end
t.eq(prdebug.profileReport(vm), "", "profile: counters zeroed by the report (C do/while)")

--------------------------------------------------------------------------
-- the PF_coredump / PF_eprint builtins print through svr.print
table.clear(printed)
vm.builtins[31](vm) -- eprint reads OFS_PARM0
t.check(#printed == 1, "PF_eprint: prints one edict dump")
table.clear(printed)
vm.builtins[28](vm)
t.check(printed[1]:find("entities") ~= nil, "PF_coredump: ED_PrintEdicts output")

t.finish("test_prdebug")
