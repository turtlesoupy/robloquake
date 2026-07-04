--!strict
-- QW builtins (qwbuiltins.luau = QW pr_cmds.c) unit-tested at the
-- register level: parameters written to OFS_PARM* exactly as
-- PR_ExecuteProgram would, results read from OFS_RETURN / world state.
-- Expected values come from the C source semantics (formats, rounding,
-- clamps), not from the port.
local t = require("./testutil")
local fs = require("@lune/fs")
local qwsv = require("../src/shared/engine/qw/qwsv")
local vmlib = require("../src/shared/engine/progs/vm")
local defs = require("../src/shared/engine/progs/defs")
local cvarlib = require("../src/shared/engine/common/cvar")
local mathlib = require("../src/shared/engine/common/mathlib")
local qd = require("../src/shared/engine/quakedef")

local P0 = defs.OFS_PARM0
local P1 = P0 + 3
local P2 = P0 + 6
local RET = defs.OFS_RETURN

local fsys = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(fsys, qwprogs)
local printed: { string } = {}
svr.print = function(s: string)
	table.insert(printed, s)
end
qwsv.spawnServer(svr, "e1m1")
local vm = svr.vm
local ent = svr.qdefs.ent
local B = vm.builtins

local function callStr(num: number, s: string)
	vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, s))
	vm.argc = 1
	B[num](vm)
end

--------------------------------------------------------------------------
-- vector math: PF_normalize(9) / PF_vlen(12) / PF_vectoyaw(13) /
-- PF_vectoangles(51). C truth: yaw = (int)(atan2(y,x)*180/PI), +360 if
-- negative; vectoangles pitch likewise int-truncated.
vmlib.setGlobalVector(vm, P0, vector.create(3, 4, 0))
vm.argc = 1
B[9](vm)
t.check(vector.magnitude(vmlib.globalVector(vm, RET) - vector.create(0.6, 0.8, 0)) < 1e-6, "normalize(3,4,0) = (0.6,0.8,0)")

vmlib.setGlobalVector(vm, P0, vector.create(3, 4, 0))
vm.argc = 1
B[12](vm)
t.check(math.abs(vmlib.globalFloat(vm, RET) - 5) < 1e-6, "vlen(3,4,0) = 5")

local yawCases = {
	{ vector.create(1, 1, 0), 45 },
	{ vector.create(-1, 0, 0), 180 },
	{ vector.create(0, -1, 0), 270 },
	{ vector.create(0, 0, 5), 0 }, -- x==y==0 -> yaw 0 per C
}
local yawOk = true
for _, case in yawCases do
	vmlib.setGlobalVector(vm, P0, case[1] :: vector)
	vm.argc = 1
	B[13](vm)
	if vmlib.globalFloat(vm, RET) ~= case[2] then
		yawOk = false
	end
end
t.check(yawOk, "vectoyaw int-truncates and wraps as C for 4 cases")

vmlib.setGlobalVector(vm, P0, vector.create(1, 0, 1))
vm.argc = 1
B[51](vm)
local va = vmlib.globalVector(vm, RET)
t.check(va.x == 45 and va.y == 0, `vectoangles(1,0,1) pitch 45 yaw 0 ({va})`)

-- PF_fabs(43), PF_rint(36) half-away-from-zero, PF_floor(37), PF_ceil(38)
vmlib.setGlobalFloat(vm, P0, -3.25)
vm.argc = 1
B[43](vm)
t.eq(vmlib.globalFloat(vm, RET), 3.25, "fabs(-3.25)")
local rintCases = { { 0.5, 1 }, { -0.5, -1 }, { 1.4, 1 }, { -1.6, -2 } }
local rintOk = true
for _, case in rintCases do
	vmlib.setGlobalFloat(vm, P0, case[1])
	vm.argc = 1
	B[36](vm)
	if vmlib.globalFloat(vm, RET) ~= case[2] then
		rintOk = false
	end
end
t.check(rintOk, "rint rounds half away from zero as C (4 cases)")
vmlib.setGlobalFloat(vm, P0, -0.5)
vm.argc = 1
B[37](vm)
t.eq(vmlib.globalFloat(vm, RET), -1, "floor(-0.5) = -1")
vmlib.setGlobalFloat(vm, P0, 0.25)
vm.argc = 1
B[38](vm)
t.eq(vmlib.globalFloat(vm, RET), 1, "ceil(0.25) = 1")

-- PF_random(7): (rand()&0x7fff)/0x7fff in [0,1)
local rOk = true
for _ = 1, 200 do
	vm.argc = 0
	B[7](vm)
	local r = vmlib.globalFloat(vm, RET)
	if r < 0 or r > 1 then
		rOk = false
	end
end
t.check(rOk, "random() stays in [0,1] over 200 draws")

--------------------------------------------------------------------------
-- strings: PF_ftos(26) "%d" for integers else "%5.1f"; PF_vtos(27)
-- "'%5.1f %5.1f %5.1f'"; PF_stof(81) atof semantics
vmlib.setGlobalFloat(vm, P0, 7)
vm.argc = 1
B[26](vm)
t.eq(vmlib.globalString(vm, RET), "7", 'ftos(7) = "7"')
vmlib.setGlobalFloat(vm, P0, 7.25)
vm.argc = 1
B[26](vm)
-- C printf %.1f rounds 7.25 half-to-even -> "  7.2"
t.eq(vmlib.globalString(vm, RET), "  7.2", 'ftos(7.25) = "  7.2" (%5.1f, half-even as C printf)')
vmlib.setGlobalVector(vm, P0, vector.create(1, -2.5, 300))
vm.argc = 1
B[27](vm)
t.eq(vmlib.globalString(vm, RET), "'  1.0  -2.5 300.0'", "vtos %5.1f triple as C")
callStr(81, "3.5xyz")
t.eq(vmlib.globalFloat(vm, RET), 3.5, 'stof("3.5xyz") = 3.5')
callStr(81, "")
t.eq(vmlib.globalFloat(vm, RET), 0, 'stof("") = 0')

--------------------------------------------------------------------------
-- cvars: PF_cvar(45) / PF_cvar_set(72)
vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, "sv_gravity"))
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "640"))
vm.argc = 2
B[72](vm)
callStr(45, "sv_gravity")
t.eq(vmlib.globalFloat(vm, RET), 640, "cvar_set + cvar round-trip (sv_gravity 640)")
cvarlib.set(svr.cvars, "sv_gravity", "800")

--------------------------------------------------------------------------
-- entities: PF_Spawn(14) / PF_setorigin(2) / PF_setsize(4) /
-- PF_findradius(22) / PF_Find(18) / PF_nextent(47) / PF_Remove(15)
vm.argc = 0
B[14](vm)
local spawned = vmlib.globalEdict(vm, RET)
t.check(spawned.num > 0 and not spawned.free, "PF_Spawn returns a fresh edict")

local player1 = svr.clients and nil
local spot = vector.create(480, -352, 88) -- e1m1 info_player_start area
vmlib.setGlobalInt(vm, P0, spawned.num)
vmlib.setGlobalVector(vm, P1, spot)
vm.argc = 2
B[2](vm)
t.check(vector.magnitude(vmlib.edVector(spawned, ent.origin) - spot) < 1e-6, "PF_setorigin places and links")

vmlib.setGlobalInt(vm, P0, spawned.num)
vmlib.setGlobalVector(vm, P1, vector.create(-8, -8, -8))
vmlib.setGlobalVector(vm, P2, vector.create(8, 8, 8))
vm.argc = 3
B[4](vm)
t.check(
	vmlib.edVector(spawned, ent.mins) == vector.create(-8, -8, -8)
		and vmlib.edVector(spawned, ent.size) == vector.create(16, 16, 16),
	"PF_setsize writes mins/maxs/size"
)

-- findradius chains entities around the spot (our fresh edict included;
-- C skips SOLID_NOT, so give it a solid)
vmlib.edSetFloat(spawned, ent.solid, qd.SOLID_TRIGGER)
vmlib.setGlobalVector(vm, P0, spot)
vmlib.setGlobalFloat(vm, P1, 64)
vm.argc = 2
B[22](vm)
local chainHead = vmlib.globalEdict(vm, RET)
local found = false
local hops = 0
local node = chainHead
while node.num ~= 0 and hops < 50 do
	if node == spawned then
		found = true
	end
	node = vmlib.edictNum(vm, vmlib.edInt(node, ent.chain))
	hops += 1
end
t.check(found, "PF_findradius chains the staged edict at the center")

-- PF_Find walks by classname from world
vmlib.setGlobalInt(vm, P0, 0)
vmlib.setGlobalInt(vm, P1, svr.qdefs.ent.classname)
vmlib.setGlobalInt(vm, P2, vmlib.allocString(vm, "door"))
vm.argc = 3
B[18](vm)
local firstDoor = vmlib.globalEdict(vm, RET)
t.check(firstDoor.num > 0 and vmlib.edString(vm, firstDoor, ent.classname) == "door", "PF_Find(world, classname, door)")

-- PF_nextent skips free slots
vmlib.setGlobalInt(vm, P0, 0)
vm.argc = 1
B[47](vm)
local nxt = vmlib.globalEdict(vm, RET)
t.check(nxt.num == 1 and not nxt.free, "PF_nextent(world) = edict 1")

-- PF_Remove frees
vmlib.setGlobalInt(vm, P0, spawned.num)
vm.argc = 1
B[15](vm)
t.check(spawned.free, "PF_Remove frees the edict")

--------------------------------------------------------------------------
-- PF_setmodel(3): precached brush model gives brush bounds
vm.argc = 0
B[14](vm)
local doorEnt = vmlib.globalEdict(vm, RET)
vmlib.setGlobalInt(vm, P0, doorEnt.num)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "*1"))
vm.argc = 2
B[3](vm)
t.check(vmlib.edFloat(doorEnt, ent.modelindex) > 0, "PF_setmodel sets modelindex for a precached brush")
t.check(vmlib.edVector(doorEnt, ent.size).x > 0, "PF_setmodel takes brush mins/maxs")
local okUnknown = pcall(function()
	vmlib.setGlobalInt(vm, P0, doorEnt.num)
	vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "progs/notprecached.mdl"))
	vm.argc = 2
	B[3](vm)
end)
t.check(not okUnknown, "PF_setmodel errors on a model missing from precache (as C)")
vmlib.setGlobalInt(vm, P0, doorEnt.num)
vm.argc = 1
B[15](vm)

--------------------------------------------------------------------------
-- PF_droptofloor(34): an entity above the start floor settles onto it
vm.argc = 0
B[14](vm)
local dropper = vmlib.globalEdict(vm, RET)
vmlib.edSetFloat(dropper, ent.solid, qd.SOLID_BBOX)
vmlib.edSetFloat(dropper, ent.movetype, qd.MOVETYPE_TOSS)
vmlib.setGlobalInt(vm, P0, dropper.num)
vmlib.setGlobalVector(vm, P1, vector.zero)
vmlib.setGlobalVector(vm, P2, vector.zero)
vm.argc = 3
B[4](vm)
vmlib.setGlobalInt(vm, P0, dropper.num)
vmlib.setGlobalVector(vm, P1, spot + vector.create(0, 0, 40))
vm.argc = 2
B[2](vm)
buffer.writei32(vm.globals, svr.qdefs.glob.self * 4, dropper.num)
vm.argc = 0
B[34](vm)
t.eq(vmlib.globalFloat(vm, RET), 1, "PF_droptofloor returns 1 on landing")
local dz = vmlib.edVector(dropper, ent.origin).z
t.check(dz < spot.z + 40 and dz > spot.z - 60, `dropper settled onto the floor (z {dz})`)
t.check(bit32.band(vmlib.edFloat(dropper, ent.flags), qd.FL_ONGROUND) ~= 0, "droptofloor sets FL_ONGROUND")

--------------------------------------------------------------------------
-- PR_CheckEmptyString via PF_precache_sound(19); precache dedup + the
-- ss_loading gate (precaching after spawn errors, as C)
local okEmpty = pcall(function()
	callStr(19, "")
end)
t.check(not okEmpty, "precache_sound(\"\") errors through PR_CheckEmptyString")
local okLate = pcall(function()
	callStr(19, "misc/late.wav")
end)
t.check(not okLate, "precache_sound after spawn errors (ss_loading gate, as C)")
-- even an already-precached name errors post-spawn: the ss_loading
-- gate precedes the dedup in C
local okDup = pcall(function()
	callStr(19, "weapons/guncock.wav")
end)
t.check(not okDup, "precache_sound post-spawn errors even for known names (gate before dedup, as C)")
callStr(77, "maps/whatever.txt") -- precache_file: no-op pass-through
t.eq(vmlib.globalString(vm, RET), "maps/whatever.txt", "precache_file passes the parm through")

--------------------------------------------------------------------------
-- prints: PF_bprint(23) level + varstring concat; PF_dprint(25);
-- PF_error(10) raises
local bcast: { { level: number, text: string } } = {}
svr.broadcastPrint = function(_svr: any, level: number, text: string)
	table.insert(bcast, { level = level, text = text })
end
vmlib.setGlobalFloat(vm, P0, 2)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "part1 "))
vmlib.setGlobalInt(vm, P2, vmlib.allocString(vm, "part2"))
vm.argc = 3
B[23](vm)
t.check(#bcast == 1 and bcast[1].level == 2 and bcast[1].text == "part1 part2", "bprint(level, ...) concatenates via PF_VarString")

local dprints: { string } = {}
svr.dprint = function(s: string)
	table.insert(dprints, s)
end
callStr(25, "debug line")
t.check(#dprints == 1 and dprints[1]:find("debug line") ~= nil, "dprint reaches svr.dprint")

local okError = pcall(function()
	vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, "boom"))
	vm.argc = 1
	B[10](vm)
end)
t.check(not okError, "PF_error raises")
buffer.writei32(vm.globals, svr.qdefs.glob.self * 4, 1)
local okObj = pcall(function()
	vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, "objboom"))
	vm.argc = 1
	B[11](vm)
end)
t.check(not okObj, "PF_objerror raises")

-- PF_pointcontents(41): open air at the start vs solid outside the hull
vmlib.setGlobalVector(vm, P0, spot + vector.create(0, 0, 8))
vm.argc = 1
B[41](vm)
t.eq(vmlib.globalFloat(vm, RET), qd.CONTENTS_EMPTY, "pointcontents(start area) = EMPTY")
vmlib.setGlobalVector(vm, P0, vector.create(-20000, -20000, -20000))
vm.argc = 1
B[41](vm)
t.eq(vmlib.globalFloat(vm, RET), qd.CONTENTS_SOLID, "pointcontents(outside world) = SOLID")

--------------------------------------------------------------------------
-- PF_aim(44): with sv_aim 2 (QW default: assist off) returns v_forward
local shooter = vmlib.edictNum(vm, 1)
buffer.writei32(vm.globals, svr.qdefs.glob.self * 4, 1)
vmlib.setGlobalVector(vm, svr.qdefs.glob.v_forward, vector.create(0, 1, 0))
vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalFloat(vm, P1, 1000)
vm.argc = 2
B[44](vm)
t.check(vmlib.globalVector(vm, RET) == vector.create(0, 1, 0), "aim with sv_aim 2 returns v_forward unchanged")
local _ = shooter
local _2 = player1
local _3 = mathlib

--------------------------------------------------------------------------
-- writes: PF_WriteByte..PF_WriteEntity (52-59) into MSG_MULTICAST
local msglib = require("../src/shared/engine/common/msg")
svr.multicast = msglib.newBuf(1024)
local function writeCall(num: number, dest: number, value: number)
	vmlib.setGlobalFloat(vm, P0, dest)
	vmlib.setGlobalFloat(vm, P1, value)
	vm.argc = 2
	B[num](vm)
end
writeCall(52, 4, 200) -- WriteByte
writeCall(53, 4, -3) -- WriteChar
writeCall(54, 4, 1234) -- WriteShort
writeCall(55, 4, 123456) -- WriteLong
writeCall(57, 4, 90) -- WriteAngle
writeCall(56, 4, 12.5) -- WriteCoord
vmlib.setGlobalFloat(vm, P0, 4)
vmlib.setGlobalInt(vm, P1, 3) -- WriteEntity reads the edict ref register
vm.argc = 2
B[59](vm)
local mc = svr.multicast
t.eq(mc.cursize, 1 + 1 + 2 + 4 + 1 + 2 + 2, "Write* sizes: byte+char+short+long+angle+coord+entity")
t.eq(buffer.readu8(mc.data, 0), 200, "WriteByte value")
t.eq(buffer.readi8(mc.data, 1), -3, "WriteChar value")
t.eq(buffer.readi16(mc.data, 2), 1234, "WriteShort value")
t.eq(buffer.readi32(mc.data, 4), 123456, "WriteLong value")
t.eq(buffer.readu8(mc.data, 8), 64, "WriteAngle 90 deg = byte 64")
t.eq(buffer.readi16(mc.data, 9), 100, "WriteCoord 12.5 = 100 (1/8 units)")
t.eq(buffer.readi16(mc.data, 11), 3, "WriteEntity writes the edict number as short")

--------------------------------------------------------------------------
-- client-facing builtins: PF_setspawnparms(78), PF_logfrag(79),
-- PF_infokey(80) userinfo path. Connect real clients for edicts 1/2.
qwsv.connectClient(svr, 1, { name = "parmee" })
qwsv.connectClient(svr, 2, { name = "victim" })
local c1 = svr.clients[1]
for j = 1, 16 do
	c1.spawn_parms[j] = j * 10
end
vmlib.setGlobalInt(vm, P0, 1)
vm.argc = 1
B[78](vm)
t.check(
	vmlib.globalFloat(vm, svr.qdefs.glob.parm1) == 10 and vmlib.globalFloat(vm, svr.qdefs.glob.parm1 + 15) == 160,
	"PF_setspawnparms copies client parms into the parm globals"
)

local frags: { { number } } = {}
svr.logfrag = function(_svr: any, e1: number, e2: number)
	table.insert(frags, { e1, e2 })
end
vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalInt(vm, P1, 2)
vm.argc = 2
B[79](vm)
t.check(#frags == 1 and frags[1][1] == 1 and frags[1][2] == 2, "PF_logfrag reports killer/killee edict numbers")

vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "name"))
vm.argc = 2
B[80](vm)
t.eq(vmlib.globalString(vm, RET), "parmee", "infokey(client, name) reads userinfo")

--------------------------------------------------------------------------
-- PF_infokey(80): world entity reads serverinfo
svr.serverinfo.hostname = "qwtest"
vmlib.setGlobalInt(vm, P0, 0)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "hostname"))
vm.argc = 2
B[80](vm)
t.eq(vmlib.globalString(vm, RET), "qwtest", "infokey(world, hostname) reads serverinfo")

--------------------------------------------------------------------------
-- PF_localcmd(46) + PF_changelevel(70) double-issue guard
callStr(46, "changelevel e1m2\n")
t.eq(svr.changelevelTo, "e1m2", "localcmd changelevel routes to changelevelTo")
svr.changelevelTo = nil
svr.changelevelIssued = false
callStr(70, "e1m3")
callStr(70, "e1m4")
t.eq(svr.changelevelTo, "e1m3", "PF_changelevel latches once (double-issue guard as C)")

t.finish("test_qwbuiltins")
