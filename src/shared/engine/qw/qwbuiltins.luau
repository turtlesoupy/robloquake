--!strict
--!optimize 2
-- QW progs builtins — QW/server/pr_cmds.c. Cloned from the verified NQ
-- builtin table with the QW differences applied: bprint/sprint take a
-- print LEVEL, and QW adds logfrag/infokey/stof/multicast. The entvars/
-- globals ABI is injected (qwdefs); the server object mirrors the NQ
-- field names this file touches.

local bsplib = require("../bsp/bsp")
local com = require("../common/com")
local cvarlib = require("../common/cvar")
local mathlib = require("../common/mathlib")
local msg = require("../common/msg")
local modelslib = require("../models/models")
local vmlib = require("../progs/vm")
local prdebug = require("../progs/prdebug")
local defs = require("../progs/defs") -- ev_* type constants only
local proto = require("../protocol")
local qd = require("../quakedef")
local world = require("./qwworld")
local sv_move = require("../server/sv_move")
local qwdefslib = require("./qwdefs")

local pr_cmds = {}

-- injected at setup time
local ent: { [string]: number } = {}
local glob: { [string]: number } = {}

local OFS_RETURN = defs.OFS_RETURN
local OFS_PARM0 = defs.OFS_PARM0
local OFS_PARM1 = OFS_PARM0 + 3
local OFS_PARM2 = OFS_PARM0 + 6
local OFS_PARM3 = OFS_PARM0 + 9
local OFS_PARM4 = OFS_PARM0 + 12

-- PF_VarString
local function varString(vm: vmlib.VM, first: number): string
	local parts = {}
	for i = first, vm.argc - 1 do
		table.insert(parts, vmlib.globalString(vm, OFS_PARM0 + i * 3))
	end
	return table.concat(parts)
end

local function returnEdict(vm: vmlib.VM, ed: vmlib.Edict)
	vmlib.setGlobalInt(vm, OFS_RETURN, ed.num)
end

-- C's "%5.1f" (right-justified, width 5, one decimal)
local function fmt51(v: number): string
	return string.format("%5.1f", v)
end

function pr_cmds.install(svr: any, qdefs: qwdefslib.QwDefs)
	ent = qdefs.ent
	glob = qdefs.glob
	local vm = svr.vm
	local g = vm.globals

	-- the shared static buffer for ftos/vtos results (pr_string_temp)
	local tempStringId = vmlib.allocString(vm, "")
	-- PF_infokey's own static buffer (C: `static char ov[256]`)
	local infokeyStringId = vmlib.allocString(vm, "")

	local B: { [number]: (vm: vmlib.VM) -> () } = {}
	local names: { [number]: string } = {}

	local function def(num: number, name: string, fn: (vm: vmlib.VM) -> ())
		B[num] = fn
		names[num] = name
	end

	-- world link hook for ED_Free
	vm.unlinkEdict = function(ed)
		world.unlinkEdict(ed)
	end

	--------------------------------------------------------------------
	def(1, "makevectors", function()
		local forward, right, up = mathlib.angleVectors(vmlib.globalVector(vm, OFS_PARM0))
		vmlib.setGlobalVector(vm, glob.v_forward, forward)
		vmlib.setGlobalVector(vm, glob.v_right, right)
		vmlib.setGlobalVector(vm, glob.v_up, up)
	end)

	def(2, "setorigin", function()
		local e = vmlib.globalEdict(vm, OFS_PARM0)
		vmlib.edSetVector(e, ent.origin, vmlib.globalVector(vm, OFS_PARM1))
		world.linkEdict(svr.world, e, false)
	end)

	-- SetMinMaxSize
	local function setMinMaxSize(e: vmlib.Edict, min: vector, max: vector)
		if min.x > max.x or min.y > max.y or min.z > max.z then
			error("backwards mins/maxs")
		end
		vmlib.edSetVector(e, ent.mins, min)
		vmlib.edSetVector(e, ent.maxs, max)
		vmlib.edSetVector(e, ent.size, max - min)
		world.linkEdict(svr.world, e, false)
	end

	def(3, "setmodel", function()
		local e = vmlib.globalEdict(vm, OFS_PARM0)
		local m = vmlib.globalString(vm, OFS_PARM1)

		-- check to see if model was properly precached
		local index: number? = nil
		for i, name in svr.model_precache do
			if name == m then
				index = i - 1
				break
			end
		end
		if not index then
			error(`no precache: {m}`)
		end

		vmlib.edSetInt(e, ent.model, vmlib.globalInt(vm, OFS_PARM1))
		vmlib.edSetFloat(e, ent.modelindex, index)

		-- QW only sizes/relinks INLINE brush models ('*'); alias and
		-- sprite models leave the bbox untouched (NQ set it from the
		-- model — QW deliberately removed that, mods setsize after)
		if m:sub(1, 1) == "*" then
			local mod = svr.models[index + 1]
			if mod then
				setMinMaxSize(e, mod.mins, mod.maxs)
			end
		end
	end)

	def(4, "setsize", function()
		local e = vmlib.globalEdict(vm, OFS_PARM0)
		setMinMaxSize(e, vmlib.globalVector(vm, OFS_PARM1), vmlib.globalVector(vm, OFS_PARM2))
	end)

	def(6, "break", function()
		error("break statement")
	end)

	def(7, "random", function()
		local num = bit32.band(svr.rand(svr), 0x7fff) / 0x7fff
		vmlib.setGlobalFloat(vm, OFS_RETURN, num)
	end)

	def(8, "sound", function()
		local entity = vmlib.globalEdict(vm, OFS_PARM0)
		local channel = vmlib.globalFloat(vm, OFS_PARM1)
		local sample = vmlib.globalString(vm, OFS_PARM2)
		local volume = vmlib.globalFloat(vm, OFS_PARM3) * 255
		local attenuation = vmlib.globalFloat(vm, OFS_PARM4)
		svr.startSound(svr, entity, channel, sample, volume, attenuation)
	end)

	def(9, "normalize", function()
		local v = vmlib.globalVector(vm, OFS_PARM0)
		local n = mathlib.normalize(v)
		vmlib.setGlobalVector(vm, OFS_RETURN, n)
	end)

	def(10, "error", function()
		local s = varString(vm, 0)
		local fname = vm.progs.functions[vm.xfunction + 1].name
		error(`======SERVER ERROR in {fname}:\n{s}`)
	end)

	def(11, "objerror", function()
		local s = varString(vm, 0)
		local fname = vm.progs.functions[vm.xfunction + 1].name
		local ed = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
		svr.print(`======OBJECT ERROR in {fname}:\n{s}`)
		vmlib.free(vm, ed)
		error(`objerror in {fname}: {s}`)
	end)

	def(12, "vlen", function()
		vmlib.setGlobalFloat(vm, OFS_RETURN, vector.magnitude(vmlib.globalVector(vm, OFS_PARM0)))
	end)

	def(13, "vectoyaw", function()
		local v = vmlib.globalVector(vm, OFS_PARM0)
		local yaw
		if v.y == 0 and v.x == 0 then
			yaw = 0
		else
			yaw = mathlib.trunc(math.atan2(v.y, v.x) * 180 / math.pi)
			if yaw < 0 then
				yaw += 360
			end
		end
		vmlib.setGlobalFloat(vm, OFS_RETURN, yaw)
	end)

	def(14, "spawn", function()
		returnEdict(vm, vmlib.alloc(vm))
	end)

	def(15, "remove", function()
		vmlib.free(vm, vmlib.globalEdict(vm, OFS_PARM0))
	end)

	local function setTraceGlobals(trace: world.Trace)
		vmlib.setGlobalFloat(vm, glob.trace_allsolid, if trace.allsolid then 1 else 0)
		vmlib.setGlobalFloat(vm, glob.trace_startsolid, if trace.startsolid then 1 else 0)
		vmlib.setGlobalFloat(vm, glob.trace_fraction, trace.fraction)
		vmlib.setGlobalFloat(vm, glob.trace_inwater, if trace.inwater then 1 else 0)
		vmlib.setGlobalFloat(vm, glob.trace_inopen, if trace.inopen then 1 else 0)
		vmlib.setGlobalVector(vm, glob.trace_endpos, trace.endpos)
		vmlib.setGlobalVector(vm, glob.trace_plane_normal, trace.planeNormal)
		vmlib.setGlobalFloat(vm, glob.trace_plane_dist, trace.planeDist)
		local traceEnt = trace.ent
		vmlib.setGlobalInt(vm, glob.trace_ent, if traceEnt then traceEnt.num else 0)
	end

	def(16, "traceline", function()
		local v1 = vmlib.globalVector(vm, OFS_PARM0)
		local v2 = vmlib.globalVector(vm, OFS_PARM1)
		local nomonsters = vmlib.globalFloat(vm, OFS_PARM2)
		local passEd = vmlib.globalEdict(vm, OFS_PARM3)
		local trace = world.move(svr.world, v1, vector.zero, vector.zero, v2, nomonsters, passEd)
		setTraceGlobals(trace)
	end)

	-- PF_newcheckclient / PF_checkclient
	local function newCheckClient(check: number): number
		-- cycle to the next one
		check = math.clamp(check, 1, svr.maxclients)
		local i = if check == svr.maxclients then 1 else check + 1

		local edict
		while true do
			if i == svr.maxclients + 1 then
				i = 1
			end
			edict = vmlib.edictNum(vm, i)
			if i == check then
				break -- didn't find anything else
			end
			if
				not edict.free
				and vmlib.edFloat(edict, ent.health) > 0
				and bit32.band(vmlib.edFloat(edict, ent.flags), qd.FL_NOTARGET) == 0
			then
				break -- anything that is a client, or has a client as an enemy
			end
			i += 1
		end

		-- get the PVS for the entity
		local org = vmlib.edVector(edict, ent.origin) + vmlib.edVector(edict, ent.view_ofs)
		local leaf = bsplib.pointInLeaf(org, svr.worldmodel)
		svr.checkpvs = bsplib.leafPVS(leaf, svr.worldmodel)
		return i
	end

	def(17, "checkclient", function()
		-- find a new check if on a new frame
		if svr.time - svr.lastchecktime >= 0.1 then
			svr.lastcheck = newCheckClient(svr.lastcheck)
			svr.lastchecktime = svr.time
		end

		-- return check if it might be visible
		local edict = vmlib.edictNum(vm, svr.lastcheck)
		if edict.free or vmlib.edFloat(edict, ent.health) <= 0 then
			returnEdict(vm, vmlib.edictNum(vm, 0))
			return
		end

		-- if current entity can't possibly see the check entity, return 0
		local self_ = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
		local view = vmlib.edVector(self_, ent.origin) + vmlib.edVector(self_, ent.view_ofs)
		local leaf = bsplib.pointInLeaf(view, svr.worldmodel)
		local l = leaf.num - 1
		local checkpvs = svr.checkpvs
		if
			l < 0
			or not checkpvs
			or bit32.band(buffer.readu8(checkpvs, bit32.rshift(l, 3)), bit32.lshift(1, bit32.band(l, 7))) == 0
		then
			returnEdict(vm, vmlib.edictNum(vm, 0))
			return
		end

		-- might be able to see it
		returnEdict(vm, edict)
	end)

	def(18, "find", function()
		local e = vmlib.globalInt(vm, OFS_PARM0)
		local f = vmlib.globalInt(vm, OFS_PARM1)
		local s = vmlib.globalString(vm, OFS_PARM2)

		for i = e + 1, vm.num_edicts - 1 do
			local edict = vm.edicts[i + 1]
			if edict.free then
				continue
			end
			local t = vmlib.edString(vm, edict, f)
			if t == s then
				returnEdict(vm, edict)
				return
			end
		end

		returnEdict(vm, vmlib.edictNum(vm, 0))
	end)

	local function checkEmptyString(s: string)
		if s == "" or s:byte(1) <= 32 then
			error("Bad string")
		end
	end

	def(19, "precache_sound", function()
		if svr.state ~= 1 then
			error("PF_Precache_*: Precache can only be done in spawn functions")
		end
		local s = vmlib.globalString(vm, OFS_PARM0)
		vmlib.setGlobalInt(vm, OFS_RETURN, vmlib.globalInt(vm, OFS_PARM0))
		checkEmptyString(s)

		for i = 2, #svr.sound_precache do
			if svr.sound_precache[i] == s then
				return
			end
		end
		if #svr.sound_precache >= qd.MAX_SOUNDS then
			error("PF_precache_sound: overflow")
		end
		table.insert(svr.sound_precache, s)
	end)

	def(20, "precache_model", function()
		if svr.state ~= 1 then
			error("PF_Precache_*: Precache can only be done in spawn functions")
		end
		local s = vmlib.globalString(vm, OFS_PARM0)
		vmlib.setGlobalInt(vm, OFS_RETURN, vmlib.globalInt(vm, OFS_PARM0))
		checkEmptyString(s)

		for i = 2, #svr.model_precache do
			if svr.model_precache[i] == s then
				return
			end
		end
		if #svr.model_precache >= qd.MAX_MODELS then
			error("PF_precache_model: overflow")
		end
		table.insert(svr.model_precache, s)
		local model = modelslib.forName(svr.reg, s, true)
		svr.models[#svr.model_precache] = model
		if model and model.kind == "brush" then
			svr.brushModels[#svr.model_precache - 1] = model.brush :: any
		end
	end)

	def(21, "stuffcmd", function()
		local entnum = vmlib.globalInt(vm, OFS_PARM0)
		if entnum < 1 or entnum > svr.maxclients then
			error("Parm 0 not a client")
		end
		local str = vmlib.globalString(vm, OFS_PARM1)
		local client = svr.clients[entnum]
		if str == "disconnect\n" then
			-- C: don't send the stufftext — drop the client server-side
			client.drop = true
			return
		end
		svr.clientCommands(svr, client, str)
	end)

	def(22, "findradius", function()
		local chain = vmlib.edictNum(vm, 0)
		local org = vmlib.globalVector(vm, OFS_PARM0)
		local rad = vmlib.globalFloat(vm, OFS_PARM1)

		for i = 1, vm.num_edicts - 1 do
			local edict = vm.edicts[i + 1]
			if edict.free then
				continue
			end
			if vmlib.edFloat(edict, ent.solid) == qd.SOLID_NOT then
				continue
			end
			local eorg = org
				- (vmlib.edVector(edict, ent.origin) + (vmlib.edVector(edict, ent.mins) + vmlib.edVector(edict, ent.maxs)) * 0.5)
			if vector.magnitude(eorg) > rad then
				continue
			end
			vmlib.edSetInt(edict, ent.chain, chain.num)
			chain = edict
		end

		returnEdict(vm, chain)
	end)

	def(23, "bprint", function()
		-- QW: void(float level, string s) bprint
		local level = vmlib.globalFloat(vm, OFS_PARM0)
		svr.broadcastPrint(svr, level, varString(vm, 1))
	end)

	def(24, "sprint", function()
		-- QW: void(entity client, float level, string s) sprint
		local entnum = vmlib.globalEdict(vm, OFS_PARM0).num
		local level = vmlib.globalFloat(vm, OFS_PARM1)
		local text = varString(vm, 2)
		if entnum < 1 or entnum > svr.maxclients then
			svr.print("tried to sprint to a non-client")
			return
		end
		svr.clientPrint(svr, svr.clients[entnum], level, text)
	end)

	def(25, "dprint", function()
		svr.dprint(varString(vm, 0))
	end)

	def(26, "ftos", function()
		local v = vmlib.globalFloat(vm, OFS_PARM0)
		local s
		if v == mathlib.trunc(v) then
			-- C: sprintf("%d", (int)v); out-of-int32 values saturate to
			-- INT_MIN on x86 (cvttsd2si) instead of crashing the frame
			if not (v >= -2147483648 and v <= 2147483647) then
				v = -2147483648
			end
			s = string.format("%d", v)
		else
			s = fmt51(v)
		end
		vmlib.setDynString(vm, tempStringId, s)
		vmlib.setGlobalInt(vm, OFS_RETURN, tempStringId)
	end)

	def(27, "vtos", function()
		local v = vmlib.globalVector(vm, OFS_PARM0)
		vmlib.setDynString(vm, tempStringId, `'{fmt51(v.x)} {fmt51(v.y)} {fmt51(v.z)}'`)
		vmlib.setGlobalInt(vm, OFS_RETURN, tempStringId)
	end)

	def(28, "coredump", function()
		-- PF_coredump = ED_PrintEdicts
		svr.print(prdebug.edPrintEdicts(vm))
	end)
	def(29, "traceon", function()
		-- statements print until DONE (prdebug's PR_PrintStatement)
		prdebug.installTracer(vm)
		vm.trace = true
	end)
	def(30, "traceoff", function()
		vm.trace = false
	end)
	def(31, "eprint", function()
		-- PF_eprint = ED_PrintNum(G_EDICTNUM(OFS_PARM0))
		svr.print(prdebug.edPrintNum(vm, vmlib.globalInt(vm, OFS_PARM0)))
	end)

	def(32, "walkmove", function()
		local edict = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
		local yaw = vmlib.globalFloat(vm, OFS_PARM0)
		local dist = vmlib.globalFloat(vm, OFS_PARM1)

		if bit32.band(vmlib.edFloat(edict, ent.flags), qd.FL_ONGROUND + qd.FL_FLY + qd.FL_SWIM) == 0 then
			vmlib.setGlobalFloat(vm, OFS_RETURN, 0)
			return
		end

		local rad = yaw * math.pi * 2 / 360
		local move = vector.create(math.cos(rad) * dist, math.sin(rad) * dist, 0)

		-- save program state, because SV_movestep may call other progs
		local oldf = vm.xfunction
		local oldself = vmlib.globalInt(vm, glob.self)

		vmlib.setGlobalFloat(vm, OFS_RETURN, if sv_move.movestep(svr, edict, move, true) then 1 else 0)

		-- restore program state
		vm.xfunction = oldf
		buffer.writei32(g, glob.self * 4, oldself)
	end)

	def(34, "droptofloor", function()
		local edict = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
		local origin = vmlib.edVector(edict, ent.origin)
		local endp = vector.create(origin.x, origin.y, origin.z - 256)

		local trace = world.move(
			svr.world,
			origin,
			vmlib.edVector(edict, ent.mins),
			vmlib.edVector(edict, ent.maxs),
			endp,
			qd.MOVE_NORMAL,
			edict
		)

		if trace.fraction == 1 or trace.allsolid then
			vmlib.setGlobalFloat(vm, OFS_RETURN, 0)
		else
			vmlib.edSetVector(edict, ent.origin, trace.endpos)
			world.linkEdict(svr.world, edict, false)
			vmlib.edSetFloat(edict, ent.flags, bit32.bor(vmlib.edFloat(edict, ent.flags), qd.FL_ONGROUND))
			vmlib.edSetInt(edict, ent.groundentity, if trace.ent then (trace.ent :: vmlib.Edict).num else 0)
			vmlib.setGlobalFloat(vm, OFS_RETURN, 1)
		end
	end)

	def(35, "lightstyle", function()
		local style = vmlib.globalFloat(vm, OFS_PARM0)
		local val = vmlib.globalString(vm, OFS_PARM1)

		-- change the string in sv
		svr.lightstyles[style] = val

		-- send message to all clients on this server (ss_active == 2)
		if svr.state ~= 2 then
			return
		end
		for _, client in svr.clients do
			if client.active or client.spawned then
				msg.writeByte(client.netchan.message, proto.svc_lightstyle)
				msg.writeByte(client.netchan.message, style)
				msg.writeString(client.netchan.message, val)
			end
		end
	end)

	def(36, "rint", function()
		local f = vmlib.globalFloat(vm, OFS_PARM0)
		local r = if f > 0 then mathlib.trunc(f + 0.5) else mathlib.trunc(f - 0.5)
		vmlib.setGlobalFloat(vm, OFS_RETURN, r)
	end)
	def(37, "floor", function()
		vmlib.setGlobalFloat(vm, OFS_RETURN, math.floor(vmlib.globalFloat(vm, OFS_PARM0)))
	end)
	def(38, "ceil", function()
		vmlib.setGlobalFloat(vm, OFS_RETURN, math.ceil(vmlib.globalFloat(vm, OFS_PARM0)))
	end)

	def(40, "checkbottom", function()
		local edict = vmlib.globalEdict(vm, OFS_PARM0)
		vmlib.setGlobalFloat(vm, OFS_RETURN, if sv_move.checkBottom(svr, edict) then 1 else 0)
	end)

	def(41, "pointcontents", function()
		local v = vmlib.globalVector(vm, OFS_PARM0)
		vmlib.setGlobalFloat(vm, OFS_RETURN, world.pointContents(svr.world, v))
	end)

	def(43, "fabs", function()
		vmlib.setGlobalFloat(vm, OFS_RETURN, math.abs(vmlib.globalFloat(vm, OFS_PARM0)))
	end)

	def(44, "aim", function()
		local edict = vmlib.globalEdict(vm, OFS_PARM0)
		-- speed parm unused in the id code path

		local start = vmlib.edVector(edict, ent.origin) + vector.create(0, 0, 20)

		-- try sending a trace straight
		local v_forward = vmlib.globalVector(vm, glob.v_forward)
		local endp = start + v_forward * 2048
		local tr = world.move(svr.world, start, vector.zero, vector.zero, endp, qd.MOVE_NORMAL, edict)
		local teamplay = cvarlib.value(svr.cvars, "teamplay")
		local trEnt = tr.ent
		if trEnt then
			local myTeam = vmlib.edFloat(edict, ent.team)
			if
				vmlib.edFloat(trEnt, ent.takedamage) == qd.DAMAGE_AIM
				and (teamplay == 0 or myTeam <= 0 or myTeam ~= vmlib.edFloat(trEnt, ent.team))
			then
				vmlib.setGlobalVector(vm, OFS_RETURN, v_forward)
				return
			end
		end

		-- try all possible entities
		local bestdir = v_forward
		local bestdist = cvarlib.value(svr.cvars, "sv_aim")
		local bestent: vmlib.Edict? = nil

		for i = 1, vm.num_edicts - 1 do
			local check = vm.edicts[i + 1]
			if vmlib.edFloat(check, ent.takedamage) ~= qd.DAMAGE_AIM then
				continue
			end
			if check == edict then
				continue
			end
			local myTeam = vmlib.edFloat(edict, ent.team)
			if teamplay ~= 0 and myTeam > 0 and myTeam == vmlib.edFloat(check, ent.team) then
				continue -- don't aim at teammate
			end
			local target = vmlib.edVector(check, ent.origin)
				+ (vmlib.edVector(check, ent.mins) + vmlib.edVector(check, ent.maxs)) * 0.5
			local dir = mathlib.normalize(target - start)
			local dist = vector.dot(dir, v_forward)
			if dist < bestdist then
				continue -- too far to turn
			end
			tr = world.move(svr.world, start, vector.zero, vector.zero, target, qd.MOVE_NORMAL, edict)
			if tr.ent == check then
				-- can shoot at this one
				bestdist = dist
				bestent = check
			end
		end

		if bestent then
			local dir = vmlib.edVector(bestent, ent.origin) - vmlib.edVector(edict, ent.origin)
			local dist = vector.dot(dir, v_forward)
			local endv = v_forward * dist
			endv = vector.create(endv.x, endv.y, dir.z)
			endv = mathlib.normalize(endv)
			vmlib.setGlobalVector(vm, OFS_RETURN, endv)
		else
			vmlib.setGlobalVector(vm, OFS_RETURN, bestdir)
		end
	end)

	def(45, "cvar", function()
		local str = vmlib.globalString(vm, OFS_PARM0)
		vmlib.setGlobalFloat(vm, OFS_RETURN, cvarlib.value(svr.cvars, str))
	end)

	def(46, "localcmd", function()
		local str = vmlib.globalString(vm, OFS_PARM0)
		-- the only localcmds issued by id1 QC are "restart", "changelevel*"
		-- and cd track / teamplay tweaks; route level changes, log the rest
		local level = str:match("^changelevel (%S+)")
		if level then
			svr.changelevelTo = level
		elseif str:match("^restart") then
			svr.changelevelTo = svr.name
		else
			svr.dprint(`localcmd: {str}`)
		end
	end)

	def(47, "nextent", function()
		local i = vmlib.globalInt(vm, OFS_PARM0)
		while true do
			i += 1
			if i == vm.num_edicts then
				returnEdict(vm, vmlib.edictNum(vm, 0))
				return
			end
			local edict = vmlib.edictNum(vm, i)
			if not edict.free then
				returnEdict(vm, edict)
				return
			end
		end
	end)

	def(48, "particle", function()
		local org = vmlib.globalVector(vm, OFS_PARM0)
		local dir = vmlib.globalVector(vm, OFS_PARM1)
		local color = vmlib.globalFloat(vm, OFS_PARM2)
		local count = vmlib.globalFloat(vm, OFS_PARM3)
		svr.startParticle(svr, org, dir, color, count)
	end)

	def(49, "changeyaw", function()
		sv_move.changeYaw(svr)
	end)

	def(51, "vectoangles", function()
		local v = vmlib.globalVector(vm, OFS_PARM0)
		local yaw, pitch
		if v.y == 0 and v.x == 0 then
			yaw = 0
			pitch = if v.z > 0 then 90 else 270
		else
			yaw = mathlib.trunc(math.atan2(v.y, v.x) * 180 / math.pi)
			if yaw < 0 then
				yaw += 360
			end
			local forward = math.sqrt(v.x * v.x + v.y * v.y)
			pitch = mathlib.trunc(math.atan2(v.z, forward) * 180 / math.pi)
			if pitch < 0 then
				pitch += 360
			end
		end
		vmlib.setGlobalVector(vm, OFS_RETURN, vector.create(pitch, yaw, 0))
	end)

	-- message writing
	local MSG_BROADCAST = 0
	local MSG_ONE = 1
	local MSG_ALL = 2
	local MSG_INIT = 3
	local MSG_MULTICAST = 4 -- QW

	local function writeDest(): msg.SizeBuf
		local dest = vmlib.globalFloat(vm, OFS_PARM0)
		if dest == MSG_BROADCAST then
			return svr.datagram
		elseif dest == MSG_ONE then
			-- ClientReliableWrite: straight onto the client's reliable
			-- netchan stream (centerprint, sellscreen, etc.)
			local entnum = vmlib.globalInt(vm, glob.msg_entity)
			if entnum < 1 or entnum > svr.maxclients then
				error("WriteDest: not a client")
			end
			return svr.clients[entnum].netchan.message
		elseif dest == MSG_ALL then
			return svr.reliable_datagram
		elseif dest == MSG_INIT then
			return svr.signon
		elseif dest == MSG_MULTICAST then
			return svr.multicast
		end
		error("WriteDest: bad destination")
	end

	def(52, "WriteByte", function()
		msg.writeByte(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(53, "WriteChar", function()
		msg.writeChar(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(54, "WriteShort", function()
		msg.writeShort(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(55, "WriteLong", function()
		msg.writeLong(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(56, "WriteCoord", function()
		msg.writeCoord(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(57, "WriteAngle", function()
		msg.writeAngle(writeDest(), vmlib.globalFloat(vm, OFS_PARM1))
	end)
	def(58, "WriteString", function()
		msg.writeString(writeDest(), vmlib.globalString(vm, OFS_PARM1))
	end)
	def(59, "WriteEntity", function()
		msg.writeShort(writeDest(), vmlib.globalInt(vm, OFS_PARM1))
	end)

	def(67, "movetogoal", function()
		sv_move.moveToGoal(svr)
	end)

	def(68, "precache_file", function()
		-- precache_file just copies files with qcc, it does nothing
		vmlib.setGlobalInt(vm, OFS_RETURN, vmlib.globalInt(vm, OFS_PARM0))
	end)

	def(69, "makestatic", function()
		local edict = vmlib.globalEdict(vm, OFS_PARM0)
		svr.checkSignonSpace(svr)
		local sg = svr.signon

		msg.writeByte(sg, proto.svc_spawnstatic)
		msg.writeByte(sg, svr.modelIndex(svr, vmlib.edString(vm, edict, ent.model)))
		msg.writeByte(sg, vmlib.edFloat(edict, ent.frame))
		msg.writeByte(sg, vmlib.edFloat(edict, ent.colormap))
		msg.writeByte(sg, vmlib.edFloat(edict, ent.skin))
		local origin = vmlib.edVector(edict, ent.origin)
		local angles = vmlib.edVector(edict, ent.angles)
		msg.writeCoord(sg, origin.x)
		msg.writeAngle(sg, angles.x)
		msg.writeCoord(sg, origin.y)
		msg.writeAngle(sg, angles.y)
		msg.writeCoord(sg, origin.z)
		msg.writeAngle(sg, angles.z)

		-- throw the entity away now
		vmlib.free(vm, edict)
	end)

	def(70, "changelevel", function()
		-- make sure we don't issue two changelevels
		if svr.changelevelIssued then
			return
		end
		svr.changelevelIssued = true
		svr.changelevelTo = vmlib.globalString(vm, OFS_PARM0)
	end)

	def(72, "cvar_set", function()
		cvarlib.set(svr.cvars, vmlib.globalString(vm, OFS_PARM0), vmlib.globalString(vm, OFS_PARM1))
	end)

	def(73, "centerprint", function()
		local entnum = vmlib.globalInt(vm, OFS_PARM0)
		local s = varString(vm, 1)
		if entnum < 1 or entnum > svr.maxclients then
			svr.print("tried to sprint to a non-client")
			return
		end
		-- ClientReliableWrite: onto the client's netchan reliable stream
		-- (client.message is a dead buffer nothing flushes)
		local client = svr.clients[entnum]
		msg.writeByte(client.netchan.message, proto.svc_centerprint)
		msg.writeString(client.netchan.message, s)
	end)

	def(74, "ambientsound", function()
		local pos = vmlib.globalVector(vm, OFS_PARM0)
		local samp = vmlib.globalString(vm, OFS_PARM1)
		local vol = vmlib.globalFloat(vm, OFS_PARM2)
		local attenuation = vmlib.globalFloat(vm, OFS_PARM3)

		-- check to see if samp was properly precached
		local soundnum = svr.soundIndex(svr, samp)
		if not soundnum then
			svr.print(`no precache: {samp}`)
			return
		end

		-- add an svc_spawnambient command to the level signon packet
		svr.checkSignonSpace(svr)
		local sg = svr.signon
		msg.writeByte(sg, proto.svc_spawnstaticsound)
		msg.writeCoord(sg, pos.x)
		msg.writeCoord(sg, pos.y)
		msg.writeCoord(sg, pos.z)
		msg.writeByte(sg, soundnum)
		msg.writeByte(sg, vol * 255)
		msg.writeByte(sg, attenuation * 64)
	end)

	B[75] = B[20] -- precache_model2
	names[75] = "precache_model2"
	B[76] = B[19] -- precache_sound2
	names[76] = "precache_sound2"
	B[77] = B[68] -- precache_file2
	names[77] = "precache_file2"

	def(78, "setspawnparms", function()
		local edict = vmlib.globalEdict(vm, OFS_PARM0)
		local i = edict.num
		if i < 1 or i > svr.maxclients then
			error("Entity is not a client")
		end
		-- copy spawn parms out of the client_t
		local client = svr.clients[i]
		for j = 0, proto.NUM_SPAWN_PARMS - 1 do
			vmlib.setGlobalFloat(vm, glob.parm1 + j, client.spawn_parms[j + 1])
		end
	end)

	-- QW additions
	def(79, "logfrag", function()
		local e1 = vmlib.globalEdict(vm, OFS_PARM0).num
		local e2 = vmlib.globalEdict(vm, OFS_PARM1).num
		if svr.logfrag then
			svr.logfrag(svr, e1, e2)
		end
	end)

	def(80, "infokey", function()
		local e = vmlib.globalEdict(vm, OFS_PARM0)
		local key = vmlib.globalString(vm, OFS_PARM1)
		local value = ""
		if e.num == 0 then
			-- C: serverinfo first, then the server operator's localinfo
			-- (mods like Rocket Arena keep their map rotation there)
			value = (svr.serverinfo and svr.serverinfo[key]) or ""
			if value == "" then
				value = (svr.localinfo and svr.localinfo[key]) or ""
			end
		elseif e.num >= 1 and e.num <= svr.maxclients then
			local cl = svr.clients[e.num]
			if key == "ip" then
				-- platform analog of the C remote address: the stable
				-- transport identity (Roblox UserId), set at connect
				value = tostring((cl and (cl :: any).address) or "")
			elseif key == "ping" then
				value = tostring(svr.calcPing and svr.calcPing(svr, cl) or 0)
			else
				value = (cl and cl.userinfo and cl.userinfo[key]) or ""
			end
		end
		-- C uses a static ov[256], NOT a fresh zoned string: reuse one
		-- dynstring slot so per-frame infokey polls don't leak memory
		vmlib.setDynString(vm, infokeyStringId, value)
		vmlib.setGlobalInt(vm, OFS_RETURN, infokeyStringId)
	end)

	def(81, "stof", function()
		-- C PF_stof is libc atof (no hex), not Q_atof
		vmlib.setGlobalFloat(vm, OFS_RETURN, com.atofC(vmlib.globalString(vm, OFS_PARM0)))
	end)

	def(82, "multicast", function()
		local org = vmlib.globalVector(vm, OFS_PARM0)
		local to = vmlib.globalFloat(vm, OFS_PARM1)
		svr.svMulticast(svr, org, to)
	end)

	vm.builtins = B
	vm.builtinNames = names
end

return pr_cmds
