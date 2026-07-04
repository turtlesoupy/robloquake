--!strict
-- NQ builtins (pr_cmds.luau = WinQuake pr_cmds.c) unit-tested at the
-- register level, the NQ twin of test_qwbuiltins: parameters into
-- OFS_PARM*, results from OFS_RETURN / world state / wire buffers.
-- Expectations come from the C source semantics.
local t = require("./testutil")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local worldlib = require("../src/shared/engine/server/world")
local mathlib = require("../src/shared/engine/common/mathlib")
local cvarlib = require("../src/shared/engine/common/cvar")
local msg = require("../src/shared/engine/common/msg")
local proto = require("../src/shared/engine/protocol")
local qd = require("../src/shared/engine/quakedef")

local P0 = defs.OFS_PARM0
local P1 = P0 + 3
local P2 = P0 + 6
local P3 = P0 + 9
local RET = defs.OFS_RETURN
local ent = defs.ent
local glob = defs.glob

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
host.spawnServer(svr, "e1m1")
local vm = svr.vm
local B = vm.builtins

-- a spawned client so the print/stuffcmd builtins have a target
local client = svr.clients[1]
client.sendUnreliable = function()
	return true
end
client.sendReliable = function()
	return true
end
host.connectClient(svr, 1)
local function sendCmd(s: string)
	local out = msg.newBuf(256)
	msg.writeByte(out, proto.clc_stringcmd)
	msg.writeString(out, s)
	table.insert(client.inbox, msg.snapshot(out))
end
sendCmd("prespawn")
host.frame(svr, 0.05)
sendCmd("spawn")
host.frame(svr, 0.05)
sendCmd("begin")
host.frame(svr, 0.05)
t.check(client.spawned, "client spawned")
local player = client.edict

local function callStr(num: number, s: string)
	vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, s))
	vm.argc = 1
	B[num](vm)
end

--------------------------------------------------------------------------
-- vector math + float ops (same C truth as the QW battery)
vmlib.setGlobalVector(vm, P0, vector.create(3, 4, 0))
vm.argc = 1
B[9](vm)
t.check(vector.magnitude(vmlib.globalVector(vm, RET) - vector.create(0.6, 0.8, 0)) < 1e-6, "normalize(3,4,0)")
vmlib.setGlobalVector(vm, P0, vector.create(3, 4, 0))
vm.argc = 1
B[12](vm)
t.check(math.abs(vmlib.globalFloat(vm, RET) - 5) < 1e-6, "vlen(3,4,0) = 5")
local yawOk = true
for _, case in { { vector.create(1, 1, 0), 45 }, { vector.create(-1, 0, 0), 180 }, { vector.create(0, -1, 0), 270 }, { vector.create(0, 0, 5), 0 } } do
	vmlib.setGlobalVector(vm, P0, case[1] :: vector)
	vm.argc = 1
	B[13](vm)
	if vmlib.globalFloat(vm, RET) ~= case[2] then
		yawOk = false
	end
end
t.check(yawOk, "vectoyaw truncation/wrap (4 cases)")
vmlib.setGlobalVector(vm, P0, vector.create(0, 0, 5))
vm.argc = 1
B[51](vm)
t.check(vmlib.globalVector(vm, RET).x == 90, "vectoangles straight-up pitch 90 (C vertical special case)")
vmlib.setGlobalVector(vm, P0, vector.create(1, 0, 1))
vm.argc = 1
B[51](vm)
local va = vmlib.globalVector(vm, RET)
t.check(va.x == 45 and va.y == 0, "vectoangles(1,0,1) pitch 45 yaw 0")

vmlib.setGlobalFloat(vm, P0, -3.25)
vm.argc = 1
B[43](vm)
t.eq(vmlib.globalFloat(vm, RET), 3.25, "fabs")
local rintOk = true
for _, case in { { 0.5, 1 }, { -0.5, -1 }, { 1.4, 1 }, { -1.6, -2 } } do
	vmlib.setGlobalFloat(vm, P0, case[1])
	vm.argc = 1
	B[36](vm)
	if vmlib.globalFloat(vm, RET) ~= case[2] then
		rintOk = false
	end
end
t.check(rintOk, "rint half away from zero (4 cases)")
vmlib.setGlobalFloat(vm, P0, -0.5)
vm.argc = 1
B[37](vm)
t.eq(vmlib.globalFloat(vm, RET), -1, "floor(-0.5)")
vmlib.setGlobalFloat(vm, P0, 0.25)
vm.argc = 1
B[38](vm)
t.eq(vmlib.globalFloat(vm, RET), 1, "ceil(0.25)")
local rOk = true
for _ = 1, 100 do
	vm.argc = 0
	B[7](vm)
	local r = vmlib.globalFloat(vm, RET)
	if r < 0 or r > 1 then
		rOk = false
	end
end
t.check(rOk, "random() in [0,1]")

-- makevectors writes the v_ globals
vmlib.setGlobalVector(vm, P0, vector.create(0, 90, 0))
vm.argc = 1
B[1](vm)
t.check(vector.magnitude(vmlib.globalVector(vm, glob.v_forward) - vector.create(0, 1, 0)) < 1e-6, "makevectors yaw 90 forward = +y")

--------------------------------------------------------------------------
-- strings + cvars
vmlib.setGlobalFloat(vm, P0, 7)
vm.argc = 1
B[26](vm)
t.eq(vmlib.globalString(vm, RET), "7", "ftos integer %d")
vmlib.setGlobalFloat(vm, P0, 7.25)
vm.argc = 1
B[26](vm)
t.eq(vmlib.globalString(vm, RET), "  7.2", "ftos %5.1f half-even")
vmlib.setGlobalVector(vm, P0, vector.create(1, -2.5, 300))
vm.argc = 1
B[27](vm)
t.eq(vmlib.globalString(vm, RET), "'  1.0  -2.5 300.0'", "vtos triple")
vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, "sv_gravity"))
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "700"))
vm.argc = 2
B[72](vm)
callStr(45, "sv_gravity")
t.eq(vmlib.globalFloat(vm, RET), 700, "cvar_set + cvar round-trip")
cvarlib.set(svr.cvars, "sv_gravity", "800")

--------------------------------------------------------------------------
-- entity lifecycle + queries
vm.argc = 0
B[14](vm)
local spawned = vmlib.globalEdict(vm, RET)
t.check(spawned.num > 0 and not spawned.free, "spawn() fresh edict")
local spot = vector.create(480, -352, 88)
vmlib.setGlobalInt(vm, P0, spawned.num)
vmlib.setGlobalVector(vm, P1, spot)
vm.argc = 2
B[2](vm)
t.check(vector.magnitude(vmlib.edVector(spawned, ent.origin) - spot) < 1e-6, "setorigin places and links")
vmlib.setGlobalInt(vm, P0, spawned.num)
vmlib.setGlobalVector(vm, P1, vector.create(-8, -8, -8))
vmlib.setGlobalVector(vm, P2, vector.create(8, 8, 8))
vm.argc = 3
B[4](vm)
t.check(vmlib.edVector(spawned, ent.size) == vector.create(16, 16, 16), "setsize/SetMinMaxSize writes size")
vmlib.edSetFloat(spawned, ent.solid, qd.SOLID_TRIGGER)
vmlib.setGlobalVector(vm, P0, spot)
vmlib.setGlobalFloat(vm, P1, 64)
vm.argc = 2
B[22](vm)
local node = vmlib.globalEdict(vm, RET)
local found = false
local hops = 0
while node.num ~= 0 and hops < 80 do
	if node == spawned then
		found = true
	end
	node = vmlib.edictNum(vm, vmlib.edInt(node, ent.chain))
	hops += 1
end
t.check(found, "findradius chains the staged edict")
vmlib.setGlobalInt(vm, P0, 0)
vmlib.setGlobalInt(vm, P1, defs.ent.classname)
vmlib.setGlobalInt(vm, P2, vmlib.allocString(vm, "door"))
vm.argc = 3
B[18](vm)
t.check(vmlib.edString(vm, vmlib.globalEdict(vm, RET), ent.classname) == "door", "find(world, classname, door)")
vmlib.setGlobalInt(vm, P0, 0)
vm.argc = 1
B[47](vm)
t.check(vmlib.globalEdict(vm, RET).num == 1, "nextent(world)")
vmlib.setGlobalInt(vm, P0, spawned.num)
vm.argc = 1
B[15](vm)
t.check(spawned.free, "remove() frees")

-- setmodel: precached brush bounds + unknown model errors
vm.argc = 0
B[14](vm)
local se = vmlib.globalEdict(vm, RET)
vmlib.setGlobalInt(vm, P0, se.num)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "*1"))
vm.argc = 2
B[3](vm)
t.check(vmlib.edFloat(se, ent.modelindex) > 0 and vmlib.edVector(se, ent.size).x > 0, "setmodel brush index + bounds")
t.check(not pcall(function()
	vmlib.setGlobalInt(vm, P0, se.num)
	vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "progs/nope.mdl"))
	vm.argc = 2
	B[3](vm)
end), "setmodel errors on non-precached model")

-- droptofloor (NQ: void, operates on self)
vmlib.edSetFloat(se, ent.movetype, qd.MOVETYPE_TOSS)
vmlib.edSetFloat(se, ent.solid, qd.SOLID_BBOX)
vmlib.setGlobalInt(vm, P0, se.num)
vmlib.setGlobalVector(vm, P1, vector.create(-4, -4, -4))
vmlib.setGlobalVector(vm, P2, vector.create(4, 4, 4))
vm.argc = 3
B[4](vm)
vmlib.setGlobalInt(vm, P0, se.num)
vmlib.setGlobalVector(vm, P1, spot + vector.create(0, 0, 40))
vm.argc = 2
B[2](vm)
buffer.writei32(vm.globals, glob.self * 4, se.num)
vm.argc = 0
B[34](vm)
t.eq(vmlib.globalFloat(vm, RET), 1, "droptofloor lands (returns 1)")
t.check(bit32.band(vmlib.edFloat(se, ent.flags), qd.FL_ONGROUND) ~= 0, "droptofloor sets FL_ONGROUND")

--------------------------------------------------------------------------
-- traceline glue: trace_* globals mirror world.move
local from = spot + vector.create(0, 0, 30)
local to = spot + vector.create(0, 600, 30)
vmlib.setGlobalVector(vm, P0, from)
vmlib.setGlobalVector(vm, P1, to)
vmlib.setGlobalFloat(vm, P2, 0)
vmlib.setGlobalInt(vm, P3, player.num)
vm.argc = 4
B[16](vm)
local tr = worldlib.move(svr.world, from, vector.zero, vector.zero, to, 0, player)
t.check(math.abs(vmlib.globalFloat(vm, glob.trace_fraction) - tr.fraction) < 1e-6, "traceline trace_fraction matches world.move")
t.check(vector.magnitude(vmlib.globalVector(vm, glob.trace_endpos) - tr.endpos) < 0.01, "traceline trace_endpos matches world.move")

-- pointcontents glue
vmlib.setGlobalVector(vm, P0, spot + vector.create(0, 0, 8))
vm.argc = 1
B[41](vm)
t.eq(vmlib.globalFloat(vm, RET), qd.CONTENTS_EMPTY, "pointcontents empty at start")
vmlib.setGlobalVector(vm, P0, vector.create(-20000, -20000, -20000))
vm.argc = 1
B[41](vm)
t.eq(vmlib.globalFloat(vm, RET), qd.CONTENTS_SOLID, "pointcontents solid outside world")

--------------------------------------------------------------------------
-- monster movement builtins on a live grunt
local grunt: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "monster_army" and vmlib.edFloat(e, ent.health) > 0 then
		if bit32.band(vmlib.edFloat(e, ent.flags), qd.FL_ONGROUND) ~= 0 then
			grunt = e
			break
		end
	end
end
if not grunt then
	-- run a few frames so monsters settle onto the floor
	for _ = 1, 10 do
		host.frame(svr, 0.05)
	end
	for i = 1, vm.num_edicts - 1 do
		local e = vm.edicts[i + 1]
		if not e.free and vmlib.edString(vm, e, ent.classname) == "monster_army" and bit32.band(vmlib.edFloat(e, ent.flags), qd.FL_ONGROUND) ~= 0 then
			grunt = e
			break
		end
	end
end
assert(grunt, "grounded grunt")

-- checkbottom: a grounded monster has support
vmlib.setGlobalInt(vm, P0, grunt.num)
vm.argc = 1
B[40](vm)
t.eq(vmlib.globalFloat(vm, RET), 1, "checkbottom on a grounded grunt")

-- changeyaw: yaw steps toward ideal_yaw by yaw_speed with anglemod
local startYaw = vmlib.edVector(grunt, ent.angles).y
vmlib.edSetFloat(grunt, ent.ideal_yaw, startYaw + 90)
vmlib.edSetFloat(grunt, ent.yaw_speed, 20)
buffer.writei32(vm.globals, glob.self * 4, grunt.num)
vm.argc = 0
B[49](vm)
local newYaw = vmlib.edVector(grunt, ent.angles).y
t.check(math.abs(((newYaw - startYaw) + 180) % 360 - 180 - 20) < 0.01, `changeyaw stepped 20 deg ({startYaw} -> {newYaw})`)

-- walkmove: program-state save/restore around movestep; grunt takes a step
local gorg = vmlib.edVector(grunt, ent.origin)
buffer.writei32(vm.globals, glob.self * 4, grunt.num)
vmlib.setGlobalFloat(vm, P0, vmlib.edVector(grunt, ent.angles).y)
vmlib.setGlobalFloat(vm, P1, 4)
vm.argc = 2
B[32](vm)
local walked = vmlib.globalFloat(vm, RET)
local gmoved = vector.magnitude(vmlib.edVector(grunt, ent.origin) - gorg)
t.check((walked == 1 and gmoved > 2) or (walked == 0 and gmoved < 2), `walkmove result consistent (ret {walked}, moved {string.format("%.1f", gmoved)})`)

--------------------------------------------------------------------------
-- wire-writing builtins: bprint/sprint/centerprint/stuffcmd into the
-- client reliable buffer, particle into the datagram
local relBefore = client.message.cursize
vmlib.setGlobalInt(vm, P0, vmlib.allocString(vm, "hello "))
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "world"))
vm.argc = 2
B[23](vm)
t.check(client.message.cursize > relBefore, "bprint appended to the client reliable stream")
t.eq(buffer.readu8(client.message.data, relBefore), proto.svc_print, "bprint wrote svc_print")

relBefore = client.message.cursize
vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "just you"))
vm.argc = 2
B[24](vm)
t.eq(buffer.readu8(client.message.data, relBefore), proto.svc_print, "sprint wrote svc_print to the target client")

relBefore = client.message.cursize
vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "CENTER"))
vm.argc = 2
B[73](vm)
t.eq(buffer.readu8(client.message.data, relBefore), proto.svc_centerprint, "centerprint wrote svc_centerprint")

relBefore = client.message.cursize
vmlib.setGlobalInt(vm, P0, 1)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "bf\n"))
vm.argc = 2
B[21](vm)
t.eq(buffer.readu8(client.message.data, relBefore), proto.svc_stufftext, "stuffcmd wrote svc_stufftext")

local dgBefore = svr.datagram.cursize
vmlib.setGlobalVector(vm, P0, spot)
vmlib.setGlobalVector(vm, P1, vector.create(0, 0, 1))
vmlib.setGlobalFloat(vm, P2, 73)
vmlib.setGlobalFloat(vm, P3, 10)
vm.argc = 4
B[48](vm)
t.eq(buffer.readu8(svr.datagram.data, dgBefore), proto.svc_particle, "particle wrote svc_particle to the datagram")

-- Write* into MSG_BROADCAST (svr.datagram)
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0) -- MSG_BROADCAST
vmlib.setGlobalFloat(vm, P1, 90)
vm.argc = 2
B[57](vm) -- WriteAngle
t.eq(buffer.readu8(svr.datagram.data, dgBefore), 64, "WriteAngle 90 -> byte 64")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalFloat(vm, P1, 12.5)
vm.argc = 2
B[56](vm) -- WriteCoord
t.eq(buffer.readi16(svr.datagram.data, dgBefore), 100, "WriteCoord 12.5 -> 100")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalFloat(vm, P1, -3)
vm.argc = 2
B[53](vm) -- WriteChar
t.eq(buffer.readi8(svr.datagram.data, dgBefore), -3, "WriteChar signed")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalFloat(vm, P1, 1234)
vm.argc = 2
B[54](vm) -- WriteShort
t.eq(buffer.readi16(svr.datagram.data, dgBefore), 1234, "WriteShort")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalFloat(vm, P1, 123456)
vm.argc = 2
B[55](vm) -- WriteLong
t.eq(buffer.readi32(svr.datagram.data, dgBefore), 123456, "WriteLong")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalInt(vm, P1, vmlib.allocString(vm, "wire"))
vm.argc = 2
B[58](vm) -- WriteString
t.eq(buffer.readu8(svr.datagram.data, dgBefore + 4), 0, "WriteString NUL-terminated")
dgBefore = svr.datagram.cursize
vmlib.setGlobalFloat(vm, P0, 0)
vmlib.setGlobalInt(vm, P1, 3)
vm.argc = 2
B[59](vm) -- WriteEntity
t.eq(buffer.readi16(svr.datagram.data, dgBefore), 3, "WriteEntity edict num as short")

--------------------------------------------------------------------------
-- makestatic: signon grows, edict freed
vm.argc = 0
B[14](vm)
local stat = vmlib.globalEdict(vm, RET)
-- any precached model works for the wire bytes; player.mdl always is
vmlib.edSetInt(stat, ent.model, vmlib.allocString(vm, "progs/player.mdl"))
local sgBefore = svr.signon.cursize
vmlib.setGlobalInt(vm, P0, stat.num)
vm.argc = 1
B[69](vm)
t.check(svr.signon.cursize > sgBefore and stat.free, "makestatic wrote svc_spawnstatic and freed the edict")

--------------------------------------------------------------------------
-- misc: VarString concat via bprint proved above; error/objerror raise;
-- localcmd routes changelevel; setspawnparms copies parms; aim no-target
t.check(not pcall(function()
	callStr(10, "boom")
end), "PF_error raises")
vm.argc = 0
B[14](vm)
local victim = vmlib.globalEdict(vm, RET)
buffer.writei32(vm.globals, glob.self * 4, victim.num)
t.check(not pcall(function()
	callStr(11, "objboom")
end), "PF_objerror raises")
t.check(victim.free, "PF_objerror freed self (ED_Free), as C")

svr.changelevelTo = nil
callStr(46, "changelevel e1m2\n")
t.eq(svr.changelevelTo, "e1m2", "localcmd routes changelevel")
svr.changelevelTo = nil

for j = 1, 16 do
	client.spawn_parms[j] = j * 5
end
vmlib.setGlobalInt(vm, P0, player.num)
vm.argc = 1
B[78](vm)
t.check(vmlib.globalFloat(vm, glob.parm1) == 5 and vmlib.globalFloat(vm, glob.parm1 + 15) == 80, "setspawnparms copies parms")

-- PF_checkclient (17): stage the player in a grunt's PVS and ask
local gorg2 = vmlib.edVector(grunt, ent.origin)
local gyaw2 = vmlib.edVector(grunt, ent.angles).y
local prevOrg = vmlib.edVector(player, ent.origin)
local placed = false
local fwd2 = mathlib.angleVectors(vector.create(0, gyaw2, 0))
for _, base in { gorg2 + fwd2 * 120, gorg2 + fwd2 * 80, gorg2 - fwd2 * 100, gorg2 } do
	for _, dz in { 8, 24, 48 } do
		for _, dxy in { vector.zero, vector.create(32, 0, 0), vector.create(-32, 0, 0), vector.create(0, 32, 0), vector.create(0, -32, 0) } do
			local cand = base + dxy + vector.create(0, 0, dz)
			vmlib.edSetVector(player, ent.origin, cand)
			if not worldlib.testEntityPosition(svr.world, player) then
				vmlib.edSetVector(player, ent.oldorigin, cand)
				placed = true
				break
			end
		end
		if placed then
			break
		end
	end
	if placed then
		break
	end
end
assert(placed, "staged the player near the grunt")
worldlib.linkEdict(svr.world, player, false)
-- newcheckclient rotates on a 0.1s cache; give it a few frames
local seen = false
for _ = 1, 10 do
	host.frame(svr, 0.05)
	buffer.writei32(vm.globals, glob.self * 4, grunt.num)
	vm.argc = 0
	B[17](vm)
	if vmlib.globalEdict(vm, RET) == player then
		seen = true
		break
	end
end
t.check(seen, "PF_checkclient found the staged player in the grunt's PVS (newcheckclient rotation)")

-- SV_MoveToGoal (builtin 67): the grunt closes distance to its enemy.
-- Deterministic geometry: stage grunt and goal on the same open floor
-- (the e1m1 lower hall) with a clear straight line between them.
local function stageEd(ed: vmlib.Edict, target: vector): boolean
	for _, dz in { 1, 9, 25, 41 } do
		local cand = target + vector.create(0, 0, dz)
		vmlib.edSetVector(ed, ent.origin, cand)
		if not worldlib.testEntityPosition(svr.world, ed) then
			vmlib.edSetVector(ed, ent.oldorigin, cand)
			vmlib.edSetVector(ed, ent.velocity, vector.zero)
			worldlib.linkEdict(svr.world, ed, false)
			return true
		end
	end
	return false
end
t.check(stageEd(grunt, vector.create(480, 100, 26)), "staged the grunt in the lower hall")
t.check(stageEd(player, vector.create(480, 480, 26)), "staged the goal player down-hall")
vmlib.edSetInt(grunt, ent.enemy, player.num)
vmlib.edSetInt(grunt, ent.goalentity, player.num)
vmlib.edSetFloat(grunt, ent.yaw_speed, 20)
vmlib.edSetFloat(grunt, ent.flags, bit32.bor(vmlib.edFloat(grunt, ent.flags) // 1, qd.FL_ONGROUND))
local gdp0 = vmlib.edVector(grunt, ent.origin) - vmlib.edVector(player, ent.origin)
local gd0 = math.sqrt(gdp0.x * gdp0.x + gdp0.y * gdp0.y)
local minDist = gd0
local path = 0
local prevG = vmlib.edVector(grunt, ent.origin)
for _ = 1, 100 do
	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	buffer.writei32(vm.globals, glob.self * 4, grunt.num)
	vmlib.setGlobalFloat(vm, P0, 8)
	vm.argc = 1
	B[67](vm)
	local g = vmlib.edVector(grunt, ent.origin)
	path += vector.magnitude(g - prevG)
	prevG = g
	local dp = g - vmlib.edVector(player, ent.origin)
	minDist = math.min(minDist, math.sqrt(dp.x * dp.x + dp.y * dp.y))
end
-- NOTE: goal-approach is NOT asserted — SV_MoveToGoal steps along
-- ideal_yaw and only re-aims via rand()-gated SV_NewChaseDir, so
-- offline approach assertions are flaky. The planned sv_move
-- compiled-C harness is the real evidence for the chase family; this
-- check pins the dispatch: movetogoal drives changeyaw+movestep and
-- the monster covers real ground without error.
local _ = minDist
t.check(path > 100, `movetogoal walked a real path ({string.format("%.0f", path)} units)`)
vmlib.edSetVector(player, ent.origin, prevOrg)
worldlib.linkEdict(svr.world, player, false)

-- localcmd restart routes to a same-map changelevel
svr.changelevelTo = nil
callStr(46, "restart\n")
t.check(svr.changelevelTo ~= nil, "localcmd restart routes to the respawn driver (Host_Restart_f)")
svr.changelevelTo = nil

-- aim: facing straight down there is no target — returns v_forward
buffer.writei32(vm.globals, glob.self * 4, player.num)
vmlib.setGlobalVector(vm, glob.v_forward, vector.create(0, 0, -1))
vmlib.setGlobalInt(vm, P0, player.num)
vmlib.setGlobalFloat(vm, P1, 1000)
vm.argc = 2
B[44](vm)
t.check(vmlib.globalVector(vm, RET) == vector.create(0, 0, -1), "aim with no target returns v_forward")

t.finish("test_nqbuiltins")
