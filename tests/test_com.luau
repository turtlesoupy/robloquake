--!strict
-- com.luau (common.c Q_atoi/Q_atof) and mathlib.anglemod vs C semantics
local t = require("./testutil")
local com = require("../src/shared/engine/common/com")
local mathlib = require("../src/shared/engine/common/mathlib")
local cvarlib = require("../src/shared/engine/common/cvar")

t.eq(com.atoi("12"), 12, "atoi decimal")
t.eq(com.atoi("-7"), -7, "atoi negative")
t.eq(com.atoi("3.9"), 3, "atoi truncates toward zero")
t.eq(com.atoi("-3.9"), -3, "atoi truncates negatives toward zero")
t.eq(com.atoi("0x1A"), 26, "atoi hex as C")
t.eq(com.atoi("junk"), 0, "atoi garbage = 0")

t.eq(com.atof("1.5"), 1.5, "atof decimal")
t.eq(com.atof("-0.25"), -0.25, "atof negative fraction")
t.eq(com.atof(".5"), 0.5, "atof bare fraction")
t.eq(com.atof("0x10"), 16, "atof hex as C")
t.eq(com.atof(""), 0, "atof empty = 0")
t.eq(com.atof("12abc"), 12, "atof stops at the first non-numeric")

-- anglemod: the active C branch is the 360/65536 quantization
local function cAnglemod(a: number): number
	local i = a * (65536 / 360)
	i = if i >= 0 then math.floor(i) else -math.floor(-i) -- C (int) cast
	return (360 / 65536) * bit32.band(i, 65535)
end
local amOk = true
for _, a in { 0, 90, 360, 361, 725, -90, -360.5, 179.99, 54321.123 } do
	if math.abs(mathlib.anglemod(a) - cAnglemod(a)) > 1e-9 then
		amOk = false
	end
end
t.check(amOk, "anglemod matches the transcribed C quantization for 9 cases")
t.eq(mathlib.anglemod(-90), 270, "anglemod(-90) = 270")
t.eq(mathlib.anglemod(360), 0, "anglemod(360) = 0")

-- cvar.c: FindVar/Set/VariableString/VariableValue on a fresh registry
local cv = cvarlib.new()
cvarlib.set(cv, "test_var", "3.5")
t.eq(cvarlib.value(cv, "test_var"), 3.5, "Cvar_Set + Cvar_VariableValue")
t.eq(cvarlib.string(cv, "test_var"), "3.5", "Cvar_VariableString returns the set string")
t.eq(cvarlib.string(cv, "missing_var"), "", "missing cvar reads as empty string (C returns cvar_null_string)")
cvarlib.setValue(cv, "test_var", 7)
t.eq(cvarlib.value(cv, "test_var"), 7, "Cvar_SetValue round-trip")

--------------------------------------------------------------------------
-- Cmd_CompleteCommand / Cvar_CompleteVariable (console Tab completion):
-- exact match wins, then first prefix match (sorted-order delta noted)
local com2 = require("../src/shared/engine/common/com")
local cvarlib2 = require("../src/shared/engine/common/cvar")
local names = { "say_team", "say", "status", "sizeup" }
t.eq(com2.completePrefix(names, "say"), "say", "completePrefix: exact match beats longer names")
t.eq(com2.completePrefix(names, "si"), "sizeup", "completePrefix: prefix match")
t.eq(com2.completePrefix(names, "s"), "say", "completePrefix: first in sorted order")
t.eq(com2.completePrefix(names, "zz"), nil, "completePrefix: no match -> nil")
t.eq(com2.completePrefix(names, ""), nil, "completePrefix: empty partial -> nil (C len check)")

local cvs = cvarlib2.new()
t.eq(cvarlib2.completeVariable(cvs, "host"), "hostname", "completeVariable: prefix match on a real cvar")
t.eq(cvarlib2.completeVariable(cvs, "hostname"), "hostname", "completeVariable: exact match")
t.eq(cvarlib2.completeVariable(cvs, "zzz"), nil, "completeVariable: no match")

t.finish("test_com")
