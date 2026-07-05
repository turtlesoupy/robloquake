--!strict
--!optimize 2
-- Host layer — port of the server-side pieces of host.c / host_cmd.c:
-- level spawning (SV_SpawnServer), the per-tick frame function, client
-- string commands (prespawn/spawn/begin/say/...), and inbound message
-- dispatch. This is platform-independent; the Roblox/lune layers feed it
-- connections and clc payloads.

local cvarlib = require("../common/cvar")
local savegamelib = require("./savegame")
local msg = require("../common/msg")
local vfslib = require("../common/vfs")
local modelslib = require("../models/models")
local defs = require("../progs/defs")
local progslib = require("../progs/progs")
local vmlib = require("../progs/vm")
local proto = require("../protocol")
local qd = require("../quakedef")
local pr_cmds = require("./pr_cmds")
local svlib = require("./sv")
local sv_phys = require("./sv_phys")
local sv_user = require("./sv_user")
local world = require("./world")

local host = {}

local ent = defs.ent
local glob = defs.glob

local STAT_TOTALSECRETS = 11
local STAT_TOTALMONSTERS = 12
local STAT_SECRETS = 13
local STAT_MONSTERS = 14

--------------------------------------------------------------------------
-- game creation

function host.newGame(fs: vfslib.Vfs, maxclients: number): svlib.Server
	local svr = svlib.new(fs, maxclients)
	for i = 1, maxclients do
		svr.clients[i] = svlib.newClient(i)
	end
	svr.setIdealPitch = sv_user.setIdealPitch

	-- COM_CheckRegistered: the presence of gfx/pop.lmp marks the registered
	-- version; QC reads cvar("registered") for episode/rune logic
	if vfslib.fileLength(fs, "gfx/pop.lmp") > 0 then
		cvarlib.setValue(svr.cvars, "registered", 1)
		svr.print("Playing registered version.")
	end
	return svr
end

--------------------------------------------------------------------------
-- SV_SpawnServer

function host.spawnServer(svr: svlib.Server, mapname: string)
	svr.dprint(`SpawnServer: {mapname}`)
	svr.changelevelIssued = false
	svr.changelevelTo = nil

	-- make cvars consistent
	local cv = svr.cvars
	if cvarlib.value(cv, "coop") ~= 0 then
		cvarlib.setValue(cv, "deathmatch", 0)
	end
	local skill = math.clamp(math.floor(cvarlib.value(cv, "skill") + 0.5), 0, 3)
	cvarlib.setValue(cv, "skill", skill)

	-- set up the new server
	svr.name = mapname
	svr.modelname = `maps/{mapname}.bsp`
	svr.paused = false
	svr.loadgame = false
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

	-- load progs to get entity field count
	local progsbuf = vfslib.loadFile(svr.fs, "progs.dat")
	if not progsbuf then
		error("PR_LoadProgs: couldn't load progs.dat")
	end
	svr.progs = progslib.load(progsbuf)

	-- allocate server memory
	local vm = vmlib.new(svr.progs, qd.MAX_EDICTS, svr.maxclients)
	svr.vm = vm
	vm.print = svr.print
	vm.time = svr.time

	-- leave slots at start for clients only
	vmlib.initEdicts(vm, svr.maxclients + 1)
	for i = 1, svr.maxclients do
		svr.clients[i].edict = vmlib.edictNum(vm, i)
	end

	svr.state = svlib.ss_loading

	-- load the world model
	svr.reg = modelslib.newRegistry(svr.fs)
	local worldmod = modelslib.forName(svr.reg, svr.modelname, false)
	if not worldmod or worldmod.kind ~= "brush" then
		svr.print(`Couldn't spawn server {svr.modelname}`)
		svr.active = false
		return
	end
	svr.worldmodel = worldmod.brush :: any

	-- clear world interaction links
	svr.world = world.new(vm, svr.worldmodel, svr.brushModels)

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

	-- install builtins (needs svr.world wired)
	pr_cmds.install(svr)

	-- set up the worldspawn edict
	local worldEd = vmlib.edictNum(vm, 0)
	buffer.fill(worldEd.fields, 0, 0, svr.progs.entityfields * 4)
	worldEd.free = false
	vmlib.edSetInt(worldEd, ent.model, vmlib.allocString(vm, svr.modelname))
	vmlib.edSetFloat(worldEd, ent.modelindex, 1) -- world model
	vmlib.edSetFloat(worldEd, ent.solid, qd.SOLID_BSP)
	vmlib.edSetFloat(worldEd, ent.movetype, qd.MOVETYPE_PUSH)

	if cvarlib.value(cv, "coop") ~= 0 then
		vmlib.setGlobalFloat(vm, glob.coop, cvarlib.value(cv, "coop"))
	else
		vmlib.setGlobalFloat(vm, glob.deathmatch, cvarlib.value(cv, "deathmatch"))
	end
	buffer.writei32(vm.globals, glob.mapname * 4, vmlib.allocString(vm, svr.name))

	-- serverflags are for cross level information (sigils)
	vmlib.setGlobalFloat(vm, glob.serverflags, svr.serverflags)

	-- load the rest of the entities
	vmlib.loadFromFile(vm, svr.worldmodel.brush.entities, cvarlib.value(cv, "deathmatch"), skill)

	svr.active = true
	vm.serverActive = true

	-- all setup is completed, any further precache statements are errors
	svr.state = svlib.ss_active

	-- run two frames to allow everything to settle
	svr.frametime = 0.1
	sv_phys.physics(svr)
	sv_phys.physics(svr)

	-- create a baseline for more efficient communications
	svlib.createBaseline(svr)

	-- send serverinfo to all connected clients
	for _, client in svr.clients do
		if client.active then
			svlib.sendServerinfo(svr, client)
		end
	end

	svr.dprint("Server spawned.")
end

--------------------------------------------------------------------------
-- client string commands (host_cmd.c)

local function hostSay(svr: svlib.Server, client: svlib.Client, args: string, teamonly: boolean)
	-- remove quotes if present
	if args:sub(1, 1) == '"' then
		args = args:sub(2, -2)
	end
	local text = `\1{client.name}: {args}\n`
	local teamplay = cvarlib.value(svr.cvars, "teamplay")
	for _, cl in svr.clients do
		if not cl.active or not cl.spawned then
			continue
		end
		if teamonly and teamplay ~= 0 then
			if vmlib.edFloat(cl.edict, ent.team) ~= vmlib.edFloat(client.edict, ent.team) then
				continue
			end
		end
		msg.writeByte(cl.message, proto.svc_print)
		msg.writeString(cl.message, text)
	end
end

local function hostPreSpawn(svr: svlib.Server, client: svlib.Client)
	if client.spawned then
		svr.print("prespawn not valid -- already spawned")
		return
	end
	msg.writeBuf(client.message, svr.signon.data, svr.signon.cursize)
	msg.writeByte(client.message, proto.svc_signonnum)
	msg.writeByte(client.message, 2)
	client.sendsignon = true
end

local function hostSpawn(svr: svlib.Server, client: svlib.Client)
	local vm = svr.vm
	if client.spawned then
		svr.print("Spawn not valid -- already spawned")
		return
	end

	-- run the entrance script
	if svr.loadgame then
		svr.paused = false
	else
		-- set up the edict
		local edict = client.edict
		buffer.fill(edict.fields, 0, 0, svr.progs.entityfields * 4)
		vmlib.edSetFloat(edict, ent.colormap, edict.num)
		vmlib.edSetFloat(edict, ent.team, bit32.band(client.colors, 15) + 1)
		vmlib.edSetInt(edict, ent.netname, vmlib.allocString(vm, client.name))

		-- copy spawn parms out of the client_t
		for i = 0, proto.NUM_SPAWN_PARMS - 1 do
			vmlib.setGlobalFloat(vm, glob.parm1 + i, client.spawn_parms[i + 1])
		end

		-- call the spawn function
		buffer.writef32(vm.globals, glob.time * 4, svr.time)
		buffer.writei32(vm.globals, glob.self * 4, edict.num)
		vmlib.exec(vm, vmlib.globalInt(vm, glob.ClientConnect))
		vmlib.exec(vm, vmlib.globalInt(vm, glob.PutClientInServer))
	end

	-- send all current names, colors, and frag counts
	msg.clear(client.message)

	-- send time of update
	msg.writeByte(client.message, proto.svc_time)
	msg.writeFloat(client.message, svr.time)

	for i, cl in svr.clients do
		msg.writeByte(client.message, proto.svc_updatename)
		msg.writeByte(client.message, i - 1)
		msg.writeString(client.message, cl.name)
		msg.writeByte(client.message, proto.svc_updatefrags)
		msg.writeByte(client.message, i - 1)
		msg.writeShort(client.message, cl.old_frags)
		msg.writeByte(client.message, proto.svc_updatecolors)
		msg.writeByte(client.message, i - 1)
		msg.writeByte(client.message, cl.colors)
	end

	-- send all current light styles
	for i = 0, qd.MAX_LIGHTSTYLES - 1 do
		msg.writeByte(client.message, proto.svc_lightstyle)
		msg.writeByte(client.message, i)
		msg.writeString(client.message, svr.lightstyles[i] or "")
	end

	-- send some stats
	local function stat(statnum: number, value: number)
		msg.writeByte(client.message, proto.svc_updatestat)
		msg.writeByte(client.message, statnum)
		msg.writeLong(client.message, value)
	end
	local vm2 = svr.vm
	stat(STAT_TOTALSECRETS, vmlib.globalFloat(vm2, glob.total_secrets))
	stat(STAT_TOTALMONSTERS, vmlib.globalFloat(vm2, glob.total_monsters))
	stat(STAT_SECRETS, vmlib.globalFloat(vm2, glob.found_secrets))
	stat(STAT_MONSTERS, vmlib.globalFloat(vm2, glob.killed_monsters))

	-- send a fixangle -- never send a roll angle, because savegames can
	-- catch the server in a state where it is expecting the client to
	-- correct the angle and it won't happen if the game was just loaded
	local angles = vmlib.edVector(client.edict, ent.angles)
	msg.writeByte(client.message, proto.svc_setangle)
	msg.writeAngle(client.message, angles.x)
	msg.writeAngle(client.message, angles.y)
	msg.writeAngle(client.message, 0)

	svlib.writeClientdataToMessage(svr, client.edict, client.message)

	msg.writeByte(client.message, proto.svc_signonnum)
	msg.writeByte(client.message, 3)
	client.sendsignon = true
end

local function hostBegin(client: svlib.Client)
	client.spawned = true
end

local function hostKill(svr: svlib.Server, client: svlib.Client)
	local vm = svr.vm
	if vmlib.edFloat(client.edict, ent.health) <= 0 then
		svr.print("Can't suicide -- already dead!")
		return
	end
	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	buffer.writei32(vm.globals, glob.self * 4, client.edict.num)
	vmlib.exec(vm, vmlib.globalInt(vm, glob.ClientKill))
end

local function hostName(svr: svlib.Server, client: svlib.Client, newName: string)
	if newName:sub(1, 1) == '"' then
		newName = newName:sub(2, -2)
	end
	newName = newName:sub(1, 15)
	if client.name ~= "" and client.name ~= "unconnected" and client.name ~= newName then
		svr.print(`{client.name} renamed to {newName}`)
	end
	client.name = newName
	if client.edict then
		vmlib.edSetInt(client.edict, ent.netname, vmlib.allocString(svr.vm, newName))
	end

	-- send notification to all clients
	msg.writeByte(svr.reliable_datagram, proto.svc_updatename)
	msg.writeByte(svr.reliable_datagram, client.num - 1)
	msg.writeString(svr.reliable_datagram, newName)
end

local function hostColor(svr: svlib.Server, client: svlib.Client, args: string)
	local parts = args:split(" ")
	local top, bottom
	if #parts >= 2 then
		top = tonumber(parts[1]) or 0
		bottom = tonumber(parts[2]) or 0
	else
		top = tonumber(parts[1]) or 0
		bottom = top
	end
	top = bit32.band(top, 15)
	if top > 13 then
		top = 13
	end
	bottom = bit32.band(bottom, 15)
	if bottom > 13 then
		bottom = 13
	end
	local playercolor = top * 16 + bottom

	client.colors = playercolor
	vmlib.edSetFloat(client.edict, ent.team, bottom + 1)

	msg.writeByte(svr.reliable_datagram, proto.svc_updatecolors)
	msg.writeByte(svr.reliable_datagram, client.num - 1)
	msg.writeByte(svr.reliable_datagram, playercolor)
end

local function clientPrint(client: svlib.Client, text: string)
	msg.writeByte(client.message, proto.svc_print)
	msg.writeString(client.message, text .. "\n")
end

local function toggleFlag(svr: svlib.Server, client: svlib.Client, flag: number, onMsg: string, offMsg: string)
	local flags = vmlib.edFloat(client.edict, ent.flags)
	flags = bit32.bxor(flags, flag)
	vmlib.edSetFloat(client.edict, ent.flags, flags)
	local active = bit32.band(flags, flag) ~= 0
	msg.writeByte(client.message, proto.svc_print)
	msg.writeString(client.message, (if active then onMsg else offMsg) .. "\n")
end

-- Host commands that a real NetQuake listen server only accepts from the
-- LOCAL console (host_cmd.c cmd_source checks): cheats, level control,
-- server cvars, save/load. The platform layer installs svr.commandGate
-- to say which remote client counts as the host; without a gate (offline
-- tests, loopback) everything is allowed, matching a listen server.
local HOST_ONLY = {
	god = true,
	notarget = true,
	fly = true,
	noclip = true,
	give = true,
	map = true,
	changelevel = true,
	skill = true,
	deathmatch = true,
	coop = true,
	sv_gravity = true,
	sv_maxspeed = true,
	save = true,
	load = true,
}

-- Host_ClientCommand dispatch (the clc_stringcmd cases SV_ReadClientMessage allows)
function host.clientCommand(svr: svlib.Server, client: svlib.Client, s: string)
	s = s:gsub("%s+$", "") -- strip trailing newline/spaces from the wire
	local cmd, args = s:match("^(%S+)%s*(.*)$")
	if not cmd then
		return
	end
	cmd = cmd:lower()

	local gate = (svr :: any).commandGate
	if gate and HOST_ONLY[cmd] and not gate(client) then
		clientPrint(client, `"{cmd}" is a host command`)
		return
	end

	if cmd == "prespawn" then
		hostPreSpawn(svr, client)
	elseif cmd == "spawn" then
		hostSpawn(svr, client)
	elseif cmd == "begin" then
		if (svr :: any).loadgame then
			(svr :: any).loadgame = false
			svr.paused = false
		end
		hostBegin(client)
	elseif cmd == "name" then
		hostName(svr, client, args :: string)
	elseif cmd == "color" then
		hostColor(svr, client, args :: string)
	elseif cmd == "say" or cmd == "say_team" then
		-- the platform layer sets suppressSay when player speech must go
		-- through its own filtered chat channel instead of the wire
		if not (svr :: any).suppressSay then
			hostSay(svr, client, args :: string, cmd == "say_team")
		end
	elseif cmd == "kill" then
		hostKill(svr, client)
	elseif cmd == "god" then
		toggleFlag(svr, client, qd.FL_GODMODE, "godmode ON", "godmode OFF")
	elseif cmd == "notarget" then
		toggleFlag(svr, client, qd.FL_NOTARGET, "notarget ON", "notarget OFF")
	elseif cmd == "fly" then
		local mt = vmlib.edFloat(client.edict, ent.movetype)
		local newmt = if mt ~= qd.MOVETYPE_FLY then qd.MOVETYPE_FLY else qd.MOVETYPE_WALK
		vmlib.edSetFloat(client.edict, ent.movetype, newmt)
	elseif cmd == "noclip" then
		local mt = vmlib.edFloat(client.edict, ent.movetype)
		local newmt = if mt ~= qd.MOVETYPE_NOCLIP then qd.MOVETYPE_NOCLIP else qd.MOVETYPE_WALK
		vmlib.edSetFloat(client.edict, ent.movetype, newmt)
	elseif cmd == "pause" then
		if cvarlib.value(svr.cvars, "pausable") ~= 0 then
			svr.paused = not svr.paused
			svlib.broadcastPrint(svr, `{client.name} {if svr.paused then "paused" else "unpaused"} the game\n`)
			for _, cl in svr.clients do
				if cl.active then
					msg.writeByte(cl.message, proto.svc_setpause)
					msg.writeByte(cl.message, if svr.paused then 1 else 0)
				end
			end
		end
	elseif cmd == "map" or cmd == "changelevel" then
		local target = (args :: string):match("%S+")
		if target then
			svr.changelevelTo = target
		end
	elseif cmd == "skill" or cmd == "deathmatch" or cmd == "coop" or cmd == "sv_gravity" or cmd == "sv_maxspeed" then
		local v = tonumber((args :: string):match("%S+") or "")
		if v then
			cvarlib.setValue(svr.cvars, cmd == "sv_gravity" and "sv_gravity" or cmd, v)
			svlib.broadcastPrint(svr, `{cmd} set to {v}\n`)
		end
	elseif cmd == "give" then
		-- Host_Give_f essentials: weapons by number, ammo/health by letter
		local edict = client.edict
		local what, amount = (args :: string):match("(%S+)%s*(%d*)")
		local n = tonumber(amount or "") or 0
		if what then
			local c0 = what:sub(1, 1)
			local items2 = vmlib.edFloat(edict, ent.items)
			if c0 >= "1" and c0 <= "8" then
				local num = tonumber(c0) :: number
				if num >= 2 then
					vmlib.edSetFloat(edict, ent.items, bit32.bor(items2, bit32.lshift(1, num - 2)))
				end
			elseif c0 == "s" then
				vmlib.edSetFloat(edict, ent.ammo_shells, n)
			elseif c0 == "n" then
				vmlib.edSetFloat(edict, ent.ammo_nails, n)
			elseif c0 == "r" then
				vmlib.edSetFloat(edict, ent.ammo_rockets, n)
			elseif c0 == "c" then
				vmlib.edSetFloat(edict, ent.ammo_cells, n)
			elseif c0 == "h" then
				vmlib.edSetFloat(edict, ent.health, n)
			end
		end
	elseif cmd == "save" then
		-- Host_Savegame_f (storage is the platform layer's concern)
		local name = (args :: string):match("[%w_%-]+")
		if not name then
			clientPrint(client, "save <savename> : save a game")
		elseif svr.intermission ~= nil and (svr :: any).intermission ~= 0 then
			clientPrint(client, "Can't save in intermission.")
		else
			local sg = (svr :: any)
			sg.savegames = sg.savegames or {}
			sg.savegames[name] = savegamelib.write(svr)
			sg.savegameDirty = name
			clientPrint(client, `Saving game to {name}.sav...`)
		end
	elseif cmd == "load" then
		local name = (args :: string):match("[%w_%-]+")
		local sg = (svr :: any)
		if not name then
			clientPrint(client, "load <savename> : load a game")
		elseif not (sg.savegames and sg.savegames[name]) then
			clientPrint(client, `ERROR: couldn't load {name}.sav`)
		else
			sg.loadgameRequest = name -- deferred: can't respawn mid-message
		end
	elseif cmd == "rq_need" then
		-- platform hook: client asks for a pak file in its bundle (demo
		-- playback needs maps/models the current level didn't precache)
		local hook = (svr :: any).onFileRequest
		local path = (args :: string):match("[%w_/%.%-]+")
		if hook and path then
			hook(path)
		end
	elseif cmd == "status" or cmd == "ping" then
		-- informational; not needed for gameplay
	else
		svr.dprint(`{client.name} tried to {s}`)
	end
end

--------------------------------------------------------------------------
-- inbound message processing (SV_ReadClientMessage)

local function readClientMessage(svr: svlib.Server, client: svlib.Client): boolean
	for _, data in client.inbox do
		local r = msg.reader(data)
		while true do
			if not client.active then
				return false -- a command caused an error
			end
			if r.badread then
				svr.print("SV_ReadClientMessage: badread")
				return false
			end

			local cmd = msg.readChar(r)
			if cmd == -1 then
				break -- end of message
			elseif cmd == proto.clc_nop then
				-- nothing
			elseif cmd == proto.clc_stringcmd then
				host.clientCommand(svr, client, msg.readString(r))
			elseif cmd == proto.clc_disconnect then
				return false
			elseif cmd == proto.clc_move then
				sv_user.readClientMove(svr, client, r)
			else
				svr.print(`SV_ReadClientMessage: unknown command char {cmd}`)
				return false
			end
		end
	end
	table.clear(client.inbox)
	return true
end

-- SV_RunClients
function host.runClients(svr: svlib.Server)
	for _, client in svr.clients do
		if not client.active then
			continue
		end

		if not readClientMessage(svr, client) then
			svlib.dropClient(svr, client, false) -- client misbehaved
			continue
		end

		if not client.spawned then
			-- clear client movement until a new packet is received
			client.cmd = { forwardmove = 0, sidemove = 0, upmove = 0 }
			continue
		end

		if not svr.paused then
			sv_user.clientThink(svr, client)
		end
	end
end

--------------------------------------------------------------------------
-- Host_Frame (server part) — call once per tick with the frame time

function host.frame(svr: svlib.Server, frametime: number)
	if not svr.active then
		return
	end

	svr.frametime = frametime
	svr.realtime += frametime

	-- clear the datagram (SV_ClearDatagram)
	msg.clear(svr.datagram)

	-- read client messages and run player commands
	host.runClients(svr)

	-- move things around and think, unless paused
	if not svr.paused then
		sv_phys.physics(svr)
	end

	-- send all messages to the clients
	svlib.sendClientMessages(svr)
end

function host.anySpawned(svr: svlib.Server): boolean
	for _, client in svr.clients do
		if client.active and client.spawned then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------
-- connecting a new client (SV_CheckForNewClients + SV_ConnectClient)

function host.connectClient(svr: svlib.Server, clientnum: number, preserveParms: boolean?)
	svlib.connectClient(svr, clientnum, preserveParms)
end

-- SV_SaveSpawnparms: run SetChangeParms on every active client so their
-- inventory/health carry into the next level, and latch serverflags
-- (rune bits). Must run BEFORE spawnServer tears the world down.
function host.saveSpawnparms(svr: svlib.Server)
	local vm = svr.vm
	svr.serverflags = vmlib.globalFloat(vm, glob.serverflags)
	for _, client in svr.clients do
		if not client.active then
			continue
		end
		buffer.writei32(vm.globals, glob.self * 4, client.edict.num)
		vmlib.exec(vm, vmlib.globalInt(vm, glob.SetChangeParms))
		for i = 0, proto.NUM_SPAWN_PARMS - 1 do
			client.spawn_parms[i + 1] = vmlib.globalFloat(vm, glob.parm1 + i)
		end
	end
end

-- find a free slot for a new connection; returns nil if full
function host.findFreeClient(svr: svlib.Server): number?
	for i, client in svr.clients do
		if not client.active then
			return i
		end
	end
	return nil
end

return host
