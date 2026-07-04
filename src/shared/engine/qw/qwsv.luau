--!strict
-- QuakeWorld server core — sv_init.c/sv_main.c/sv_user.c essentials:
-- spawn qwprogs on a map, client lifecycle, SV_RunCmd through the
-- M1-verified pmove, SV_Physics for non-clients via qwphys. Networking
-- (netchan + delta entities) is the next layer; this one is offline-
-- verifiable game simulation.

local bsp = require("../bsp/bsp")
local cvarlib = require("../common/cvar")
local mathlib = require("../common/mathlib")
local msg = require("../common/msg")
local vfslib = require("../common/vfs")
local modelslib = require("../models/models")
local qwents = require("./qwents")
local qwp = require("./qwprotocol")
local progslib = require("../progs/progs")
local defs = require("../progs/defs")
local vmlib = require("../progs/vm")
local qd = require("../quakedef")
local qwdefslib = require("./qwdefs")
local qwbuiltins = require("./qwbuiltins")
local qwphys = require("./qwphys")
local qwworld = require("./qwworld")
local pmovelib = require("./pmove")

local qwsv = {}

local MAX_CLIENTS = 32

export type Client = {
	active: boolean,
	spawned: boolean,
	spectator: boolean,
	num: number,
	name: string,
	userinfo: { [string]: string },
	edict: vmlib.Edict,
	spawn_parms: { number },
	oldbuttons: number,
	entgravity: number,
	maxspeed: number,
	message: msg.SizeBuf,
	datagram: msg.SizeBuf,
	prints: { string }, -- collected clientPrint output (transport later)

	-- netchan-lite + delta compression state
	netchan: { incoming_sequence: number, outgoing_sequence: number, incoming_acknowledged: number },
	frames: { [number]: ClientFrame }, -- ring keyed by seq & UPDATE_MASK
	delta_sequence: number, -- -1 = no delta unless requested (per message)
	lastcmd: qwents.UserCmdWire,
	localtime: number, -- sv.time when the last cmd batch ran
	spec_track: number, -- 1-based player a spectator is tracking, 0 = none
}

export type ClientFrame = {
	entities: { qwents.EntityState },
	senttime: number,
}

function qwsv.newGame(fsys: vfslib.Vfs, qwprogsBuf: buffer): any
	local svr: any = {}
	svr.fs = fsys
	svr.qwprogsBuf = qwprogsBuf
	svr.maxclients = MAX_CLIENTS
	svr.cvars = cvarlib.new()
	local cv = svr.cvars
	-- QW server cvar defaults
	for name, v in
		{
			deathmatch = 1, -- QW is deathmatch-only
			teamplay = 0,
			timelimit = 0,
			fraglimit = 0,
			samelevel = 0,
			coop = 0,
			skill = 1,
			sv_gravity = 800,
			sv_stopspeed = 100,
			sv_maxspeed = 320,
			sv_spectatormaxspeed = 500,
			sv_accelerate = 10,
			sv_airaccelerate = 10,
			sv_wateraccelerate = 10,
			sv_friction = 4,
			sv_waterfriction = 4,
			sv_aim = 2,
			pausable = 1,
			registered = 1,
		} :: { [string]: number }
	do
		-- register QW cvars directly (cvar.new seeds only the NQ defaults)
		cv.vars[name] = { string = tostring(v), value = v }
	end

	svr.clients = {}
	for i = 1, MAX_CLIENTS do
		svr.clients[i] = {
			active = false,
			spawned = false,
			spectator = false,
			num = i,
			name = "",
			userinfo = {},
			edict = nil :: any,
			spawn_parms = table.create(16, 0),
			oldbuttons = 0,
			entgravity = 1,
			maxspeed = 320,
			message = msg.newBuf(8000),
			datagram = msg.newBuf(2048),
			prints = {},
			netchan = { incoming_sequence = 0, outgoing_sequence = 0, incoming_acknowledged = 0 },
			frames = {},
			delta_sequence = -1,
			lastcmd = qwents.nullCmd(),
			localtime = 0,
			spec_track = 0,
		}
	end

	svr.serverflags = 0
	svr.serverinfo = { ["*version"] = "2.40", maxclients = tostring(MAX_CLIENTS), deathmatch = "1" }
	svr.datagram = msg.newBuf(4096)
	svr.reliable_datagram = msg.newBuf(4096)
	svr.signon = msg.newBuf(32768)
	svr.multicast = msg.newBuf(2048)
	svr.print = function(s: string)
		print("[qwsv] " .. s)
	end
	svr.dprint = function(_s: string) end
	svr.active = false

	-- hooks used by qwbuiltins/qwphys (transport wires in later layers)
	svr.soundLog = {}
	svr.startSound = function(_svr: any, ed: vmlib.Edict, channel: number, sample: string, volume: number, attenuation: number)
		table.insert(svr.soundLog, { ent = ed.num, channel = channel, sample = sample, volume = volume, attenuation = attenuation })
	end
	svr.printLog = {}
	svr.broadcastPrint = function(_svr: any, level: number, text: string)
		table.insert(svr.printLog, { level = level, text = text })
	end
	svr.clientPrint = function(_svr: any, client: Client, level: number, text: string)
		table.insert(client.prints, text)
	end
	svr.flushMulticast = function(_svr: any, _reliable: boolean)
		-- netchan layer routes this per-client later; content is correct
		msg.clear(svr.multicast)
	end
	svr.logfrag = function(_svr: any, _killer: number, _killee: number) end
	svr.soundIndex = function(_svr: any, sample: string): number?
		for i, name in svr.sound_precache do
			if name == sample then
				return i - 1
			end
		end
		return nil
	end
	svr.modelIndex = function(_svr: any, name: string): number?
		for i, n in svr.model_precache do
			if n == name then
				return i - 1
			end
		end
		return nil
	end
	svr.startParticle = function(_svr: any, org: vector, dir: vector, color: number, count: number)
		table.insert(svr.soundLog, { particle = true, org = org, color = color, count = count })
	end
	svr.clientCommands = function(_svr: any, client: Client, text: string)
		-- stuffcmd: queued for the wire layer
		table.insert(client.prints, "[stuff] " .. text)
	end
	-- QW rand: deterministic LCG shared with the NQ server port
	local rngState = 12345
	svr.rand = function(_svr: any): number
		rngState = (rngState * 214013 + 2531011) % 4294967296
		return bit32.band(bit32.rshift(rngState, 16), 0x7fff)
	end
	return svr
end

-- SV_SpawnServer: QW reloads the progs on every level
function qwsv.spawnServer(svr: any, mapname: string)
	svr.dprint(`SpawnServer: {mapname}`)
	svr.changelevelTo = nil
	svr.changelevelIssued = false

	svr.name = mapname
	svr.modelname = `maps/{mapname}.bsp`
	svr.paused = false
	svr.time = 1.0
	svr.lastcheck = 1
	svr.lastchecktime = 0
	svr.models = {}
	svr.model_precache = {}
	svr.sound_precache = {}
	svr.brushModels = {}
	svr.lightstyles = {}
	msg.clear(svr.datagram)
	msg.clear(svr.reliable_datagram)
	msg.clear(svr.signon)
	msg.clear(svr.multicast)

	svr.progs = progslib.load(svr.qwprogsBuf, defs.PROGHEADER_CRC_QW)
	svr.qdefs = qwdefslib.build(svr.progs)
	local qdefs = svr.qdefs
	local ent = qdefs.ent
	local glob = qdefs.glob

	local vm = vmlib.new(svr.progs, qd.MAX_EDICTS, svr.maxclients)
	svr.vm = vm
	vm.print = svr.print
	vm.time = svr.time
	-- OP_STATE must write through the QW ABI
	vm.stateOffsets = {
		globSelf = glob.self,
		globTime = glob.time,
		nextthink = ent.nextthink,
		frame = ent.frame,
		think = ent.think,
	}

	vmlib.initEdicts(vm, svr.maxclients + 1)
	for i = 1, svr.maxclients do
		svr.clients[i].edict = vmlib.edictNum(vm, i)
	end

	svr.state = 1 -- ss_loading

	svr.reg = modelslib.newRegistry(svr.fs)
	local worldmod = modelslib.forName(svr.reg, svr.modelname, false)
	if not worldmod or worldmod.kind ~= "brush" then
		svr.print(`Couldn't spawn server {svr.modelname}`)
		svr.active = false
		return
	end
	svr.worldmodel = worldmod.brush :: any

	svr.world = qwworld.new(vm, svr.worldmodel, svr.brushModels, qdefs)

	svr.sound_precache[1] = ""
	svr.model_precache[1] = ""
	svr.model_precache[2] = svr.modelname
	svr.models[2] = worldmod
	svr.brushModels[1] = svr.worldmodel
	local numsubmodels = #svr.worldmodel.brush.submodels
	for i = 1, numsubmodels - 1 do
		local name = `*{i}`
		svr.model_precache[2 + i] = name
		local m = modelslib.forName(svr.reg, name, true)
		svr.models[2 + i] = m
		if m and m.kind == "brush" then
			svr.brushModels[i + 1] = m.brush :: any
		end
	end

	qwbuiltins.install(svr, qdefs)
	qwphys.useDefs(qdefs)

	-- worldspawn edict
	local worldEd = vmlib.edictNum(vm, 0)
	buffer.fill(worldEd.fields, 0, 0, svr.progs.entityfields * 4)
	worldEd.free = false
	vmlib.edSetInt(worldEd, ent.model, vmlib.allocString(vm, svr.modelname))
	vmlib.edSetFloat(worldEd, ent.modelindex, 1)
	vmlib.edSetFloat(worldEd, ent.solid, qd.SOLID_BSP)
	vmlib.edSetFloat(worldEd, ent.movetype, qd.MOVETYPE_PUSH)

	if glob.deathmatch then
		vmlib.setGlobalFloat(vm, glob.deathmatch, cvarlib.value(svr.cvars, "deathmatch"))
	end
	buffer.writei32(vm.globals, glob.mapname * 4, vmlib.allocString(vm, svr.name))
	vmlib.setGlobalFloat(vm, glob.serverflags, svr.serverflags)

	vmlib.loadFromFileQW(vm, svr.worldmodel.brush.entities, cvarlib.value(svr.cvars, "deathmatch"), glob, ent)

	svr.active = true
	vm.serverActive = true
	svr.state = 2 -- ss_active

	-- SV_FindModelNumbers
	svr.sv_nailmodel, svr.sv_supernailmodel, svr.sv_playermodel = -1, -1, -1
	for i, name in svr.model_precache do
		if name == "progs/spike.mdl" then
			svr.sv_nailmodel = i - 1
		elseif name == "progs/s_spike.mdl" then
			svr.sv_supernailmodel = i - 1
		elseif name == "progs/player.mdl" then
			svr.sv_playermodel = i - 1
		end
	end

	-- run two frames to allow everything to settle
	svr.frametime = 0.1
	qwphys.physics(svr)
	qwphys.physics(svr)

	qwsv.createBaseline(svr)
end

-- SV_CreateBaseline: per-entity reference states for delta compression,
-- plus the svc_spawnbaseline signon messages
function qwsv.createBaseline(svr: any)
	local vm = svr.vm
	local ent = svr.qdefs.ent
	svr.baselines = {} :: { [number]: qwents.EntityState }
	local playerModel = svr.sv_playermodel >= 0 and svr.sv_playermodel or 0
	for entnum = 0, vm.num_edicts - 1 do
		local svent = vm.edicts[entnum + 1]
		if svent.free then
			continue
		end
		-- create baselines for all player slots, and any other
		-- edict that has a visible model
		if entnum > svr.maxclients and vmlib.edFloat(svent, ent.modelindex) == 0 then
			continue
		end

		local base = qwents.nullState(entnum)
		base.origin = vmlib.edVector(svent, ent.origin)
		base.angles = vmlib.edVector(svent, ent.angles)
		base.frame = vmlib.edFloat(svent, ent.frame)
		base.skinnum = vmlib.edFloat(svent, ent.skin)
		if entnum > 0 and entnum <= svr.maxclients then
			base.colormap = entnum
			base.modelindex = playerModel
		else
			base.colormap = 0
			base.modelindex = svr.modelIndex(svr, vmlib.edString(vm, svent, ent.model)) or 0
		end
		svr.baselines[entnum] = base

		msg.writeByte(svr.signon, qwp.svc_spawnbaseline)
		msg.writeShort(svr.signon, entnum)
		msg.writeByte(svr.signon, base.modelindex)
		msg.writeByte(svr.signon, base.frame)
		msg.writeByte(svr.signon, base.colormap)
		msg.writeByte(svr.signon, base.skinnum)
		msg.writeCoord(svr.signon, base.origin.x)
		msg.writeAngle(svr.signon, base.angles.x)
		msg.writeCoord(svr.signon, base.origin.y)
		msg.writeAngle(svr.signon, base.angles.y)
		msg.writeCoord(svr.signon, base.origin.z)
		msg.writeAngle(svr.signon, base.angles.z)
	end
end

function qwsv.baselineFor(svr: any, num: number): qwents.EntityState
	return (svr.baselines and svr.baselines[num]) or qwents.nullState(num)
end

-- SV_ExtractFromUserinfo essentials
local function extractUserinfo(client: Client)
	client.name = client.userinfo.name or "player"
end

-- connection + spawn flow (Cmd_New_f/Cmd_Spawn_f/Cmd_Begin_f compressed
-- for the offline layer; the wire handshake arrives with netchan)
function qwsv.connectClient(svr: any, slot: number, userinfo: { [string]: string }?)
	local vm = svr.vm
	local qdefs = svr.qdefs
	local client: Client = svr.clients[slot]
	client.active = true
	client.spectator = (userinfo and userinfo.spectator) == "1"
	client.userinfo = userinfo or {}
	extractUserinfo(client)
	client.oldbuttons = 0
	client.entgravity = 1
	client.maxspeed = cvarlib.value(svr.cvars, "sv_maxspeed")
	client.netchan = { incoming_sequence = 0, outgoing_sequence = 0, incoming_acknowledged = 0 }
	client.frames = {}
	client.delta_sequence = -1
	client.lastcmd = qwents.nullCmd()
	client.localtime = 0
	client.spec_track = 0

	local ed = client.edict
	buffer.fill(ed.fields, 0, 0, svr.progs.entityfields * 4)
	ed.free = false
	vmlib.edSetInt(ed, qdefs.ent.netname, vmlib.allocString(vm, client.name))

	-- SetNewParms fills parm1..16 with the fresh-spawn defaults
	vmlib.exec(vm, qdefs.func.SetNewParms)
	for i = 1, 16 do
		client.spawn_parms[i] = vmlib.globalFloat(vm, qdefs.glob["parm" .. i])
	end

	qwsv.spawnIntoGame(svr, client)
end

function qwsv.spawnIntoGame(svr: any, client: Client)
	local vm = svr.vm
	local qdefs = svr.qdefs
	local g = vm.globals

	for i = 1, 16 do
		vmlib.setGlobalFloat(vm, qdefs.glob["parm" .. i], client.spawn_parms[i])
	end
	buffer.writef32(g, qdefs.glob.time * 4, svr.time)
	buffer.writei32(g, qdefs.glob.self * 4, client.edict.num)

	if client.spectator then
		if qdefs.func.SpectatorConnect then
			vmlib.exec(vm, qdefs.func.SpectatorConnect)
		end
	else
		vmlib.exec(vm, qdefs.func.ClientConnect)
		vmlib.exec(vm, qdefs.func.PutClientInServer)
	end
	client.spawned = true
end

-- V_CalcRoll (server side, view.c)
local function calcRoll(angles: vector, velocity: vector): number
	local _f, right, _u = mathlib.angleVectors(angles)
	local side = vector.dot(velocity, right)
	local s = if side < 0 then -1 else 1
	side = math.abs(side)
	local rollangle = 2.0 -- cl_rollangle
	local rollspeed = 200 -- cl_rollspeed
	if side < rollspeed then
		side = side * rollangle / rollspeed
	else
		side = rollangle
	end
	return side * s
end

-- SV_RunCmd
function qwsv.runCmd(svr: any, client: Client, ucmd: pmovelib.UserCmd)
	local vm = svr.vm
	local qdefs = svr.qdefs
	local ent = qdefs.ent
	local glob = qdefs.glob
	local player = client.edict
	local g = vm.globals

	-- chop up very long commands
	if ucmd.msec > 50 then
		local oldmsec = ucmd.msec
		local half = table.clone(ucmd)
		half.msec = oldmsec // 2
		qwsv.runCmd(svr, client, half)
		local half2 = table.clone(half)
		half2.impulse = 0
		qwsv.runCmd(svr, client, half2)
		return
	end

	if vmlib.edFloat(player, ent.fixangle) == 0 then
		vmlib.edSetVector(player, ent.v_angle, ucmd.angles)
	end

	vmlib.edSetFloat(player, ent.button0, bit32.band(ucmd.buttons, 1))
	vmlib.edSetFloat(player, ent.button2, bit32.rshift(bit32.band(ucmd.buttons, 2), 1))
	if (ucmd :: any).impulse and (ucmd :: any).impulse ~= 0 then
		vmlib.edSetFloat(player, ent.impulse, (ucmd :: any).impulse)
	end

	-- angles: show 1/3 the pitch angle and all the roll angle
	if vmlib.edFloat(player, ent.health) > 0 then
		local v_angle = vmlib.edVector(player, ent.v_angle)
		local angles = vmlib.edVector(player, ent.angles)
		if vmlib.edFloat(player, ent.fixangle) == 0 then
			angles = vector.create(-v_angle.x / 3, v_angle.y, angles.z)
		end
		local roll = calcRoll(angles, vmlib.edVector(player, ent.velocity)) * 4
		vmlib.edSetVector(player, ent.angles, vector.create(angles.x, angles.y, roll))
	end

	local frametime = math.min(ucmd.msec * 0.001, 0.1)
	svr.frametime = frametime

	if not client.spectator then
		buffer.writef32(g, glob.frametime * 4, frametime)
		buffer.writef32(g, glob.time * 4, svr.time)
		buffer.writei32(g, glob.self * 4, player.num)
		vmlib.exec(vm, qdefs.func.PlayerPreThink)
		qwphys.runThink(svr, player)
	end

	-- fill the pmove state
	local mins = vmlib.edVector(player, ent.mins)
	local hullOfs = mins - pmovelib.PLAYER_MINS
	local pm: pmovelib.PlayerMove = {
		origin = vmlib.edVector(player, ent.origin) + hullOfs,
		angles = vmlib.edVector(player, ent.v_angle),
		velocity = vmlib.edVector(player, ent.velocity),
		oldbuttons = client.oldbuttons,
		waterjumptime = vmlib.edFloat(player, ent.teleport_time),
		dead = vmlib.edFloat(player, ent.health) <= 0,
		spectator = client.spectator,
		physents = { { model = svr.worldmodel :: any, origin = vector.zero } },
		cmd = ucmd,
		numtouch = 0,
		touchindex = {},
		onground = -1,
		waterlevel = 0,
		watertype = 0,
	}

	-- AddLinksToPmove: solid bsp movers and other players within 256
	local physentEdicts: { number } = { 0 } -- physent index -> edict num
	local pmins = pm.origin - vector.create(256, 256, 256)
	local pmaxs = pm.origin + vector.create(256, 256, 256)
	for i = 1, vm.num_edicts - 1 do
		local ed = vm.edicts[i + 1]
		if ed.free or ed == player then
			continue
		end
		local solid = vmlib.edFloat(ed, ent.solid)
		if solid ~= qd.SOLID_BSP and solid ~= qd.SOLID_BBOX and solid ~= qd.SOLID_SLIDEBOX then
			continue
		end
		local amin = vmlib.edVector(ed, ent.absmin)
		local amax = vmlib.edVector(ed, ent.absmax)
		if amin.x > pmaxs.x or amin.y > pmaxs.y or amin.z > pmaxs.z then
			continue
		end
		if amax.x < pmins.x or amax.y < pmins.y or amax.z < pmins.z then
			continue
		end
		if solid == qd.SOLID_BSP then
			local mi = vmlib.edFloat(ed, ent.modelindex)
			local m = svr.models[mi + 1]
			if m and m.kind == "brush" then
				table.insert(pm.physents, { model = m.brush :: any, origin = vmlib.edVector(ed, ent.origin) })
				table.insert(physentEdicts, i)
			end
		else
			table.insert(pm.physents, {
				origin = vmlib.edVector(ed, ent.origin),
				mins = vmlib.edVector(ed, ent.mins),
				maxs = vmlib.edVector(ed, ent.maxs),
			})
			table.insert(physentEdicts, i)
		end
	end

	local movevars: pmovelib.MoveVars = {
		gravity = cvarlib.value(svr.cvars, "sv_gravity"),
		stopspeed = cvarlib.value(svr.cvars, "sv_stopspeed"),
		maxspeed = client.maxspeed,
		spectatormaxspeed = cvarlib.value(svr.cvars, "sv_spectatormaxspeed"),
		accelerate = cvarlib.value(svr.cvars, "sv_accelerate"),
		airaccelerate = cvarlib.value(svr.cvars, "sv_airaccelerate"),
		wateraccelerate = cvarlib.value(svr.cvars, "sv_wateraccelerate"),
		friction = cvarlib.value(svr.cvars, "sv_friction"),
		waterfriction = cvarlib.value(svr.cvars, "sv_waterfriction"),
		entgravity = client.entgravity,
	}

	pmovelib.playerMove(pm, movevars)

	client.oldbuttons = pm.oldbuttons
	vmlib.edSetFloat(player, ent.teleport_time, pm.waterjumptime)
	vmlib.edSetFloat(player, ent.waterlevel, pm.waterlevel)
	vmlib.edSetFloat(player, ent.watertype, pm.watertype)
	local flags = vmlib.edFloat(player, ent.flags)
	if pm.onground ~= -1 then
		flags = bit32.bor(flags, qd.FL_ONGROUND)
		vmlib.edSetFloat(player, ent.flags, flags)
		vmlib.edSetInt(player, ent.groundentity, physentEdicts[pm.onground + 1] or 0)
	else
		vmlib.edSetFloat(player, ent.flags, bit32.band(flags, bit32.bnot(qd.FL_ONGROUND)))
	end
	vmlib.edSetVector(player, ent.origin, pm.origin - hullOfs)
	vmlib.edSetVector(player, ent.velocity, pm.velocity)
	vmlib.edSetVector(player, ent.v_angle, pm.angles)

	if not client.spectator then
		-- link into place and touch triggers
		qwworld.linkEdict(svr.world, player, true)

		-- touch other objects
		local touched: { [number]: boolean } = {}
		for i = 1, pm.numtouch do
			local pidx = pm.touchindex[i]
			local n = physentEdicts[pidx + 1]
			if not n or n == 0 or touched[n] then
				continue
			end
			local other = vm.edicts[n + 1]
			local touchFn = vmlib.edInt(other, ent.touch)
			if touchFn == 0 then
				continue
			end
			buffer.writei32(g, glob.self * 4, n)
			buffer.writei32(g, glob.other * 4, player.num)
			buffer.writef32(g, glob.time * 4, svr.time)
			vmlib.exec(vm, touchFn)
			touched[n] = true
		end
	end
end

-- clc_move essentials: PostRunCmd runs ONCE per move message, not per
-- chopped sub-command; lastcmd is kept (buttons cleared) for the
-- PF_COMMAND playerinfo and for filling dropped packets
function qwsv.executeCmd(svr: any, client: Client, ucmd: pmovelib.UserCmd)
	client.localtime = svr.time
	qwsv.runCmd(svr, client, ucmd)
	qwsv.postRunCmd(svr, client)
	local u = ucmd :: any
	client.lastcmd = {
		angles = ucmd.angles,
		forwardmove = ucmd.forwardmove,
		sidemove = ucmd.sidemove,
		upmove = ucmd.upmove,
		buttons = 0, -- avoid multiple fires on lag
		impulse = u.impulse or 0,
		msec = ucmd.msec,
	}
end

-- SV_PostRunCmd
function qwsv.postRunCmd(svr: any, client: Client)
	local vm = svr.vm
	local qdefs = svr.qdefs
	local g = vm.globals

	if not client.spectator then
		buffer.writef32(g, qdefs.glob.time * 4, svr.time)
		buffer.writei32(g, qdefs.glob.self * 4, client.edict.num)
		vmlib.exec(vm, qdefs.func.PlayerPostThink)
		-- SV_RunNewmis
		local newmis = vmlib.globalInt(vm, qdefs.glob.newmis)
		if newmis ~= 0 then
			local ed = vm.edicts[newmis + 1]
			buffer.writei32(g, qdefs.glob.newmis * 4, 0)
			svr.frametime = 0.05
			qwphys.physicsToss(svr, ed) -- SV_RunNewmis uses the toss path
		end
	elseif qdefs.func.SpectatorThink then
		buffer.writef32(g, qdefs.glob.time * 4, svr.time)
		buffer.writei32(g, qdefs.glob.self * 4, client.edict.num)
		vmlib.exec(vm, qdefs.func.SpectatorThink)
	end
end

--------------------------------------------------------------------------
-- frame updates (sv_ents.c)

local function addToFatPVS(svr: any, org: vector, child: number, fatpvs: buffer, fatbytes: number)
	local data = svr.worldmodel.brush
	while true do
		if child < 0 then
			local leaf = data.leafs[-child]
			if leaf.contents ~= qd.CONTENTS_SOLID then
				local pvs = bsp.leafPVS(leaf, svr.worldmodel)
				for i = 0, math.min(fatbytes, buffer.len(pvs)) - 1 do
					buffer.writeu8(fatpvs, i, bit32.bor(buffer.readu8(fatpvs, i), buffer.readu8(pvs, i)))
				end
			end
			return
		end

		local node = data.nodes[child + 1]
		local plane = data.planes[node.planenum + 1]
		local d = vector.dot(org, plane.normal) - plane.dist
		if d > 8 then
			child = node.children[1]
		elseif d < -8 then
			child = node.children[2]
		else
			addToFatPVS(svr, org, node.children[1], fatpvs, fatbytes)
			child = node.children[2]
		end
	end
end

-- SV_FatPVS: inclusive or of all leafs within 8 units of the point
function qwsv.fatPVS(svr: any, org: vector): buffer
	local fatbytes = bit32.rshift(svr.worldmodel.numleafs + 31, 3)
	local fatpvs = buffer.create(fatbytes)
	addToFatPVS(svr, org, 0, fatpvs, fatbytes)
	return fatpvs
end

local function edictInPVS(ed: vmlib.Edict, pvs: buffer): boolean
	for i = 1, ed.num_leafs do
		local ln = ed.leafnums[i]
		if bit32.band(buffer.readu8(pvs, bit32.rshift(ln, 3)), bit32.lshift(1, bit32.band(ln, 7))) ~= 0 then
			return true
		end
	end
	return false
end

-- SV_WritePlayersToClient
function qwsv.writePlayersToClient(svr: any, client: Client, pvs: buffer, out: msg.SizeBuf)
	local vm = svr.vm
	local ent = svr.qdefs.ent
	local clent = client.edict

	for j = 1, svr.maxclients do
		local cl: Client = svr.clients[j]
		if not (cl.active and cl.spawned) then
			continue
		end
		local ed = cl.edict

		-- ZOID visibility tracking
		if ed ~= clent and not (client.spec_track ~= 0 and client.spec_track == j) then
			if cl.spectator then
				continue
			end
			if not edictInPVS(ed, pvs) then
				continue
			end
		end

		local pflags = bit32.bor(qwp.PF_MSEC, qwp.PF_COMMAND)
		local modelindex = vmlib.edFloat(ed, ent.modelindex)
		local velocity = vmlib.edVector(ed, ent.velocity)
		local effects = vmlib.edFloat(ed, ent.effects)
		local skin = vmlib.edFloat(ed, ent.skin)
		local health = vmlib.edFloat(ed, ent.health)
		local weaponframe = vmlib.edFloat(ed, ent.weaponframe)

		if modelindex ~= svr.sv_playermodel then
			pflags = bit32.bor(pflags, qwp.PF_MODEL)
		end
		if velocity.x ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_VELOCITY1)
		end
		if velocity.y ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_VELOCITY2)
		end
		if velocity.z ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_VELOCITY3)
		end
		if effects ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_EFFECTS)
		end
		if skin ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_SKINNUM)
		end
		if health <= 0 then
			pflags = bit32.bor(pflags, qwp.PF_DEAD)
		end
		if vmlib.edVector(ed, ent.mins).z ~= -24 then
			pflags = bit32.bor(pflags, qwp.PF_GIB)
		end

		if cl.spectator then
			-- only send origin and velocity to spectators
			pflags = bit32.band(pflags, bit32.bor(qwp.PF_VELOCITY1, qwp.PF_VELOCITY2, qwp.PF_VELOCITY3))
		elseif ed == clent then
			-- don't send a lot of data on personal entity
			pflags = bit32.band(pflags, bit32.bnot(bit32.bor(qwp.PF_MSEC, qwp.PF_COMMAND)))
			if weaponframe ~= 0 then
				pflags = bit32.bor(pflags, qwp.PF_WEAPONFRAME)
			end
		end

		if client.spec_track ~= 0 and client.spec_track == j and weaponframe ~= 0 then
			pflags = bit32.bor(pflags, qwp.PF_WEAPONFRAME)
		end

		msg.writeByte(out, qwp.svc_playerinfo)
		msg.writeByte(out, j - 1) -- wire player numbers are 0-based
		msg.writeShort(out, pflags)

		local origin = vmlib.edVector(ed, ent.origin)
		msg.writeCoord(out, origin.x)
		msg.writeCoord(out, origin.y)
		msg.writeCoord(out, origin.z)
		msg.writeByte(out, vmlib.edFloat(ed, ent.frame))

		if bit32.band(pflags, qwp.PF_MSEC) ~= 0 then
			local msec = 1000 * (svr.time - cl.localtime)
			if msec > 255 then
				msec = 255
			end
			msg.writeByte(out, msec // 1)
		end

		if bit32.band(pflags, qwp.PF_COMMAND) ~= 0 then
			local cmd = table.clone(cl.lastcmd)
			if health <= 0 then
				-- don't show the corpse looking around
				cmd.angles = vector.create(0, vmlib.edVector(ed, ent.angles).y, cmd.angles.z)
			end
			cmd.buttons = 0 -- never send buttons
			cmd.impulse = 0 -- never send impulses
			qwents.writeDeltaUsercmd(out, qwents.nullCmd(), cmd)
		end

		if bit32.band(pflags, qwp.PF_VELOCITY1) ~= 0 then
			msg.writeShort(out, velocity.x // 1)
		end
		if bit32.band(pflags, qwp.PF_VELOCITY2) ~= 0 then
			msg.writeShort(out, velocity.y // 1)
		end
		if bit32.band(pflags, qwp.PF_VELOCITY3) ~= 0 then
			msg.writeShort(out, velocity.z // 1)
		end
		if bit32.band(pflags, qwp.PF_MODEL) ~= 0 then
			msg.writeByte(out, modelindex)
		end
		if bit32.band(pflags, qwp.PF_SKINNUM) ~= 0 then
			msg.writeByte(out, skin)
		end
		if bit32.band(pflags, qwp.PF_EFFECTS) ~= 0 then
			msg.writeByte(out, effects)
		end
		if bit32.band(pflags, qwp.PF_WEAPONFRAME) ~= 0 then
			msg.writeByte(out, weaponframe)
		end
	end
end

-- SV_AddNailUpdate / SV_EmitNailUpdate: special dense encoding because
-- there can be a lot of nails
local MAX_NAILS = 32

local function emitNailUpdate(svr: any, nails: { vmlib.Edict }, out: msg.SizeBuf)
	if #nails == 0 then
		return
	end
	local ent = svr.qdefs.ent
	msg.writeByte(out, qwp.svc_nails)
	msg.writeByte(out, #nails)
	for _, ed in nails do
		local org = vmlib.edVector(ed, ent.origin)
		local ang = vmlib.edVector(ed, ent.angles)
		-- [48 bits] xyzpy 12 12 12 4 8
		local x = bit32.arshift((org.x + 4096) // 1, 1)
		local y = bit32.arshift((org.y + 4096) // 1, 1)
		local z = bit32.arshift((org.z + 4096) // 1, 1)
		local p = bit32.band((16 * ang.x / 360) // 1, 15)
		local yaw = bit32.band((256 * ang.y / 360) // 1, 255)
		msg.writeByte(out, bit32.band(x, 255))
		msg.writeByte(out, bit32.band(bit32.bor(bit32.rshift(x, 8), bit32.lshift(y, 4)), 255))
		msg.writeByte(out, bit32.band(bit32.rshift(y, 4), 255))
		msg.writeByte(out, bit32.band(z, 255))
		msg.writeByte(out, bit32.band(bit32.bor(bit32.rshift(z, 8), bit32.lshift(p, 4)), 255))
		msg.writeByte(out, yaw)
	end
end

-- SV_WriteEntitiesToClient: encode this frame's visible state against
-- the client's last acked frame
function qwsv.writeEntitiesToClient(svr: any, client: Client, out: msg.SizeBuf)
	local vm = svr.vm
	local ent = svr.qdefs.ent

	-- this is the frame we are creating
	local frame: ClientFrame = { entities = {}, senttime = svr.time }
	client.frames[bit32.band(client.netchan.incoming_sequence, qwp.UPDATE_MASK)] = frame

	local clent = client.edict
	local org = vmlib.edVector(clent, ent.origin) + vmlib.edVector(clent, ent.view_ofs)
	local pvs = qwsv.fatPVS(svr, org)

	qwsv.writePlayersToClient(svr, client, pvs, out)

	local pack = frame.entities
	local nails: { vmlib.Edict } = {}
	for e = svr.maxclients + 1, vm.num_edicts - 1 do
		local ed = vm.edicts[e + 1]
		if ed.free then
			continue
		end
		-- ignore ents without visible models
		local modelindex = vmlib.edFloat(ed, ent.modelindex)
		if modelindex == 0 or vmlib.edString(vm, ed, ent.model) == "" then
			continue
		end
		if not edictInPVS(ed, pvs) then
			continue
		end
		if (modelindex == svr.sv_nailmodel or modelindex == svr.sv_supernailmodel) and #nails < MAX_NAILS then
			table.insert(nails, ed)
			continue
		end
		if #pack == qwents.MAX_PACKET_ENTITIES then
			continue -- all full
		end

		local state = qwents.nullState(e)
		state.origin = vmlib.edVector(ed, ent.origin)
		state.angles = vmlib.edVector(ed, ent.angles)
		state.modelindex = modelindex
		state.frame = vmlib.edFloat(ed, ent.frame)
		state.colormap = vmlib.edFloat(ed, ent.colormap)
		state.skinnum = vmlib.edFloat(ed, ent.skin)
		state.effects = vmlib.edFloat(ed, ent.effects)
		table.insert(pack, state)
	end

	-- encode as a delta from the last packetentities acked by the client
	local from: { qwents.EntityState }? = nil
	local deltaSeq: number? = nil
	if client.delta_sequence ~= -1 then
		local fromframe = client.frames[bit32.band(client.delta_sequence, qwp.UPDATE_MASK)]
		from = if fromframe then fromframe.entities else {}
		deltaSeq = client.delta_sequence
	end
	qwents.emitPacketEntities(out, pack, from, deltaSeq, function(n: number): qwents.EntityState
		return qwsv.baselineFor(svr, n)
	end)

	emitNailUpdate(svr, nails, out)
end

-- SV_Frame (physics portion; players move on cmd arrival)
function qwsv.frame(svr: any, dt: number)
	if not svr.active or svr.paused then
		return
	end
	svr.frametime = math.clamp(dt, 0.001, 0.1)
	svr.time += svr.frametime
	svr.vm.time = svr.time
	qwphys.physics(svr)
end

return qwsv
