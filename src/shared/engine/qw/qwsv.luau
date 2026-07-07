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
local qwnetchan = require("./qwnetchan")
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
-- read-only baseline for delta-cmd encoding (writeDeltaUsercmd never
-- mutates its inputs; a fresh nullCmd per player per reply was garbage)
local NULL_CMD = qwents.nullCmd()

-- C (int) cast: truncation toward zero (// 1 floors, wrong for negatives)
local function trunc(x: number): number
	return if x >= 0 then math.floor(x) else math.ceil(x)
end

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
	netchan: qwnetchan.Netchan,
	frames: { [number]: ClientFrame }, -- ring keyed by seq & UPDATE_MASK
	delta_sequence: number, -- -1 = no delta unless requested (per message)
	lastcmd: qwents.UserCmdWire,
	localtime: number, -- sv.time when the last cmd batch ran
	spec_track: number, -- 1-based player a spectator is tracking, 0 = none

	-- wire state
	stats: { number }, -- [0..MAX_CL_STATS-1] last sent values
	chokecount: number,
	lossage: number,
	connection_started: number,
	last_message: number, -- netchan.last_received (svr.realtime clock)
	userid: number,
	sendinfo: boolean, -- at end of frame, send info to all (new connect)
	send_message: boolean, -- reply owed: one datagram per received packet
	send: ((packet: buffer, hasReliable: boolean?) -> ())?, -- transport hook (remote/loopback)
	address: string?, -- PF_infokey("ip"): transport identity (UserId)
}

export type ClientFrame = {
	entities: { qwents.EntityState },
	senttime: number,
	ping_time: number, -- realtime - senttime when the client acked, -1 pending
}

function qwsv.newGame(fsys: vfslib.Vfs, qwprogsBuf: buffer?): any
	local svr: any = {}
	svr.fs = fsys
	-- QW loads qwprogs.dat with COM_LoadFile: the searchpath stack resolves
	-- it, so a mod gamedir's progs override the base game's. Callers may
	-- also inject a buffer directly (the Studio boot's chunk-asset path).
	svr.qwprogsBuf = qwprogsBuf or vfslib.loadFile(fsys, "qwprogs.dat")
	if not svr.qwprogsBuf then
		error("PR_LoadProgs: couldn't load qwprogs.dat (not in any searchpath pak)")
	end
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
			sv_phs = 1,
			sv_spectalk = 1,
			pausable = 1,
			registered = 1,
			timeout = 65, -- sv_main.c: seconds without a packet before drop
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
			netchan = qwnetchan.new(),
			frames = {},
			delta_sequence = -1,
			lastcmd = qwents.nullCmd(),
			localtime = 0,
			spec_track = 0,
			stats = table.create(32, 0),
			chokecount = 0,
			lossage = 0,
			connection_started = 0,
			last_message = 0, -- netchan.last_received (SV_CheckTimeouts)
			userid = i,
			sendinfo = false,
			send_message = false,
			send = nil,
		}
	end

	svr.serverflags = 0
	svr.spawncount = 0
	svr.serverinfo = { ["*version"] = "2.40", maxclients = tostring(MAX_CLIENTS), deathmatch = "1" }
	-- SV_Localinfo_f's store: operator key/values QC reads via
	-- infokey(world, ...) when serverinfo has no entry (map rotations etc)
	svr.localinfo = {}
	svr.realtime = 0 -- wall clock: accrues across pauses/level changes
	svr.datagram = msg.newBuf(4096)
	svr.reliable_datagram = msg.newBuf(4096)
	-- signon is a LIST of <=MAX_DATAGRAM buffers like C (sv_init.c):
	-- SV_PreSpawn_f streams one per round-trip, so baseline-heavy maps
	-- never have to fit the whole signon in one reliable message
	svr.signon = msg.newBuf(1450)
	svr.signon_buffers = { svr.signon }
	svr.checkSignonSpace = function(s: any)
		qwsv.checkSignonSpace(s)
	end
	svr.calcPing = function(s: any, cl: any): number
		return qwsv.calcPing(s, cl)
	end
	svr.multicast = msg.newBuf(2048)
	svr.print = function(s: string)
		print("[qwsv] " .. s)
	end
	svr.dprint = function(_s: string) end
	svr.active = false

	-- hooks used by qwbuiltins/qwphys
	svr.soundLog = {}
	svr.startSound = function(_svr: any, ed: vmlib.Edict, channel: number, sample: string, volume: number, attenuation: number)
		table.insert(svr.soundLog, { ent = ed.num, channel = channel, sample = sample, volume = volume, attenuation = attenuation })
		qwsv.startSoundWire(svr, ed, channel, sample, volume, attenuation)
	end
	svr.printLog = {}
	svr.broadcastPrint = function(_svr: any, level: number, text: string)
		table.insert(svr.printLog, { level = level, text = text })
		-- SV_BroadcastPrintf: reliable svc_print to every spawned client
		for i = 1, svr.maxclients do
			local cl: Client = svr.clients[i]
			if cl.active and cl.spawned and cl.send then
				msg.writeByte(cl.netchan.message, qwp.svc_print)
				msg.writeByte(cl.netchan.message, level)
				msg.writeString(cl.netchan.message, text)
			end
		end
	end
	svr.clientPrint = function(_svr: any, client: Client, level: number, text: string)
		if level < ((client :: any).messagelevel or 0) then
			return
		end
		table.insert(client.prints, text)
		if client.send then
			msg.writeByte(client.netchan.message, qwp.svc_print)
			msg.writeByte(client.netchan.message, level)
			msg.writeString(client.netchan.message, text)
		end
	end
	svr.svMulticast = function(_svr: any, origin: vector, to: number)
		qwsv.svMulticast(svr, origin, to)
	end
	svr.flushMulticast = function(_svr: any, reliable: boolean)
		-- legacy ALL-semantics flush (builtin 82 now routes svMulticast)
		qwsv.svMulticast(svr, vector.zero, if reliable then 3 else 0)
	end
	svr.fraglog = {}
	svr.logfrag = function(_svr: any, killer: number, killee: number)
		-- SV_LogPlayer format: \killer\killee\ per line, ring of 512
		table.insert(svr.fraglog, { killer = killer, killee = killee, time = svr.time })
		if #svr.fraglog > 512 then
			table.remove(svr.fraglog, 1)
		end
	end
	-- name -> 0-based precache index maps (modelIndex runs per client
	-- per reply against the weaponmodel string; the linear scan was hot).
	-- Maintained lazily: rebuilt when the list length changed.
	local soundIndexMap: { [string]: number } = {}
	local soundIndexFor: any, soundIndexCount = nil, -1
	local modelIndexMap: { [string]: number } = {}
	local modelIndexFor: any, modelIndexCount = nil, -1
	svr.soundIndex = function(_svr: any, sample: string): number?
		local list = svr.sound_precache
		if soundIndexFor ~= list or soundIndexCount ~= #list then
			table.clear(soundIndexMap)
			for i, name in list do
				if soundIndexMap[name] == nil then
					soundIndexMap[name] = i - 1
				end
			end
			soundIndexFor = list
			soundIndexCount = #list
		end
		return soundIndexMap[sample]
	end
	svr.modelIndex = function(_svr: any, name: string): number?
		local list = svr.model_precache
		if modelIndexFor ~= list or modelIndexCount ~= #list then
			table.clear(modelIndexMap)
			for i, n in list do
				if modelIndexMap[n] == nil then
					modelIndexMap[n] = i - 1
				end
			end
			modelIndexFor = list
			modelIndexCount = #list
		end
		return modelIndexMap[name]
	end
	svr.startParticle = function(_svr: any, org: vector, dir: vector, color: number, count: number)
		table.insert(svr.soundLog, { particle = true, org = org, color = color, count = count })
	end
	svr.clientCommands = function(_svr: any, client: Client, text: string)
		table.insert(client.prints, "[stuff] " .. text)
		if client.send then
			msg.writeByte(client.netchan.message, qwp.svc_stufftext)
			msg.writeString(client.netchan.message, text)
		end
	end
	-- QW rand: deterministic LCG shared with the NQ server port
	local rngState = 12345
	svr.rand = function(_svr: any): number
		rngState = (rngState * 214013 + 2531011) % 4294967296
		return bit32.band(bit32.rshift(rngState, 16), 0x7fff)
	end
	return svr
end

-- SV_SaveSpawnparms (sv_ccmds.c): SetChangeParms per spawned client on
-- the OUTGOING progs so inventory carries; latch serverflags. Run
-- before spawnServer reloads the VM.
function qwsv.saveSpawnparms(svr: any)
	if not svr.active then
		return
	end
	local vm = svr.vm
	local qdefs = svr.qdefs
	svr.serverflags = vmlib.globalFloat(vm, qdefs.glob.serverflags)
	for i = 1, svr.maxclients do
		local client: Client = svr.clients[i]
		if not (client.active and client.spawned) then
			continue
		end
		buffer.writei32(vm.globals, qdefs.glob.self * 4, client.edict.num)
		vmlib.exec(vm, qdefs.func.SetChangeParms)
		for j = 1, 16 do
			client.spawn_parms[j] = vmlib.globalFloat(vm, qdefs.glob["parm" .. j])
		end
	end
end

-- SV_SpawnServer: QW reloads the progs on every level
function qwsv.spawnServer(svr: any, mapname: string)
	svr.dprint(`SpawnServer: {mapname}`)
	svr.changelevelTo = nil
	svr.changelevelIssued = false
	svr.spawncount += 1

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
	svr.phsCache = {}
	svr.pvsCache = {}
	msg.clear(svr.datagram)
	msg.clear(svr.reliable_datagram)
	svr.signon = msg.newBuf(1450)
	svr.signon_buffers = { svr.signon }
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
	-- sv_move (walkmove/checkbottom/changeyaw/movetogoal) resolves the
	-- world module + progs ABI through these (shared with the NQ port)
	svr.worldMod = qwworld

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

	-- SV_ProgStartFrame: let progs latch rule cvars before entity spawns
	buffer.writei32(vm.globals, glob.self * 4, 0)
	buffer.writei32(vm.globals, glob.other * 4, 0)
	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	vmlib.exec(vm, qdefs.func.StartFrame)

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

		qwsv.checkSignonSpace(svr)
		msg.writeByte(svr.signon, qwp.svc_spawnbaseline)
		msg.writeShort(svr.signon, entnum)
		msg.writeByte(svr.signon, base.modelindex)
		msg.writeByte(svr.signon, base.frame)
		msg.writeByte(svr.signon, base.colormap)
		msg.writeByte(svr.signon, base.skinnum)
		msg.writeCoord(svr.signon, base.origin.x)
		msg.writeAngleQW(svr.signon, base.angles.x)
		msg.writeCoord(svr.signon, base.origin.y)
		msg.writeAngleQW(svr.signon, base.angles.y)
		msg.writeCoord(svr.signon, base.origin.z)
		msg.writeAngleQW(svr.signon, base.angles.z)
	end
end

function qwsv.baselineFor(svr: any, num: number): qwents.EntityState
	return (svr.baselines and svr.baselines[num]) or qwents.nullState(num)
end

-- SV_ExtractFromUserinfo
local function extractUserinfo(svr: any, client: Client)
	local val = (client.userinfo.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if val == "" or val:lower() == "console" then
		val = "unnamed"
	end
	if val ~= client.name then
		-- dedupe: prefix (N) until unique among other clients
		local dupe = 1
		while true do
			local taken = false
			for i = 1, svr.maxclients do
				local other: Client = svr.clients[i]
				if other.active and other ~= client and other.name == val then
					taken = true
					break
				end
			end
			if not taken then
				break
			end
			dupe += 1
			val = `({dupe}){client.userinfo.name or "unnamed"}`
		end
		if client.name ~= "" and client.name ~= val then
			svr.broadcastPrint(svr, qwp.PRINT_HIGH, `{client.name} changed name to {val}\n`)
		end
		client.name = val
		client.userinfo.name = val
	end
	-- msg: client print filter level
	client.messagelevel = tonumber(client.userinfo.msg) or 0
end

-- connection + spawn flow (Cmd_New_f/Cmd_Spawn_f/Cmd_Begin_f compressed
-- for the offline layer; the wire handshake arrives with netchan)
function qwsv.connectClient(svr: any, slot: number, userinfo: { [string]: string }?)
	local client = qwsv.allocClient(svr, slot, userinfo)
	qwsv.spawnIntoGame(svr, client)
	client.spawned = true
end

-- SV_DirectConnect core: slot setup + default spawn parms via SetNewParms
function qwsv.allocClient(svr: any, slot: number, userinfo: { [string]: string }?): Client
	local vm = svr.vm
	local qdefs = svr.qdefs
	local client: Client = svr.clients[slot]
	client.active = true
	client.spectator = (userinfo and userinfo.spectator) == "1"
	client.userinfo = userinfo or {}
	extractUserinfo(svr, client)
	client.oldbuttons = 0
	client.entgravity = 1
	client.maxspeed = cvarlib.value(svr.cvars, "sv_maxspeed")
	client.netchan = qwnetchan.new()
	client.frames = {}
	client.delta_sequence = -1
	client.lastcmd = qwents.nullCmd()
	client.localtime = 0
	client.spec_track = 0
	client.stats = table.create(32, 0)
	client.chokecount = 0
	client.lossage = 0
	client.connection_started = svr.time
	client.last_message = svr.realtime or 0
	client.send_message = false
	-- C zeroes the whole client_t on connect: ad-hoc fields must not
	-- leak from the slot's previous occupant (stale flood mute etc.)
	local c = client :: any
	c.backbuf = {}
	c.backbufBytes = 0
	c.floodTimes = nil
	c.lockedTill = nil
	c.old_frags = nil

	local ed = client.edict
	buffer.fill(ed.fields, 0, 0, svr.progs.entityfields * 4)
	ed.free = false
	vmlib.edSetInt(ed, qdefs.ent.netname, vmlib.allocString(vm, client.name))

	-- SetNewParms fills parm1..16 with the fresh-spawn defaults
	-- (SV_DirectConnect: default spawn parms for the new client)
	vmlib.exec(vm, qdefs.func.SetNewParms)
	for i = 1, 16 do
		client.spawn_parms[i] = vmlib.globalFloat(vm, qdefs.glob["parm" .. i])
	end
	svr.usercount = (svr.usercount or 0) + 1
	client.userid = svr.usercount
	client.sendinfo = true
	return client
end

-- SV_DirectConnect equivalent for the wire path: allocates the slot
-- and spawn parms only — ClientConnect/PutClientInServer run exactly
-- once, at cmd begin (SV_Begin_f), never during the handshake
function qwsv.wireConnect(svr: any, slot: number, userinfo: { [string]: string }?, send: (packet: buffer, hasReliable: boolean?) -> ()): Client
	local client: Client = qwsv.allocClient(svr, slot, userinfo)
	client.send = send
	return client
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
		-- SV_SpawnSpectator: place at the first info_player_start
		local ed = client.edict
		local ent = qdefs.ent
		vmlib.edSetVector(ed, ent.origin, vector.zero)
		vmlib.edSetVector(ed, ent.view_ofs, vector.create(0, 0, 22))
		for i = svr.maxclients - 1, vm.num_edicts - 1 do
			local e = vm.edicts[i + 1]
			if not e.free and vmlib.edString(vm, e, ent.classname) == "info_player_start" then
				vmlib.edSetVector(ed, ent.origin, vmlib.edVector(e, ent.origin))
				break
			end
		end
		if qdefs.func.SpectatorConnect then
			vmlib.exec(vm, qdefs.func.SpectatorConnect)
		end
	else
		vmlib.exec(vm, qdefs.func.ClientConnect)
		vmlib.exec(vm, qdefs.func.PutClientInServer)
	end
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
-- one-shot per modelindex: a SOLID_BSP edict whose model slot isn't a
-- brush model (C would Sys_Error the server; we omit it from physents)
local warnedBadPhysentModel: { [number]: boolean } = {}

-- AddLinksToPmove's areanode recursion, hoisted to module scope so runCmd
-- doesn't allocate a closure per cmd (C: static function over globals)
local function addLinksToPmove(
	node: any,
	player: vmlib.Edict,
	ent: any,
	svr: any,
	pm: pmovelib.PlayerMove,
	pmins: vector,
	pmaxs: vector,
	physentEdicts: { number }
)
	local sentinel = node.solid_edicts
	local l = sentinel.next
	while l ~= sentinel do
		local nxt = l.next
		local ed = l.ed
		repeat
			if ed == player then
				break
			end
			local solid = vmlib.edFloat(ed, ent.solid)
			if solid ~= qd.SOLID_BSP and solid ~= qd.SOLID_BBOX and solid ~= qd.SOLID_SLIDEBOX then
				break
			end
			if vmlib.edInt(ed, ent.owner) == player.num then
				break -- player's own missile
			end
			if #pm.physents >= 32 then -- MAX_PHYSENTS
				break
			end
			local amin = vmlib.edVector(ed, ent.absmin)
			local amax = vmlib.edVector(ed, ent.absmax)
			if amin.x > pmaxs.x or amin.y > pmaxs.y or amin.z > pmaxs.z then
				break
			end
			if amax.x < pmins.x or amax.y < pmins.y or amax.z < pmins.z then
				break
			end
			if solid == qd.SOLID_BSP then
				local mi = vmlib.edFloat(ed, ent.modelindex)
				local m = svr.models[mi + 1]
				if m and m.kind == "brush" then
					table.insert(pm.physents, { model = m.brush :: any, origin = vmlib.edVector(ed, ent.origin) })
					table.insert(physentEdicts, ed.num)
				elseif not warnedBadPhysentModel[mi] then
					-- C Sys_Errors here ("SOLID_BSP with a non bsp model");
					-- we stay up but the entity is non-solid to players —
					-- say so once instead of failing silently
					warnedBadPhysentModel[mi] = true
					svr.print(`SOLID_BSP edict {ed.num} has non-brush modelindex {mi}; not solid to players`)
				end
			else
				table.insert(pm.physents, {
					origin = vmlib.edVector(ed, ent.origin),
					mins = vmlib.edVector(ed, ent.mins),
					maxs = vmlib.edVector(ed, ent.maxs),
				})
				table.insert(physentEdicts, ed.num)
			end
		until true
		l = nxt
	end
	if node.axis == -1 then
		return
	end
	if mathlib.comp(pmaxs, node.axis) > node.dist then
		addLinksToPmove(node.children[1], player, ent, svr, pm, pmins, pmaxs, physentEdicts)
	end
	if mathlib.comp(pmins, node.axis) < node.dist then
		addLinksToPmove(node.children[2], player, ent, svr, pm, pmins, pmaxs, physentEdicts)
	end
end

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

	-- AddLinksToPmove: solid bsp movers and other players within 256,
	-- collected by walking the areanode solid lists like C (sv_user.c
	-- recursion) instead of scanning every edict per cmd
	local physentEdicts: { number } = { 0 } -- physent index -> edict num
	local pmins = pm.origin - vector.create(256, 256, 256)
	local pmaxs = pm.origin + vector.create(256, 256, 256)
	addLinksToPmove(svr.world.areanodes[1], player, ent, svr, pm, pmins, pmaxs, physentEdicts)

	-- movevars: the cvar half is rebuilt at most once per server frame
	-- (9 hash lookups per cmd otherwise); only maxspeed/entgravity vary
	-- per client
	local movevars: pmovelib.MoveVars = svr.movevarsScratch
	if not movevars or svr.movevarsTime ~= svr.realtime then
		movevars = {
			gravity = cvarlib.value(svr.cvars, "sv_gravity"),
			stopspeed = cvarlib.value(svr.cvars, "sv_stopspeed"),
			maxspeed = 0,
			spectatormaxspeed = cvarlib.value(svr.cvars, "sv_spectatormaxspeed"),
			accelerate = cvarlib.value(svr.cvars, "sv_accelerate"),
			airaccelerate = cvarlib.value(svr.cvars, "sv_airaccelerate"),
			wateraccelerate = cvarlib.value(svr.cvars, "sv_wateraccelerate"),
			friction = cvarlib.value(svr.cvars, "sv_friction"),
			waterfriction = cvarlib.value(svr.cvars, "sv_waterfriction"),
			entgravity = 1,
		}
		svr.movevarsScratch = movevars
		svr.movevarsTime = svr.realtime
	end
	movevars.maxspeed = client.maxspeed
	movevars.entgravity = client.entgravity

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

		-- touch other objects (playertouch: deduped across the whole
		-- clc_move batch — chop halves and net_drop replays included)
		local touched: { [number]: boolean } = (client :: any).playertouch or {};
		(client :: any).playertouch = touched
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
	(client :: any).playertouch = {} -- SV_PreRunCmd
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
		-- SV_RunNewmis (the lastruntime stamp keeps the next SV_Physics
		-- scan from moving the missile a second time)
		local newmis = vmlib.globalInt(vm, qdefs.glob.newmis)
		if newmis ~= 0 then
			local ed = vm.edicts[newmis + 1]
			buffer.writei32(g, qdefs.glob.newmis * 4, 0)
			local saved = svr.frametime
			svr.frametime = 0.05
			qwphys.runEntity(svr, ed)
			svr.frametime = saved
		end
	elseif qdefs.func.SpectatorThink then
		buffer.writef32(g, qdefs.glob.time * 4, svr.time)
		buffer.writei32(g, qdefs.glob.self * 4, client.edict.num)
		vmlib.exec(vm, qdefs.func.SpectatorThink)
	end
end

--------------------------------------------------------------------------
-- wire protocol: handshake user commands + clc processing (sv_user.c)

local MAX_MSGLEN = 1450

local function tokenize(text: string): { string }
	local args: { string } = {}
	local i = 1
	local n = #text
	while i <= n do
		local c = text:sub(i, i)
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			i += 1
		elseif c == '"' then
			local j = text:find('"', i + 1, true)
			if not j then
				table.insert(args, text:sub(i + 1))
				break
			end
			table.insert(args, text:sub(i + 1, j - 1))
			i = j + 1
		else
			local j = text:find("[ \t\n\r]", i) or n + 1
			table.insert(args, text:sub(i, j - 1))
			i = j
		end
	end
	return args
end

local function infoString(t: { [string]: string }): string
	local parts = {}
	for k, v in t do
		table.insert(parts, `\\{k}\\{v}`)
	end
	return table.concat(parts)
end

-- SV_New_f: serverdata + movevars, sent on connect and on level change
function qwsv.newF(svr: any, client: Client)
	if client.spawned then
		return
	end
	client.connection_started = svr.time
	local out = client.netchan.message
	msg.clear(out) -- fresh handshake supersedes anything pending

	msg.writeByte(out, qwp.svc_serverdata)
	msg.writeLong(out, qwp.PROTOCOL_VERSION)
	msg.writeLong(out, svr.spawncount)
	msg.writeString(out, "qw")

	local playernum = client.num - 1
	if client.spectator then
		playernum = bit32.bor(playernum, 128)
	end
	msg.writeByte(out, playernum)

	-- full levelname from worldspawn's message field
	local worldEd = vmlib.edictNum(svr.vm, 0)
	msg.writeString(out, vmlib.edString(svr.vm, worldEd, svr.qdefs.ent.message))

	-- movevars
	local cv = svr.cvars
	msg.writeFloat(out, cvarlib.value(cv, "sv_gravity"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_stopspeed"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_maxspeed"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_spectatormaxspeed"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_accelerate"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_airaccelerate"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_wateraccelerate"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_friction"))
	msg.writeFloat(out, cvarlib.value(cv, "sv_waterfriction"))
	msg.writeFloat(out, 1) -- entgravity

	-- send music
	msg.writeByte(out, qwp.svc_cdtrack)
	msg.writeByte(out, vmlib.edFloat(worldEd, svr.qdefs.ent.sounds))

	msg.writeByte(out, qwp.svc_stufftext)
	msg.writeString(out, `fullserverinfo "{infoString(svr.serverinfo)}"\n`)
end

-- SV_Soundlist_f / SV_Modellist_f share the continuation format
local function writeList(client: Client, svc: number, list: { string }, n: number)
	local out = client.netchan.message
	msg.writeByte(out, svc)
	msg.writeByte(out, n)
	local i = n + 2 -- list[1] is the empty string at precache 0
	while list[i] and out.cursize < MAX_MSGLEN / 2 do
		msg.writeString(out, list[i])
		i += 1
		n += 1
	end
	msg.writeByte(out, 0)
	-- next msg
	if list[i] then
		msg.writeByte(out, n)
	else
		msg.writeByte(out, 0)
	end
end

function qwsv.soundlistF(svr: any, client: Client, args: { string })
	if client.spawned then
		svr.print("soundlist not valid -- allready spawned")
		return
	end
	if tonumber(args[2]) ~= svr.spawncount then
		svr.print("SV_Soundlist_f from different level")
		qwsv.newF(svr, client)
		return
	end
	writeList(client, qwp.svc_soundlist, svr.sound_precache, tonumber(args[3]) or 0)
end

function qwsv.modellistF(svr: any, client: Client, args: { string })
	if client.spawned then
		svr.print("modellist not valid -- allready spawned")
		return
	end
	if tonumber(args[2]) ~= svr.spawncount then
		svr.print("SV_Modellist_f from different level")
		qwsv.newF(svr, client)
		return
	end
	writeList(client, qwp.svc_modellist, svr.model_precache, tonumber(args[3]) or 0)
end

-- SV_FlushSignon: seal the current signon buffer and start a fresh one
-- when it nears the datagram limit (called before each signon write)
function qwsv.checkSignonSpace(svr: any)
	local sg: msg.SizeBuf = svr.signon
	if sg.cursize > sg.maxsize - 512 then
		local fresh = msg.newBuf(1450)
		table.insert(svr.signon_buffers, fresh)
		svr.signon = fresh
	end
end

-- SV_PreSpawn_f: one signon buffer (baselines + statics) per request;
-- the continuation stufftext drives the client to ask for the next
function qwsv.prespawnF(svr: any, client: Client, args: { string })
	if client.spawned then
		svr.print("prespawn not valid -- allready spawned")
		return
	end
	if tonumber(args[2]) ~= svr.spawncount then
		svr.print("SV_PreSpawn_f from different level")
		qwsv.newF(svr, client)
		return
	end
	local bufIdx = tonumber(args[3]) or 0
	if bufIdx < 0 or bufIdx >= #svr.signon_buffers then
		bufIdx = 0
	end
	local sg: msg.SizeBuf = svr.signon_buffers[bufIdx + 1]
	local out = client.netchan.message
	-- SZ_Write of the whole buffer (C: "written to not overflow" — one
	-- 1450-byte chunk always fits the just-flushed reliable stream)
	local pos = out.cursize
	buffer.copy(out.data, pos, sg.data, 0, sg.cursize)
	out.cursize += sg.cursize
	bufIdx += 1
	msg.writeByte(out, qwp.svc_stufftext)
	if bufIdx == #svr.signon_buffers then
		msg.writeString(out, `cmd spawn {svr.spawncount} 0\n`)
	else
		msg.writeString(out, `cmd prespawn {svr.spawncount} {bufIdx}\n`)
	end
end

-- SV_CalcPing: average of the acked frame round-trips, ms
function qwsv.calcPing(svr: any, cl: Client): number
	local ping, count = 0, 0
	for i = 0, qwp.UPDATE_BACKUP - 1 do
		local f = cl.frames[i]
		if f and f.ping_time and f.ping_time > 0 then
			ping += f.ping_time
			count += 1
		end
	end
	if count == 0 then
		return 9999
	end
	return math.floor(ping / count * 1000)
end

-- SV_FullClientUpdate
function qwsv.fullClientUpdate(svr: any, cl: Client, buf: msg.SizeBuf)
	local i = cl.num - 1
	local frags = if cl.active and cl.edict then trunc(vmlib.edFloat(cl.edict, svr.qdefs.ent.frags)) else 0
	msg.writeByte(buf, qwp.svc_updatefrags)
	msg.writeByte(buf, i)
	msg.writeShort(buf, frags)
	msg.writeByte(buf, qwp.svc_updateping)
	msg.writeByte(buf, i)
	msg.writeShort(buf, if cl.active then qwsv.calcPing(svr, cl) else 9999)
	msg.writeByte(buf, qwp.svc_updatepl)
	msg.writeByte(buf, i)
	msg.writeByte(buf, cl.lossage)
	msg.writeByte(buf, qwp.svc_updateentertime)
	msg.writeByte(buf, i)
	msg.writeFloat(buf, svr.time - cl.connection_started)
	msg.writeByte(buf, qwp.svc_updateuserinfo)
	msg.writeByte(buf, i)
	msg.writeLong(buf, cl.userid)
	-- Info_RemovePrefixedKeys: _-prefixed keys are server-private
	local pub: { [string]: string } = {}
	if cl.active then
		for k, v in cl.userinfo do
			if k:sub(1, 1) ~= "_" then
				pub[k] = v
			end
		end
	end
	msg.writeString(buf, infoString(pub))
end

-- SV_Spawn_f: other players' state, lightstyles, forced stats
function qwsv.spawnF(svr: any, client: Client, args: { string })
	if client.spawned then
		svr.print("Spawn not valid -- allready spawned")
		return
	end
	if tonumber(args[2]) ~= svr.spawncount then
		svr.print("SV_Spawn_f from different level")
		qwsv.newF(svr, client)
		return
	end
	local n = tonumber(args[3]) or 0
	if n < 0 or n > svr.maxclients then
		svr.print("SV_Spawn_f invalid client start")
		qwsv.newF(svr, client)
		return
	end
	local out = client.netchan.message
	msg.clear(out) -- C SZ_Clears the reliable stream here

	-- current status of every slot from n on, inactive ones included
	-- (clears stale scoreboard entries client-side)
	for i = n + 1, svr.maxclients do
		qwsv.fullClientUpdateToClient(svr, svr.clients[i], client)
	end

	for i = 0, 63 do
		msg.writeByte(out, qwp.svc_lightstyle)
		msg.writeByte(out, i)
		msg.writeString(out, svr.lightstyles[i] or "")
	end

	-- set up the edict
	local ed = client.edict
	local ent = svr.qdefs.ent
	buffer.fill(ed.fields, 0, 0, svr.progs.entityfields * 4)
	ed.free = false
	vmlib.edSetFloat(ed, ent.colormap, client.edict.num)
	vmlib.edSetFloat(ed, ent.team, 0)
	vmlib.edSetInt(ed, ent.netname, vmlib.allocString(svr.vm, client.name))
	client.entgravity = 1
	client.maxspeed = cvarlib.value(svr.cvars, "sv_maxspeed")
	-- C also seeds the QC fields when the mod declares them (QC that
	-- reads self.gravity before assigning must see 1, not the memset 0)
	local optfield = svr.qdefs.optfield or {}
	if optfield.gravity then
		vmlib.edSetFloat(ed, optfield.gravity, 1)
	end
	if optfield.maxspeed then
		vmlib.edSetFloat(ed, optfield.maxspeed, client.maxspeed)
	end

	-- force stats to be updated
	for i = 0, 31 do
		client.stats[i] = 0
	end
	local glob = svr.qdefs.glob
	for _, stat in
		{
			{ qwp.STAT_TOTALSECRETS, glob.total_secrets },
			{ qwp.STAT_TOTALMONSTERS, glob.total_monsters },
			{ qwp.STAT_SECRETS, glob.found_secrets },
			{ qwp.STAT_MONSTERS, glob.killed_monsters },
		}
	do
		msg.writeByte(out, qwp.svc_updatestatlong)
		msg.writeByte(out, stat[1])
		msg.writeLong(out, vmlib.globalFloat(svr.vm, stat[2]) // 1)
	end

	-- get the client to check and download skins; when that is
	-- completed, a begin command will be issued
	msg.writeByte(out, qwp.svc_stufftext)
	msg.writeString(out, "skins\n")
end

-- SV_Begin_f
function qwsv.beginF(svr: any, client: Client, args: { string })
	if client.spawned then
		return -- don't begin again
	end
	client.spawned = true
	if tonumber(args[2]) ~= svr.spawncount then
		svr.print("SV_Begin_f from different level")
		client.spawned = false
		qwsv.newF(svr, client)
		return
	end
	qwsv.spawnIntoGame(svr, client)

	if svr.paused then
		local out = client.netchan.message
		msg.writeByte(out, qwp.svc_setpause)
		msg.writeByte(out, 1)
		svr.clientPrint(svr, client, qwp.PRINT_HIGH, "Server is paused.\n")
	end
end

-- SV_SetPlayer: find the target client by userid (cheat commands)
function qwsv.setPlayer(svr: any, uid: number): Client?
	for i = 1, svr.maxclients do
		local cl: Client = svr.clients[i]
		if cl.active and cl.userid == uid then
			return cl
		end
	end
	svr.print(`Userid {uid} is not on the server`)
	return nil
end

-- SV_God_f: toggle FL_GODMODE on the target (host-gated at the caller —
-- the platform's host check replaces C's -cheats launch flag)
function qwsv.godF(svr: any, uid: number)
	local cl = qwsv.setPlayer(svr, uid)
	if not cl then
		return
	end
	local flags = bit32.bxor(vmlib.edFloat(cl.edict, svr.qdefs.ent.flags), qd.FL_GODMODE)
	vmlib.edSetFloat(cl.edict, svr.qdefs.ent.flags, flags)
	svr.clientPrint(svr, cl, qwp.PRINT_HIGH, if bit32.band(flags, qd.FL_GODMODE) ~= 0 then "godmode ON\n" else "godmode OFF\n")
end

-- SV_Noclip_f: toggle MOVETYPE_NOCLIP <-> MOVETYPE_WALK
function qwsv.noclipF(svr: any, uid: number)
	local cl = qwsv.setPlayer(svr, uid)
	if not cl then
		return
	end
	local mt = svr.qdefs.ent.movetype
	if vmlib.edFloat(cl.edict, mt) ~= qd.MOVETYPE_NOCLIP then
		vmlib.edSetFloat(cl.edict, mt, qd.MOVETYPE_NOCLIP)
		svr.clientPrint(svr, cl, qwp.PRINT_HIGH, "noclip ON\n")
	else
		vmlib.edSetFloat(cl.edict, mt, qd.MOVETYPE_WALK)
		svr.clientPrint(svr, cl, qwp.PRINT_HIGH, "noclip OFF\n")
	end
end

-- SV_Give_f: weapons by number 2-9 (IT_SHOTGUN << n-2), ammo/health by letter
function qwsv.giveF(svr: any, uid: number, what: string, amount: number)
	local cl = qwsv.setPlayer(svr, uid)
	if not cl or what == "" then
		return
	end
	local ed = cl.edict
	local ent2 = svr.qdefs.ent
	local c0 = what:sub(1, 1)
	if c0 >= "2" and c0 <= "9" then
		local items = vmlib.edFloat(ed, ent2.items)
		vmlib.edSetFloat(ed, ent2.items, bit32.bor(items, bit32.lshift(1, (c0:byte() - string.byte("2")))))
	elseif c0 == "s" then
		vmlib.edSetFloat(ed, ent2.ammo_shells, amount)
	elseif c0 == "n" then
		vmlib.edSetFloat(ed, ent2.ammo_nails, amount)
	elseif c0 == "r" then
		vmlib.edSetFloat(ed, ent2.ammo_rockets, amount)
	elseif c0 == "h" then
		vmlib.edSetFloat(ed, ent2.health, amount)
	elseif c0 == "c" then
		vmlib.edSetFloat(ed, ent2.ammo_cells, amount)
	end
end

-- SV_SendServerInfoChange: svc_serverinfo key/value to every client
function qwsv.sendServerInfoChange(svr: any, key: string, value: string)
	if not svr.active then
		return
	end
	msg.writeByte(svr.reliable_datagram, qwp.svc_serverinfo)
	msg.writeString(svr.reliable_datagram, key)
	msg.writeString(svr.reliable_datagram, value)
end

-- SV_Serverinfo_f's mutation body: set key (star keys refused, "" clears),
-- mirror into a matching cvar, broadcast the change. Returns false when
-- refused.
function qwsv.setServerinfo(svr: any, key: string, value: string): boolean
	if key:sub(1, 1) == "*" then
		svr.print("Star variables cannot be changed.")
		return false
	end
	svr.serverinfo[key] = if value ~= "" then value else nil
	-- "if this is a cvar, change it too" (C pokes string+value directly)
	if svr.cvars and svr.cvars.vars[key] then
		cvarlib.set(svr.cvars, key, value)
	end
	qwsv.sendServerInfoChange(svr, key, value)
	return true
end

-- Info_Print: 20-column keys (keys sorted for a stable table; C prints
-- raw string order)
function qwsv.infoPrint(t: { [string]: string }): string
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		local key = if #k > 20 then k:sub(1, 20) else k .. (" "):rep(20 - #k)
		table.insert(out, key .. t[k] .. "\n")
	end
	return table.concat(out)
end

-- SV_BroadcastCommand: svc_stufftext to every client
function qwsv.broadcastCommand(svr: any, text: string)
	if not svr.active then
		return
	end
	msg.writeByte(svr.reliable_datagram, qwp.svc_stufftext)
	msg.writeString(svr.reliable_datagram, text)
end

-- SV_FullClientUpdateToClient: one client's full update onto another
-- client's reliable stream (no backbuf branch: the transport is reliable)
function qwsv.fullClientUpdateToClient(svr: any, about: Client, to: Client)
	qwsv.fullClientUpdate(svr, about, to.netchan.message)
end

local userCommands: { [string]: (svr: any, client: Client, args: { string }, raw: string) -> () } = {
	new = function(svr, client)
		qwsv.newF(svr, client)
	end,
	soundlist = qwsv.soundlistF,
	modellist = qwsv.modellistF,
	prespawn = qwsv.prespawnF,
	spawn = qwsv.spawnF,
	begin = qwsv.beginF,
	drop = function(svr, client)
		qwsv.dropClient(svr, client)
	end,
	-- SV_Pings_f: refresh everyone's ping/pl on this client
	pings = function(svr, client)
		local out = client.netchan.message
		for i = 1, svr.maxclients do
			local cl: Client = svr.clients[i]
			if cl.active and cl.spawned then
				msg.writeByte(out, qwp.svc_updateping)
				msg.writeByte(out, i - 1)
				msg.writeShort(out, qwsv.calcPing(svr, cl))
				msg.writeByte(out, qwp.svc_updatepl)
				msg.writeByte(out, i - 1)
				msg.writeByte(out, cl.lossage)
			end
		end
	end,
	-- ZOID: spectator autocam target
	ptrack = function(svr, client, args)
		if not client.spectator then
			return
		end
		local ent = svr.qdefs.ent
		if not args[2] then
			client.spec_track = 0
			vmlib.edSetInt(client.edict, ent.goalentity, 0)
			return
		end
		local i = tonumber(args[2]) or -1
		local target = svr.clients[i + 1]
		if i < 0 or i >= svr.maxclients or not (target.active and target.spawned) or target.spectator then
			svr.clientPrint(svr, client, qwp.PRINT_HIGH, "Invalid client to track\n")
			client.spec_track = 0
			vmlib.edSetInt(client.edict, ent.goalentity, 0)
			return
		end
		client.spec_track = i + 1 -- now tracking
		vmlib.edSetInt(client.edict, ent.goalentity, target.edict.num)
	end,
	say = function(svr, client, _args, raw)
		if svr.suppressSay then
			return -- platform routes player speech through filtered chat
		end
		local c: any = client
		-- flood protection: fp_messages msgs per fp_persecond seconds
		c.floodTimes = c.floodTimes or {}
		if c.lockedTill and svr.time < c.lockedTill then
			svr.clientPrint(svr, client, qwp.PRINT_CHAT, "You can't talk for 10 seconds.\n")
			return
		end
		table.insert(c.floodTimes, svr.time)
		if #c.floodTimes > 4 then
			table.remove(c.floodTimes, 1)
			if svr.time - c.floodTimes[1] < 4 then
				c.lockedTill = svr.time + 10
				svr.clientPrint(svr, client, qwp.PRINT_CHAT, "FLOOD PROTECTION: You can't talk for 10 seconds.\n")
				return
			end
		end
		local text = (raw:match("^say%s+(.*)$") or ""):gsub('^"(.*)"$', "%1")
		local prefix = if client.spectator then `[SPEC] {client.name}:` else `{client.name}:`
		local specOnly = client.spectator and cvarlib.value(svr.cvars, "sv_spectalk") == 0
		local line = `{prefix} {text}\n`
		table.insert(svr.printLog, { level = qwp.PRINT_CHAT, text = line })
		for i = 1, svr.maxclients do
			local cl: Client = svr.clients[i]
			if cl.active and cl.spawned and (not specOnly or cl.spectator) then
				svr.clientPrint(svr, cl, qwp.PRINT_CHAT, line)
			end
		end
	end,
	say_team = function(svr, client, _args, raw)
		if svr.suppressSay then
			return -- platform routes player speech through filtered chat
		end
		local text = (raw:match("^say_team%s+(.*)$") or ""):gsub('^"(.*)"$', "%1")
		local team = client.userinfo.team or ""
		local line = `({client.name}): {text}\n`
		table.insert(svr.printLog, { level = qwp.PRINT_CHAT, text = line })
		for i = 1, svr.maxclients do
			local cl: Client = svr.clients[i]
			if cl.active and cl.spawned and (cl.userinfo.team or "") == team then
				svr.clientPrint(svr, cl, qwp.PRINT_CHAT, line)
			end
		end
	end,
	setinfo = function(svr, client, args)
		local key, value = args[2], args[3]
		if not key or not value then
			return
		end
		if key:sub(1, 1) == "*" then
			return -- star keys are server-controlled
		end
		if client.userinfo[key] == value then
			return
		end
		client.userinfo[key] = value
		extractUserinfo(svr, client)
		-- process the change and tell everyone over the reliable stream
		local rd = svr.reliable_datagram
		msg.writeByte(rd, qwp.svc_setinfo)
		msg.writeByte(rd, client.num - 1)
		msg.writeString(rd, key)
		msg.writeString(rd, value)
	end,
	serverinfo = function(svr, client)
		-- SV_ShowServerinfo_f: Info_Print to the requesting client
		svr.clientPrint(svr, client, qwp.PRINT_HIGH, qwsv.infoPrint(svr.serverinfo))
	end,
	pause = function(svr, client)
		if cvarlib.value(svr.cvars, "pausable") == 0 then
			svr.clientPrint(svr, client, qwp.PRINT_HIGH, "Pause not allowed.\n")
			return
		end
		svr.paused = not svr.paused
		svr.broadcastPrint(svr, qwp.PRINT_HIGH, `{client.name} {if svr.paused then "paused" else "unpaused"} the game.\n`)
		local rd = svr.reliable_datagram
		msg.writeByte(rd, qwp.svc_setpause)
		msg.writeByte(rd, if svr.paused then 1 else 0)
	end,
	msg = function(svr, client, args)
		if args[2] then
			client.messagelevel = tonumber(args[2]) or 0
			client.userinfo.msg = args[2]
		end
	end,
	kill = function(svr, client)
		local vm = svr.vm
		if vmlib.edFloat(client.edict, svr.qdefs.ent.health) <= 0 then
			return
		end
		buffer.writef32(vm.globals, svr.qdefs.glob.time * 4, svr.time)
		buffer.writei32(vm.globals, svr.qdefs.glob.self * 4, client.edict.num)
		vmlib.exec(vm, svr.qdefs.func.ClientKill)
	end,
}

function qwsv.executeUserCommand(svr: any, client: Client, raw: string)
	local args = tokenize(raw)
	local handler = args[1] and userCommands[args[1]]
	if handler then
		handler(svr, client, args, raw)
	else
		svr.dprint(`Bad user command: {raw}`)
	end
end

function qwsv.dropClient(svr: any, client: Client)
	-- add the disconnect message (the transport may still flush it)
	msg.writeByte(client.netchan.message, qwp.svc_disconnect)

	if client.spawned then
		local vm = svr.vm
		buffer.writei32(vm.globals, svr.qdefs.glob.self * 4, client.edict.num)
		buffer.writef32(vm.globals, svr.qdefs.glob.time * 4, svr.time)
		if client.spectator then
			if svr.qdefs.func.SpectatorDisconnect then
				vmlib.exec(vm, svr.qdefs.func.SpectatorDisconnect)
			end
		else
			vmlib.exec(vm, svr.qdefs.func.ClientDisconnect)
		end
	end
	qwsv.replyToClient(svr, client)

	client.active = false
	client.spawned = false
	client.send = nil
	client.name = ""
	client.userinfo = {}
	-- C never frees client edicts; the slot is reused on reconnect

	-- tell everyone the slot is gone
	qwsv.fullClientUpdate(svr, client, svr.reliable_datagram)
end

-- SV_ConSay_f: host chat, "console: " prefixed, to every spawned client
function qwsv.conSay(svr: any, text: string)
	text = text:gsub('^"(.*)"$', "%1")
	local line = `console: {text}\n`
	table.insert(svr.printLog, { level = qwp.PRINT_CHAT, text = line })
	for i = 1, svr.maxclients do
		local cl: Client = svr.clients[i]
		if cl.active and cl.spawned then
			svr.clientPrint(svr, cl, qwp.PRINT_CHAT, line)
		end
	end
end

-- SV_Kick_f: drop by userid, with the broadcast + direct notice
function qwsv.kick(svr: any, uid: number): boolean
	for i = 1, svr.maxclients do
		local cl: Client = svr.clients[i]
		if cl.active and cl.userid == uid then
			svr.broadcastPrint(svr, qwp.PRINT_HIGH, `{cl.name} was kicked\n`)
			-- print directly: the dropped client won't get the broadcast
			svr.clientPrint(svr, cl, qwp.PRINT_HIGH, "You were kicked from the game\n")
			qwsv.dropClient(svr, cl)
			return true
		end
	end
	svr.print(`Couldn't find user number {uid}`)
	return false
end

-- SV_ExecuteClientMessage
function qwsv.executeClientMessage(svr: any, client: Client, packet: buffer)
	local chan = client.netchan
	local r = qwnetchan.process(chan, packet)
	if not r then
		return -- stale packet
	end
	-- ping bookkeeping: this packet acks one of our frames
	local acked = client.frames[bit32.band(chan.incoming_acknowledged, qwp.UPDATE_MASK)]
	if acked and acked.ping_time == -1 then
		acked.ping_time = svr.time - acked.senttime
	end
	local netDrop = math.max(chan.drop_count, 0)
	local moveIssued = false

	-- make sure the reply sequence number matches the incoming sequence
	-- number (sv_user.c): dropped client packets would otherwise skew
	-- the two sequence spaces apart for the rest of the session — the
	-- client's frames ring keys prediction and delta compression off
	-- reply seq == cmd seq
	local sendMessage = true
	if chan.incoming_sequence >= chan.outgoing_sequence then
		chan.outgoing_sequence = chan.incoming_sequence
	else
		sendMessage = false -- don't reply, sequences have slipped
	end

	-- mark time so clients will know how much to predict other players
	client.localtime = svr.time
	client.last_message = svr.realtime or 0 -- netchan.last_received
	client.delta_sequence = -1 -- no delta unless requested
	client.send_message = sendMessage -- one reply per received packet

	while true do
		if r.badread then
			svr.print("SV_ReadClientMessage: badread")
			qwsv.dropClient(svr, client)
			return
		end
		local c = msg.readByte(r)
		if c == -1 then
			break
		end

		if c == qwp.clc_nop then
			-- nothing
		elseif c == qwp.clc_delta then
			client.delta_sequence = msg.readByte(r)
		elseif c == qwp.clc_move then
			if moveIssued then
				return -- someone is trying to cheat
			end
			moveIssued = true;
			(client :: any).playertouch = {} -- SV_PreRunCmd
			local _checksum = msg.readByte(r) -- authenticated transport; not validated
			client.lossage = msg.readByte(r)
			local oldest = qwents.readDeltaUsercmd(r, qwents.nullCmd())
			local oldcmd = qwents.readDeltaUsercmd(r, oldest)
			local newcmd = qwents.readDeltaUsercmd(r, oldcmd)
			if client.spawned and not svr.paused then
				-- fill in dropped packets from what we have
				if netDrop < 20 then
					while netDrop > 2 do
						qwsv.runCmd(svr, client, client.lastcmd :: any)
						netDrop -= 1
					end
					if netDrop > 1 then
						qwsv.runCmd(svr, client, oldest :: any)
					end
					if netDrop > 0 then
						qwsv.runCmd(svr, client, oldcmd :: any)
					end
				end
				qwsv.runCmd(svr, client, newcmd :: any)
				qwsv.postRunCmd(svr, client)
			end
			if client.spawned then
				client.lastcmd = newcmd
				client.lastcmd.buttons = 0 -- avoid multiple fires on lag
			end
		elseif c == qwp.clc_tmove then
			local o = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
			-- only allowed by spectators
			if client.spectator then
				vmlib.edSetVector(client.edict, svr.qdefs.ent.origin, o)
				qwworld.linkEdict(svr.world, client.edict, false)
			end
		elseif c == qwp.clc_stringcmd then
			qwsv.executeUserCommand(svr, client, msg.readString(r))
		else
			svr.print(`SV_ReadClientMessage: unknown command char {c}`)
			qwsv.dropClient(svr, client)
			return
		end
	end

	-- PF_stuffcmd("disconnect\n") sets the drop flag mid-QC; honor it
	-- once the message batch is done (C sv_main.c)
	if (client :: any).drop then
		(client :: any).drop = false
		if client.active then
			qwsv.dropClient(svr, client)
		end
	end
end

-- SV_UpdateClientStats: delta update of the stats array over reliable
local statsScratch: { [number]: number } = {} -- C's `int stats[MAX_CL_STATS]` (stack, but fully rewritten per call)
function qwsv.updateClientStats(svr: any, client: Client)
	local ent = svr.qdefs.ent
	local vm = svr.vm
	local ed = client.edict
	if client.spectator and client.spec_track > 0 then
		ed = svr.clients[client.spec_track].edict
	end

	local stats = statsScratch
	table.clear(stats)
	stats[qwp.STAT_HEALTH] = trunc(vmlib.edFloat(ed, ent.health))
	stats[qwp.STAT_WEAPON] = svr.modelIndex(svr, vmlib.edString(vm, ed, ent.weaponmodel)) or 0
	stats[qwp.STAT_AMMO] = trunc(vmlib.edFloat(ed, ent.currentammo))
	stats[qwp.STAT_ARMOR] = trunc(vmlib.edFloat(ed, ent.armorvalue))
	stats[qwp.STAT_SHELLS] = trunc(vmlib.edFloat(ed, ent.ammo_shells))
	stats[qwp.STAT_NAILS] = trunc(vmlib.edFloat(ed, ent.ammo_nails))
	stats[qwp.STAT_ROCKETS] = trunc(vmlib.edFloat(ed, ent.ammo_rockets))
	stats[qwp.STAT_CELLS] = trunc(vmlib.edFloat(ed, ent.ammo_cells))
	if not client.spectator then
		stats[qwp.STAT_ACTIVEWEAPON] = trunc(vmlib.edFloat(ed, ent.weapon))
	end
	-- stuff the sigil bits into the high bits of items for sbar
	stats[qwp.STAT_ITEMS] = bit32.bor(
		bit32.band(trunc(vmlib.edFloat(ed, ent.items)), 0xffffffff),
		bit32.lshift(trunc(vmlib.globalFloat(vm, svr.qdefs.glob.serverflags)), 28) -- live rune bits
	)

	local out = client.netchan.message
	for i = 0, 31 do
		local v = stats[i] or 0
		if v ~= client.stats[i] then
			client.stats[i] = v
			if v >= 0 and v <= 255 then
				msg.writeByte(out, qwp.svc_updatestat)
				msg.writeByte(out, i)
				msg.writeByte(out, v)
			else
				msg.writeByte(out, qwp.svc_updatestatlong)
				msg.writeByte(out, i)
				msg.writeLong(out, v)
			end
		end
	end
end

-- SV_WriteClientdataToMessage
function qwsv.writeClientdataToMessage(svr: any, client: Client, out: msg.SizeBuf)
	local ent = svr.qdefs.ent
	local ed = client.edict
	local vm = svr.vm

	if client.chokecount ~= 0 then
		msg.writeByte(out, qwp.svc_chokecount)
		msg.writeByte(out, client.chokecount)
		client.chokecount = 0
	end

	local dmgTake = vmlib.edFloat(ed, ent.dmg_take)
	local dmgSave = vmlib.edFloat(ed, ent.dmg_save)
	if dmgTake ~= 0 or dmgSave ~= 0 then
		local inflictor = vm.edicts[vmlib.edInt(ed, ent.dmg_inflictor) + 1]
		msg.writeByte(out, qwp.svc_damage)
		msg.writeByte(out, dmgSave)
		msg.writeByte(out, dmgTake)
		local iorg = vmlib.edVector(inflictor, ent.origin)
			+ 0.5 * (vmlib.edVector(inflictor, ent.mins) + vmlib.edVector(inflictor, ent.maxs))
		msg.writeCoord(out, iorg.x)
		msg.writeCoord(out, iorg.y)
		msg.writeCoord(out, iorg.z)
		vmlib.edSetFloat(ed, ent.dmg_take, 0)
		vmlib.edSetFloat(ed, ent.dmg_save, 0)
	end

	-- a fixangle might get lost in a dropped packet. Oh well.
	if vmlib.edFloat(ed, ent.fixangle) ~= 0 then
		msg.writeByte(out, qwp.svc_setangle)
		local ang = vmlib.edVector(ed, ent.angles)
		msg.writeAngleQW(out, ang.x)
		msg.writeAngleQW(out, ang.y)
		msg.writeAngleQW(out, ang.z)
		vmlib.edSetFloat(ed, ent.fixangle, 0)
	end
end

-- SV_SendClientDatagram (the C stack buf is a reused per-client scratch:
-- transmit copies out of it and clears, one reply per received packet)
function qwsv.sendClientDatagram(svr: any, client: Client)
	local c = client :: any
	local out: msg.SizeBuf = c.datagramScratch
	if not out then
		out = msg.newBuf(MAX_MSGLEN, true)
		c.datagramScratch = out
	end
	msg.clear(out)
	out.overflowed = false

	qwsv.writeClientdataToMessage(svr, client, out)
	qwsv.writeEntitiesToClient(svr, client, out)

	-- copy the accumulated multicast datagram for this client
	if client.datagram.overflowed then
		svr.print(`WARNING: datagram overflowed for {client.name}`)
	elseif client.datagram.cursize > 0 then
		local pos = out.cursize
		if pos + client.datagram.cursize <= out.maxsize then
			buffer.copy(out.data, pos, client.datagram.data, 0, client.datagram.cursize)
			out.cursize += client.datagram.cursize
		end
	end
	msg.clear(client.datagram)

	qwsv.updateClientStats(svr, client)

	if out.overflowed then
		svr.print(`WARNING: msg overflowed for {client.name}`)
		msg.clear(out)
	end

	local packet, hasReliable = qwnetchan.transmit(client.netchan, out)
	local send = client.send
	if send then
		send(packet, hasReliable)
	end
end

-- one reply for one received packet: the strict 1:1 exchange keeps the
-- two sequence spaces identical (server frames are keyed by the client
-- sv_nchan.c backbuf equivalent: reliable-by-contract data that does
-- not fit the live stream queues per client as whole-message blocks
-- (a block must never split across packets — each packet parses as a
-- complete svc stream) and drains as transmits free space. It is never
-- silently dropped; a client whose queue ALSO overflows gets dropped
-- at the sweep, like C's MAX_BACK_BUFFERS drop.
local BACKBUF_CAP = 32768
function qwsv.reliableCopy(client: Client, data: buffer, len: number)
	if len == 0 or not client.send then
		return
	end
	local c = client :: any
	local out = client.netchan.message
	if (c.backbufBytes or 0) == 0 and out.cursize + len <= out.maxsize then
		buffer.copy(out.data, out.cursize, data, 0, len)
		out.cursize += len
		return
	end
	if (c.backbufBytes or 0) + len > BACKBUF_CAP then
		out.overflowed = true -- drop at the next checkTimeouts sweep
		return
	end
	local block = buffer.create(len)
	buffer.copy(block, 0, data, 0, len)
	c.backbuf = c.backbuf or {}
	table.insert(c.backbuf, block)
	c.backbufBytes = (c.backbufBytes or 0) + len
end

local function drainBackbuf(client: Client)
	local c = client :: any
	if not c.backbuf or #c.backbuf == 0 then
		return
	end
	local out = client.netchan.message
	while #c.backbuf > 0 do
		local block: buffer = c.backbuf[1]
		local len = buffer.len(block)
		if out.cursize + len > out.maxsize then
			break -- whole blocks only
		end
		buffer.copy(out.data, out.cursize, block, 0, len)
		out.cursize += len
		table.remove(c.backbuf, 1)
		c.backbufBytes -= len
	end
end

-- packet seq; the client acks with the server packet seq — the delta
-- lookup depends on those being the same number, as in the C netchan)
function qwsv.replyToClient(svr: any, client: Client)
	if not client.send_message or not client.send then
		return
	end
	client.send_message = false
	drainBackbuf(client) -- queued reliable blocks ride this packet
	local send = client.send
	if client.spawned then
		qwsv.sendClientDatagram(svr, client)
	else
		-- handshake replies (or an empty keepalive to stay 1:1). While a
		-- reliable message is in flight with no resend evidence yet, a
		-- pure keepalive would carry nothing — but its higher sequence,
		-- riding the unreliable remote, can outrun the reliable-only
		-- (>~900 byte) signon packet across the two channels and get it
		-- stale-discarded on arrival; under the steady pre-spawn cmd
		-- stream that race can starve the handshake. Withhold the reply
		-- — the client's own cmd stream keeps acks flowing both ways.
		local chan = client.netchan
		if chan.reliable_length > 0 then
			local resend = chan.incoming_acknowledged > chan.last_reliable_sequence
				and chan.incoming_reliable_acknowledged ~= chan.reliable_sequence
			if not resend then
				return
			end
		end
		local packet, hasReliable = qwnetchan.transmit(client.netchan, nil)
		if send then
			send(packet, hasReliable)
		end
	end
end

-- SV_SendClientMessages
function qwsv.sendClientMessages(svr: any)
	for i = 1, svr.maxclients do
		local client: Client = svr.clients[i]
		if client.active then
			qwsv.replyToClient(svr, client)
		end
	end
end

--------------------------------------------------------------------------
-- frame updates (sv_ents.c)

-- decompressed PVS rows cached per leaf for the life of the level
local function leafPVSCached(svr: any, leaf: any): buffer
	local row = svr.pvsCache[leaf]
	if not row then
		row = bsp.leafPVS(leaf, svr.worldmodel)
		svr.pvsCache[leaf] = row
	end
	return row
end
qwsv.leafPVSCached = leafPVSCached

local function addToFatPVS(svr: any, org: vector, child: number, fatpvs: buffer, fatbytes: number)
	local data = svr.worldmodel.brush
	while true do
		if child < 0 then
			local leaf = data.leafs[-child]
			if leaf.contents ~= qd.CONTENTS_SOLID then
				local pvs = leafPVSCached(svr, leaf)
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

-- SV_FatPVS: inclusive or of all leafs within 8 units of the point.
-- The output is C's static fatpvs (reused per call — consumed within
-- the same reply), and decompressed leaf rows are cached per level
-- (the map is static; decompressing 10-30 leafs per reply was garbage)
function qwsv.fatPVS(svr: any, org: vector): buffer
	local fatbytes = bit32.rshift(svr.worldmodel.numleafs + 31, 3)
	local fatpvs: buffer? = svr.fatpvsScratch
	if not fatpvs or buffer.len(fatpvs) < fatbytes then
		fatpvs = buffer.create(fatbytes)
		svr.fatpvsScratch = fatpvs
	end
	local fp = fatpvs :: buffer
	buffer.fill(fp, 0, 0, fatbytes)
	addToFatPVS(svr, org, 0, fp, fatbytes)
	return fp
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
			-- C copies into a stack cmd; reuse one scratch table (this
			-- runs per visible player per client per reply)
			local cmd = svr.cmdScratch
			if not cmd then
				cmd = qwents.nullCmd()
				svr.cmdScratch = cmd
			end
			local lc = cl.lastcmd
			cmd.msec = lc.msec
			cmd.angles = lc.angles
			cmd.forwardmove = lc.forwardmove
			cmd.sidemove = lc.sidemove
			cmd.upmove = lc.upmove
			if health <= 0 then
				-- don't show the corpse looking around
				cmd.angles = vector.create(0, vmlib.edVector(ed, ent.angles).y, cmd.angles.z)
			end
			cmd.buttons = 0 -- never send buttons
			cmd.impulse = 0 -- never send impulses
			qwents.writeDeltaUsercmd(out, NULL_CMD, cmd)
		end

		if bit32.band(pflags, qwp.PF_VELOCITY1) ~= 0 then
			msg.writeShort(out, trunc(velocity.x))
		end
		if bit32.band(pflags, qwp.PF_VELOCITY2) ~= 0 then
			msg.writeShort(out, trunc(velocity.y))
		end
		if bit32.band(pflags, qwp.PF_VELOCITY3) ~= 0 then
			msg.writeShort(out, trunc(velocity.z))
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
		local x = bit32.arshift(trunc(org.x + 4096), 1)
		local y = bit32.arshift(trunc(org.y + 4096), 1)
		local z = bit32.arshift(trunc(org.z + 4096), 1)
		local p = bit32.band(trunc(16 * ang.x / 360), 15)
		local yaw = bit32.band(trunc(256 * ang.y / 360), 255)
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
	local frame: ClientFrame = { entities = {}, senttime = svr.time, ping_time = -1 }
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
		if modelindex == svr.sv_nailmodel or modelindex == svr.sv_supernailmodel then
			-- SV_AddNailUpdate swallows overflow nails too (returns true
			-- when full): they are dropped, not sent as packet entities
			if #nails < MAX_NAILS then
				table.insert(nails, ed)
			end
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

--------------------------------------------------------------------------
-- multicast (sv_send.c SV_Multicast + lazy SV_CalcPHS)

local function visRowBytes(svr: any): number
	return 4 * bit32.rshift(svr.worldmodel.numleafs + 31, 5)
end

-- PVS row for a C leaf number (0 = solid leaf = everything visible)
local function pvsRow(svr: any, leafnumC: number): buffer
	local rowbytes = visRowBytes(svr)
	if leafnumC == 0 then
		local all = buffer.create(rowbytes)
		buffer.fill(all, 0, 0xff, rowbytes)
		return all
	end
	local leaf = svr.worldmodel.brush.leafs[leafnumC + 1]
	local pvs = leafPVSCached(svr, leaf)
	local row = buffer.create(rowbytes)
	buffer.copy(row, 0, pvs, 0, math.min(rowbytes, buffer.len(pvs)))
	return row
end

-- PHS row: the or of the PVS rows of every leaf visible from here
-- (SV_CalcPHS output, computed per-leaf on demand and cached — the
-- eager O(numleafs^2) build would stall level load on this platform)
local function phsRow(svr: any, leafnumC: number): buffer
	local cached = svr.phsCache[leafnumC]
	if cached then
		return cached
	end
	local rowbytes = visRowBytes(svr)
	local num = svr.worldmodel.numleafs
	local scan = pvsRow(svr, leafnumC)
	local row = buffer.create(rowbytes)
	buffer.copy(row, 0, scan, 0, rowbytes)
	for j = 0, rowbytes - 1 do
		local bitbyte = buffer.readu8(scan, j)
		if bitbyte == 0 then
			continue
		end
		for k = 0, 7 do
			if bit32.band(bitbyte, bit32.lshift(1, k)) == 0 then
				continue
			end
			-- or this pvs row into the phs (+1: pvs is 1 based)
			local index = j * 8 + k + 1
			if index >= num then
				continue
			end
			local src = pvsRow(svr, index)
			for w = 0, rowbytes - 4, 4 do
				local b = buffer.readu32(src, w)
				if b ~= 0 then
					buffer.writeu32(row, w, bit32.bor(buffer.readu32(row, w), b))
				end
			end
		end
	end
	svr.phsCache[leafnumC] = row
	return row
end

-- SV_Multicast: sends the contents of svr.multicast to a subset of the
-- clients, then clears it. MULTICAST_ALL/PHS/PVS = 0/1/2, _R = 3/4/5
function qwsv.svMulticast(svr: any, origin: vector, to: number)
	local leaf = bsp.pointInLeaf(origin, svr.worldmodel)
	local leafnum = if leaf then leaf.num else 0

	local reliable = false
	local mask: buffer? = nil
	if to == 3 then
		reliable = true
	elseif to == 4 then
		reliable = true
		mask = phsRow(svr, leafnum)
	elseif to == 1 then
		mask = phsRow(svr, leafnum)
	elseif to == 5 then
		reliable = true
		mask = pvsRow(svr, leafnum)
	elseif to == 2 then
		mask = pvsRow(svr, leafnum)
	elseif to ~= 0 then
		error(`SV_Multicast: bad to:{to}`)
	end

	local ent = svr.qdefs.ent
	for j = 1, svr.maxclients do
		local client: Client = svr.clients[j]
		if not (client.active and client.spawned) then
			continue
		end

		local inrange = mask == nil
		if not inrange then
			local corg = vmlib.edVector(client.edict, ent.origin)
			if (to == 1 or to == 4) and vector.magnitude(origin - corg) <= 1024 then
				inrange = true
			else
				local cleaf = bsp.pointInLeaf(corg, svr.worldmodel)
				if cleaf then
					-- -1: pvs rows are 1 based, not 0 based like leafs
					local ln = cleaf.num - 1
					local m = mask :: buffer
					inrange = ln < 0
						or bit32.band(buffer.readu8(m, bit32.rshift(ln, 3)), bit32.lshift(1, bit32.band(ln, 7))) ~= 0
				else
					inrange = true
				end
			end
		end
		if not inrange then
			continue
		end

		if reliable then
			-- ClientReliableWrite: queued if the stream is full, never
			-- silently dropped
			qwsv.reliableCopy(client, svr.multicast.data, svr.multicast.cursize)
		else
			local dest = client.datagram
			if dest.cursize + svr.multicast.cursize <= dest.maxsize then
				buffer.copy(dest.data, dest.cursize, svr.multicast.data, 0, svr.multicast.cursize)
				dest.cursize += svr.multicast.cursize
			end
		end
	end

	msg.clear(svr.multicast)
end

-- SV_StartSound (wire half; the soundLog hook calls through here)
function qwsv.startSoundWire(svr: any, entity: vmlib.Edict, channel: number, sample: string, volume: number, attenuation: number)
	if not svr.active or not svr.qdefs then
		return
	end
	local sound_num = svr.soundIndex(svr, sample)
	if not sound_num then
		svr.print(`SV_StartSound: {sample} not precacheed`)
		return
	end

	local reliable = false
	local use_phs
	if bit32.band(channel, 8) ~= 0 or cvarlib.value(svr.cvars, "sv_phs") == 0 then
		if bit32.band(channel, 8) ~= 0 then
			reliable = true -- sounds that break the phs are reliable
		end
		use_phs = false
		channel = bit32.band(channel, 7)
	else
		use_phs = true
	end

	channel = bit32.bor(bit32.lshift(entity.num, 3), channel)
	if volume ~= qwp.DEFAULT_SOUND_PACKET_VOLUME then
		channel = bit32.bor(channel, qwp.SND_VOLUME)
	end
	if attenuation ~= qwp.DEFAULT_SOUND_PACKET_ATTENUATION then
		channel = bit32.bor(channel, qwp.SND_ATTENUATION)
	end

	-- use the entity origin unless it is a bmodel
	local ent = svr.qdefs.ent
	local origin
	if vmlib.edFloat(entity, ent.solid) == qd.SOLID_BSP then
		origin = vmlib.edVector(entity, ent.origin)
			+ 0.5 * (vmlib.edVector(entity, ent.mins) + vmlib.edVector(entity, ent.maxs))
	else
		origin = vmlib.edVector(entity, ent.origin)
	end

	msg.writeByte(svr.multicast, qwp.svc_sound)
	msg.writeShort(svr.multicast, channel)
	if bit32.band(channel, qwp.SND_VOLUME) ~= 0 then
		msg.writeByte(svr.multicast, volume)
	end
	if bit32.band(channel, qwp.SND_ATTENUATION) ~= 0 then
		msg.writeByte(svr.multicast, attenuation * 64)
	end
	msg.writeByte(svr.multicast, sound_num)
	msg.writeCoord(svr.multicast, origin.x)
	msg.writeCoord(svr.multicast, origin.y)
	msg.writeCoord(svr.multicast, origin.z)

	if use_phs then
		qwsv.svMulticast(svr, origin, if reliable then 4 else 1)
	else
		qwsv.svMulticast(svr, origin, if reliable then 3 else 0)
	end
end

-- SV_Frame (physics portion; players move on cmd arrival)
function qwsv.frame(svr: any, dt: number)
	if not svr.active then
		return
	end
	-- realtime accrues across pauses and level changes (SV_Frame);
	-- timeouts key off it, never off the per-level sv.time
	svr.realtime = (svr.realtime or 0) + math.clamp(dt, 0.001, 0.1)
	qwsv.checkTimeouts(svr)
	if svr.paused then
		return
	end
	svr.frametime = math.clamp(dt, 0.001, 0.1)
	svr.time += svr.frametime
	svr.vm.time = svr.time
	qwphys.physics(svr)

	qwsv.updateToReliableMessages(svr)
end

-- SV_CheckTimeouts + the sv_send.c overflow sweep: drop clients that
-- stopped sending packets, and clients whose reliable stream overflowed
-- (netchan.message is allowoverflow like C — the write flags + clears
-- instead of erroring, and the drop happens here)
function qwsv.checkTimeouts(svr: any)
	local droptime = svr.realtime - cvarlib.value(svr.cvars, "timeout")
	for i = 1, svr.maxclients do
		local cl: Client = svr.clients[i]
		if not cl.active then
			continue
		end
		if cl.netchan.message.overflowed then
			msg.clear(cl.netchan.message)
			cl.netchan.message.overflowed = false
			svr.broadcastPrint(svr, qwp.PRINT_HIGH, `{cl.name} overflowed\n`)
			svr.print(`WARNING: reliable overflow on {cl.name}`)
			qwsv.dropClient(svr, cl)
		elseif (cl.last_message or 0) < droptime then
			svr.broadcastPrint(svr, qwp.PRINT_HIGH, `{cl.name} timed out\n`)
			qwsv.dropClient(svr, cl)
		end
	end
end

-- SV_UpdateToReliableMessages: per-frame reliable-state sync — frag
-- changes rebroadcast to everyone, per-client entgravity/maxspeed when
-- QC changed them, then sv.reliable_datagram to every connected client
-- and sv.datagram to every spawned client, both cleared
function qwsv.updateToReliableMessages(svr: any)
	local ent = svr.qdefs.ent
	local fields = svr.qdefs.optfield or {}

	for i = 1, svr.maxclients do
		local hc: Client = svr.clients[i]
		if not (hc.active and hc.spawned) then
			continue
		end
		if hc.sendinfo then
			hc.sendinfo = false
			qwsv.fullClientUpdate(svr, hc, svr.reliable_datagram)
		end
		local frags = trunc(vmlib.edFloat(hc.edict, ent.frags))
		if (hc :: any).old_frags ~= frags then
			for j = 1, svr.maxclients do
				local cl: Client = svr.clients[j]
				if cl.active then
					local out = cl.netchan.message
					msg.writeByte(out, qwp.svc_updatefrags)
					msg.writeByte(out, i - 1)
					msg.writeShort(out, frags)
				end
			end
			(hc :: any).old_frags = frags
		end

		-- maxspeed/entgravity changes (QC "gravity"/"maxspeed" fields)
		if fields.gravity then
			local v = vmlib.edFloat(hc.edict, fields.gravity)
			if hc.entgravity ~= v and v ~= 0 then
				hc.entgravity = v
				msg.writeByte(hc.netchan.message, qwp.svc_entgravity)
				msg.writeFloat(hc.netchan.message, v)
			end
		end
		if fields.maxspeed then
			local v = vmlib.edFloat(hc.edict, fields.maxspeed)
			if hc.maxspeed ~= v and v ~= 0 then
				hc.maxspeed = v
				msg.writeByte(hc.netchan.message, qwp.svc_maxspeed)
				msg.writeFloat(hc.netchan.message, v)
			end
		end
	end

	local rd = svr.reliable_datagram
	local dg = svr.datagram
	for i = 1, svr.maxclients do
		local cl: Client = svr.clients[i]
		if not cl.active then
			continue
		end
		if rd.cursize > 0 and cl.send then
			-- reliable-by-contract (frags/setinfo/reconnect stufftexts):
			-- backbuf'd when the window is full, never silently dropped
			qwsv.reliableCopy(cl, rd.data, rd.cursize)
		end
		-- datagrams only go to spawned
		if dg.cursize > 0 and cl.spawned then
			local cdg = cl.datagram
			if cdg.cursize + dg.cursize <= cdg.maxsize then
				buffer.copy(cdg.data, cdg.cursize, dg.data, 0, dg.cursize)
				cdg.cursize += dg.cursize
			end
		end
	end
	msg.clear(rd)
	msg.clear(dg)
end

return qwsv
