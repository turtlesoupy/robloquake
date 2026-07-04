--!strict
-- QuakeWorld client core — cl_main.c/cl_parse.c/cl_ents.c/cl_input.c/
-- cl_pred.c essentials: connection state machine, server message
-- parsing into the frames ring, clc_move construction, and client-side
-- prediction through the shared pmove. Rendering-agnostic: the Roblox
-- layer consumes cl.simorg/simangles, frames, and the event lists.

local modelslib = require("../models/models")
local msg = require("../common/msg")
local pmovelib = require("./pmove")
local qwents = require("./qwents")
local qwnetchan = require("./qwnetchan")
local qwp = require("./qwprotocol")
local vfslib = require("../common/vfs")

local qwcl = {}

local UPDATE_BACKUP = qwp.UPDATE_BACKUP
local UPDATE_MASK = qwp.UPDATE_MASK

export type PlayerState = {
	messagenum: number,
	state_time: number,
	command: qwents.UserCmdWire,
	origin: vector,
	viewangles: vector,
	velocity: vector,
	modelindex: number,
	frame: number,
	skinnum: number,
	effects: number,
	weaponframe: number,
	flags: number,
	-- prediction results carried between frames (C keeps these in the
	-- ring slot and lets parse overwrite only the wire fields)
	oldbuttons: number,
	waterjumptime: number,
	onground: number,
}

export type Frame = {
	cmd: qwents.UserCmdWire,
	senttime: number,
	receivedtime: number,
	delta_sequence: number,
	invalid: boolean,
	playerstate: { [number]: PlayerState }, -- 0-based player num
	packet_entities: { qwents.EntityState },
}

export type PlayerInfo = {
	userinfo: { [string]: string },
	name: string,
	frags: number,
	ping: number,
	pl: number,
	entertime: number,
	userid: number,
	spectator: boolean,
}

local function newPlayerState(): PlayerState
	return {
		messagenum = 0,
		state_time = 0,
		command = qwents.nullCmd(),
		origin = vector.zero,
		viewangles = vector.zero,
		velocity = vector.zero,
		modelindex = 0,
		frame = 0,
		skinnum = 0,
		effects = 0,
		weaponframe = 0,
		flags = 0,
		oldbuttons = 0,
		waterjumptime = 0,
		onground = -1,
	}
end

function qwcl.new(fsys: vfslib.Vfs): any
	local cl: any = {}
	cl.fs = fsys
	cl.state = "disconnected" -- ca_disconnected/connected/onserver/active
	cl.netchan = qwnetchan.new()
	cl.realtime = 0
	cl.time = 0
	cl.latency = 0

	cl.servercount = 0
	cl.gamedir = "qw"
	cl.playernum = 0
	cl.spectator = false
	cl.levelname = ""
	cl.serverinfo = {}
	cl.movevars = nil

	cl.sound_name = {} :: { string } -- [precache index 0..]
	cl.model_name = {} :: { string }
	cl.models = {} :: { [number]: any }
	cl.worldmodel = nil
	cl.reg = modelslib.newRegistry(fsys)

	cl.baselines = {} :: { [number]: qwents.EntityState }
	cl.lightstyles = {} :: { [number]: string }
	cl.stats = table.create(32, 0)
	cl.stats[0] = 0
	cl.players = {} :: { [number]: PlayerInfo }
	cl.static_entities = {}
	cl.static_sounds = {}

	cl.frames = {} :: { [number]: Frame }
	for i = 0, UPDATE_BACKUP - 1 do
		local ps = {}
		for j = 0, qwp.MAX_CLIENTS - 1 do
			ps[j] = newPlayerState()
		end
		cl.frames[i] = {
			cmd = qwents.nullCmd(),
			senttime = 0,
			receivedtime = -1,
			delta_sequence = -1,
			invalid = false,
			playerstate = ps,
			packet_entities = {},
		}
	end
	cl.validsequence = 0
	cl.parsecount = 0
	cl.parsecounttime = 0
	cl.deltaPacketCount = 0 -- svc_deltapacketentities received (netgraph)

	cl.viewangles = vector.zero
	cl.simorg = vector.zero
	cl.simvel = vector.zero
	cl.simangles = vector.zero
	cl.punchangle = 0
	cl.intermission = 0
	cl.paused = false
	cl.cdtrack = 0

	-- event sinks for the renderer/audio layers
	cl.prints = {} :: { { level: number, text: string } }
	cl.centerprints = {} :: { string }
	cl.sounds = {} :: { { ent: number, channel: number, num: number, vol: number, atten: number, pos: vector } }
	cl.tempEntities = {} :: { { type: number, pos: vector, pos2: vector?, entity: number?, count: number? } }
	cl.stufftext = "" -- accumulated; executed by the console layer
	cl.disconnected_reason = nil

	cl.send = nil :: ((packet: buffer) -> ())?
	cl.dprint = function(_s: string) end
	return cl
end

local function sendStringCmd(cl: any, s: string)
	msg.writeByte(cl.netchan.message, qwp.clc_stringcmd)
	msg.writeString(cl.netchan.message, s)
end
qwcl.sendStringCmd = sendStringCmd

-- transmit whatever reliable data is pending (handshake phase; during
-- play clc_move packets carry it)
function qwcl.flush(cl: any)
	if cl.netchan.message.cursize > 0 then
		local packet = qwnetchan.transmit(cl.netchan, nil)
		if cl.send then
			cl.send(packet)
		end
	end
end

function qwcl.connect(cl: any, send: (packet: buffer) -> ())
	cl.send = send
	cl.state = "connected"
	sendStringCmd(cl, "new")
	qwcl.flush(cl)
end

--------------------------------------------------------------------------
-- server message parsing (cl_parse.c)

-- CL_ClearState: wipe per-level state before a new serverdata
local function clearState(cl: any)
	cl.baselines = {}
	cl.lightstyles = {}
	cl.static_entities = {}
	cl.static_sounds = {}
	cl.sound_name = {}
	cl.model_name = {}
	cl.models = {}
	cl.worldmodel = nil
	cl.playerindex = nil
	cl.spikeindex = nil
	cl.validsequence = 0
	cl.nails = {}
	for i = 0, UPDATE_BACKUP - 1 do
		local f: Frame = cl.frames[i]
		f.packet_entities = {}
		f.delta_sequence = -1
		f.invalid = false
	end
	cl.levelResets = (cl.levelResets or 0) + 1 -- renderer watches this
end

local function parseServerData(cl: any, r: msg.Reader)
	clearState(cl)
	local protover = msg.readLong(r)
	if protover ~= qwp.PROTOCOL_VERSION then
		error(`Server returned version {protover}, not {qwp.PROTOCOL_VERSION}`)
	end
	cl.servercount = msg.readLong(r)
	cl.gamedir = msg.readString(r)
	local playernum = msg.readByte(r)
	cl.spectator = bit32.band(playernum, 128) ~= 0
	cl.playernum = bit32.band(playernum, 127)
	cl.levelname = msg.readString(r)
	cl.movevars = {
		gravity = msg.readFloat(r),
		stopspeed = msg.readFloat(r),
		maxspeed = msg.readFloat(r),
		spectatormaxspeed = msg.readFloat(r),
		accelerate = msg.readFloat(r),
		airaccelerate = msg.readFloat(r),
		wateraccelerate = msg.readFloat(r),
		friction = msg.readFloat(r),
		waterfriction = msg.readFloat(r),
		entgravity = msg.readFloat(r),
	}
	-- ask for the sound list next
	sendStringCmd(cl, `soundlist {cl.servercount} 0`)
end

local function parseSoundlist(cl: any, r: msg.Reader)
	local numsounds = msg.readByte(r)
	while true do
		local s = msg.readString(r)
		if s == "" then
			break
		end
		numsounds += 1
		cl.sound_name[numsounds] = s
	end
	local next_ = msg.readByte(r)
	if next_ ~= 0 then
		sendStringCmd(cl, `soundlist {cl.servercount} {next_}`)
	else
		sendStringCmd(cl, `modellist {cl.servercount} 0`)
	end
end

local function parseModellist(cl: any, r: msg.Reader)
	local nummodels = msg.readByte(r)
	while true do
		local s = msg.readString(r)
		if s == "" then
			break
		end
		nummodels += 1
		cl.model_name[nummodels] = s
	end
	local next_ = msg.readByte(r)
	if next_ ~= 0 then
		sendStringCmd(cl, `modellist {cl.servercount} {next_}`)
		return
	end
	-- Model_NextDownload: load everything, world is model 1
	for i = 1, #cl.model_name do
		local name = cl.model_name[i]
		local m = modelslib.forName(cl.reg, name, false)
		cl.models[i] = m
		if i == 1 then
			if not m or m.kind ~= "brush" then
				error(`Couldn't load world model {name}`)
			end
			cl.worldmodel = m.brush
		end
	end
	sendStringCmd(cl, `prespawn {cl.servercount} 0 0`)
end

local function parseBaseline(cl: any, r: msg.Reader)
	local num = msg.readShort(r)
	local es = qwents.nullState(num)
	es.modelindex = msg.readByte(r)
	es.frame = msg.readByte(r)
	es.colormap = msg.readByte(r)
	es.skinnum = msg.readByte(r)
	local ox = msg.readCoord(r)
	local ax = msg.readAngle(r)
	local oy = msg.readCoord(r)
	local ay = msg.readAngle(r)
	local oz = msg.readCoord(r)
	local az = msg.readAngle(r)
	es.origin = vector.create(ox, oy, oz)
	es.angles = vector.create(ax, ay, az)
	cl.baselines[num] = es
end

local function parseStatic(cl: any, r: msg.Reader)
	local es = qwents.nullState(0)
	es.modelindex = msg.readByte(r)
	es.frame = msg.readByte(r)
	es.colormap = msg.readByte(r)
	es.skinnum = msg.readByte(r)
	local ox = msg.readCoord(r)
	local ax = msg.readAngle(r)
	local oy = msg.readCoord(r)
	local ay = msg.readAngle(r)
	local oz = msg.readCoord(r)
	local az = msg.readAngle(r)
	es.origin = vector.create(ox, oy, oz)
	es.angles = vector.create(ax, ay, az)
	table.insert(cl.static_entities, es)
end

local function parseStaticSound(cl: any, r: msg.Reader)
	local pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	local num = msg.readByte(r)
	local vol = msg.readByte(r)
	local atten = msg.readByte(r)
	table.insert(cl.static_sounds, { pos = pos, num = num, vol = vol, atten = atten })
end

local function parseStartSound(cl: any, r: msg.Reader)
	local channel = msg.readShort(r)
	local vol = qwp.DEFAULT_SOUND_PACKET_VOLUME
	local atten = qwp.DEFAULT_SOUND_PACKET_ATTENUATION
	if bit32.band(channel, qwp.SND_VOLUME) ~= 0 then
		vol = msg.readByte(r)
	end
	if bit32.band(channel, qwp.SND_ATTENUATION) ~= 0 then
		atten = msg.readByte(r) / 64
	end
	local num = msg.readByte(r)
	local pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	local ent = bit32.band(bit32.rshift(channel, 3), 1023)
	channel = bit32.band(channel, 7)
	table.insert(cl.sounds, { ent = ent, channel = channel, num = num, vol = vol, atten = atten, pos = pos })
end

local function parseTempEntity(cl: any, r: msg.Reader)
	local t = msg.readByte(r)
	local ev: any = { type = t }
	if t == qwp.TE_LIGHTNING1 or t == qwp.TE_LIGHTNING2 or t == qwp.TE_LIGHTNING3 then
		ev.entity = msg.readShort(r)
		ev.pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
		ev.pos2 = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	elseif t == qwp.TE_GUNSHOT or t == qwp.TE_BLOOD then
		ev.count = msg.readByte(r)
		ev.pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	else
		ev.pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	end
	table.insert(cl.tempEntities, ev)
end

-- CL_ParsePlayerinfo
local function parsePlayerinfo(cl: any, r: msg.Reader)
	local num = msg.readByte(r)
	if num >= qwp.MAX_CLIENTS then
		error("CL_ParsePlayerinfo: bad num")
	end
	local state: PlayerState = cl.frames[bit32.band(cl.parsecount, UPDATE_MASK)].playerstate[num]
	local flags = msg.readShort(r)
	state.flags = flags
	state.messagenum = cl.parsecount
	state.origin = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	state.frame = msg.readByte(r)

	-- the other player's last move was likely some time before the
	-- packet was sent out; track the exact time it was valid at
	if bit32.band(flags, qwp.PF_MSEC) ~= 0 then
		local msec = msg.readByte(r)
		state.state_time = cl.parsecounttime - msec * 0.001
	else
		state.state_time = cl.parsecounttime
	end

	if bit32.band(flags, qwp.PF_COMMAND) ~= 0 then
		state.command = qwents.readDeltaUsercmd(r, qwents.nullCmd())
	end

	local vx = if bit32.band(flags, qwp.PF_VELOCITY1) ~= 0 then msg.readShort(r) else 0
	local vy = if bit32.band(flags, qwp.PF_VELOCITY2) ~= 0 then msg.readShort(r) else 0
	local vz = if bit32.band(flags, qwp.PF_VELOCITY3) ~= 0 then msg.readShort(r) else 0
	state.velocity = vector.create(vx, vy, vz)

	state.modelindex = if bit32.band(flags, qwp.PF_MODEL) ~= 0 then msg.readByte(r) else cl.playerindex or 0
	state.skinnum = if bit32.band(flags, qwp.PF_SKINNUM) ~= 0 then msg.readByte(r) else 0
	state.effects = if bit32.band(flags, qwp.PF_EFFECTS) ~= 0 then msg.readByte(r) else 0
	state.weaponframe = if bit32.band(flags, qwp.PF_WEAPONFRAME) ~= 0 then msg.readByte(r) else 0
	state.viewangles = state.command.angles
end

-- CL_ParsePacketEntities
local function parsePacketEntitiesMsg(cl: any, r: msg.Reader, delta: boolean)
	local newpacket = bit32.band(cl.netchan.incoming_sequence, UPDATE_MASK)
	local newframe: Frame = cl.frames[newpacket]
	newframe.invalid = false

	local oldpacket = -1
	if delta then
		cl.deltaPacketCount += 1
		local from = msg.readByte(r)
		oldpacket = newframe.delta_sequence
		if bit32.band(from, UPDATE_MASK) ~= bit32.band(oldpacket, UPDATE_MASK) then
			cl.dprint("WARNING: from mismatch")
		end
	end

	local oldEnts: { qwents.EntityState }
	if oldpacket ~= -1 then
		if cl.netchan.outgoing_sequence - oldpacket >= UPDATE_BACKUP - 1 then
			-- we can't use this, it is too old (FlushEntityPacket)
			newframe.invalid = true
			cl.validsequence = 0
			-- (FlushEntityPacket: read and discard, keep old data)
			qwents.parsePacketEntities(r, {}, function(n)
				return cl.baselines[n] or qwents.nullState(n)
			end)
			return
		end
		cl.validsequence = cl.netchan.incoming_sequence
		oldEnts = cl.frames[bit32.band(oldpacket, UPDATE_MASK)].packet_entities
	else
		-- full update that we can start delta compressing from now
		oldEnts = {}
		cl.validsequence = cl.netchan.incoming_sequence
	end

	newframe.packet_entities = qwents.parsePacketEntities(r, oldEnts, function(n)
		return cl.baselines[n] or qwents.nullState(n)
	end)
end

local function parseNails(cl: any, r: msg.Reader)
	local count = msg.readByte(r)
	cl.nails = {}
	for _ = 1, count do
		local b = {}
		for i = 1, 6 do
			b[i] = msg.readByte(r)
		end
		local x = bit32.bor(b[1], bit32.lshift(bit32.band(b[2], 15), 8)) * 2 - 4096
		local y = bit32.bor(bit32.rshift(b[2], 4), bit32.lshift(b[3], 4)) * 2 - 4096
		local z = bit32.bor(b[4], bit32.lshift(bit32.band(b[5], 15), 8)) * 2 - 4096
		local pitch = bit32.rshift(b[5], 4) * 360 / 16
		local yaw = b[6] * 360 / 256
		table.insert(cl.nails, { origin = vector.create(x, y, z), angles = vector.create(pitch, yaw, 0) })
	end
end

local function playerInfo(cl: any, num: number): PlayerInfo
	local info = cl.players[num]
	if not info then
		info = {
			userinfo = {},
			name = "",
			frags = 0,
			ping = 0,
			pl = 0,
			entertime = 0,
			userid = 0,
			spectator = false,
		}
		cl.players[num] = info
	end
	return info
end

local function parseUserinfoString(s: string): { [string]: string }
	local t: { [string]: string } = {}
	for k, v in s:gmatch("\\([^\\]*)\\([^\\]*)") do
		t[k] = v
	end
	return t
end

-- executes queued stufftext lines; connection-sequence "cmd" lines are
-- forwarded back to the server (that's how the server drives the
-- handshake); everything else accumulates for the console layer
local function execStufftext(cl: any)
	-- only complete (newline-terminated) lines execute; a partial tail
	-- waits for the next svc_stufftext, like Cbuf accumulation
	local buf = cl.stufftext
	local lastNL = buf:find("\n[^\n]*$")
	local tail = ""
	if not buf:find("\n") then
		return -- nothing complete yet
	end
	if not buf:match("\n$") then
		local cut = buf:match("()[^\n]*$")
		tail = buf:sub(cut)
		buf = buf:sub(1, cut - 1)
	end
	cl.stufftext = ""
	local rest = {}
	-- honor ';' separators within a line
	buf = buf:gsub(";", "\n")
	for line in buf:gmatch("[^\n]+") do
		local cmdArgs = line:match("^cmd%s+(.*)$")
		if cmdArgs then
			sendStringCmd(cl, cmdArgs)
		elseif line == "skins" then
			-- no skin downloads over remotes: report ready immediately
			sendStringCmd(cl, `begin {cl.servercount}`)
			cl.state = "onserver"
		elseif line:match("^fullserverinfo ") then
			local info = line:match('^fullserverinfo%s+"(.*)"$') or ""
			cl.serverinfo = parseUserinfoString(info)
		elseif line == "reconnect" then
			sendStringCmd(cl, "new")
		else
			table.insert(rest, line)
		end
	end
	cl.rawStufftext = (cl.rawStufftext or "") .. (if #rest > 0 then table.concat(rest, "\n") .. "\n" else "")
	cl.stufftext = tail
end

-- CL_ParseServerMessage
function qwcl.parseServerMessage(cl: any, r: msg.Reader)
	-- CL_ParseClientdata: the frame this message acks is OUR cmd frame
	cl.parsecount = cl.netchan.incoming_acknowledged
	local frame: Frame = cl.frames[bit32.band(cl.parsecount, UPDATE_MASK)]
	frame.receivedtime = cl.realtime
	cl.parsecounttime = frame.senttime

	-- drift the average latency towards the observed latency
	local latency = frame.receivedtime - frame.senttime
	if latency >= 0 and latency <= 1.0 then
		if latency < cl.latency then
			cl.latency = latency
		else
			cl.latency += 0.001 -- drift up, so corrections are needed
		end
	end
	cl.nails = {} -- CL_ClearProjectiles: nails live one message

	while true do
		if r.badread then
			error("CL_ParseServerMessage: Bad server message")
		end
		local cmd = msg.readByte(r)
		if cmd == -1 then
			break
		end

		if cmd == qwp.svc_nop then
			-- nothing
		elseif cmd == qwp.svc_disconnect then
			cl.state = "disconnected"
			cl.disconnected_reason = "server disconnected"
			return
		elseif cmd == qwp.svc_print then
			table.insert(cl.prints, { level = msg.readByte(r), text = msg.readString(r) })
		elseif cmd == qwp.svc_centerprint then
			table.insert(cl.centerprints, msg.readString(r))
		elseif cmd == qwp.svc_stufftext then
			cl.stufftext ..= msg.readString(r)
			execStufftext(cl)
		elseif cmd == qwp.svc_damage then
			cl.damage = { save = msg.readByte(r), take = msg.readByte(r), from = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r)) }
		elseif cmd == qwp.svc_serverdata then
			parseServerData(cl, r)
		elseif cmd == qwp.svc_setangle then
			cl.viewangles = vector.create(msg.readAngle(r), msg.readAngle(r), msg.readAngle(r))
			cl.setangle = true -- presentation layer must push into input
		elseif cmd == qwp.svc_lightstyle then
			local i = msg.readByte(r)
			cl.lightstyles[i] = msg.readString(r)
		elseif cmd == qwp.svc_sound then
			parseStartSound(cl, r)
		elseif cmd == qwp.svc_stopsound then
			local i = msg.readShort(r)
			table.insert(cl.sounds, { ent = bit32.rshift(i, 3), channel = bit32.band(i, 7), num = -1, vol = 0, atten = 0, pos = vector.zero })
		elseif cmd == qwp.svc_updatefrags then
			local i = msg.readByte(r)
			playerInfo(cl, i).frags = msg.readShort(r)
		elseif cmd == qwp.svc_updateping then
			local i = msg.readByte(r)
			playerInfo(cl, i).ping = msg.readShort(r)
		elseif cmd == qwp.svc_updatepl then
			local i = msg.readByte(r)
			playerInfo(cl, i).pl = msg.readByte(r)
		elseif cmd == qwp.svc_updateentertime then
			-- time is sent over as seconds ago
			local i = msg.readByte(r)
			playerInfo(cl, i).entertime = cl.realtime - msg.readFloat(r)
		elseif cmd == qwp.svc_updateuserinfo then
			local i = msg.readByte(r)
			local info = playerInfo(cl, i)
			info.userid = msg.readLong(r)
			info.userinfo = parseUserinfoString(msg.readString(r))
			info.name = info.userinfo.name or ""
			info.spectator = (info.userinfo["*spectator"] or "") ~= "" or info.userinfo.spectator == "1"
		elseif cmd == qwp.svc_setinfo then
			local i = msg.readByte(r)
			local key = msg.readString(r)
			local value = msg.readString(r)
			local info = playerInfo(cl, i)
			info.userinfo[key] = value
			-- CL_ProcessUserInfo re-derives on every setinfo
			info.name = info.userinfo.name or info.name
			info.spectator = (info.userinfo["*spectator"] or "") ~= "" or info.userinfo.spectator == "1"
		elseif cmd == qwp.svc_serverinfo then
			local key = msg.readString(r)
			cl.serverinfo[key] = msg.readString(r)
		elseif cmd == qwp.svc_updatestat then
			local i = msg.readByte(r)
			cl.stats[i] = msg.readByte(r)
		elseif cmd == qwp.svc_updatestatlong then
			local i = msg.readByte(r)
			cl.stats[i] = msg.readLong(r)
		elseif cmd == qwp.svc_spawnbaseline then
			parseBaseline(cl, r)
		elseif cmd == qwp.svc_spawnstatic then
			parseStatic(cl, r)
		elseif cmd == qwp.svc_spawnstaticsound then
			parseStaticSound(cl, r)
		elseif cmd == qwp.svc_cdtrack then
			cl.cdtrack = msg.readByte(r)
		elseif cmd == qwp.svc_intermission then
			cl.intermission = 1
			cl.simorg = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
			cl.simangles = vector.create(msg.readAngle(r), msg.readAngle(r), msg.readAngle(r))
			cl.simvel = vector.zero
		elseif cmd == qwp.svc_finale then
			cl.intermission = 2
			table.insert(cl.centerprints, msg.readString(r))
		elseif cmd == qwp.svc_sellscreen then
			-- nothing
		elseif cmd == qwp.svc_smallkick then
			cl.punchangle = -2
		elseif cmd == qwp.svc_bigkick then
			cl.punchangle = -4
		elseif cmd == qwp.svc_muzzleflash then
			local i = msg.readShort(r)
			table.insert(cl.tempEntities, { type = -1, entity = i, pos = vector.zero })
		elseif cmd == qwp.svc_setpause then
			cl.paused = msg.readByte(r) ~= 0
		elseif cmd == qwp.svc_temp_entity then
			parseTempEntity(cl, r)
		elseif cmd == qwp.svc_killedmonster then
			cl.stats[qwp.STAT_MONSTERS] = (cl.stats[qwp.STAT_MONSTERS] or 0) + 1
		elseif cmd == qwp.svc_foundsecret then
			cl.stats[qwp.STAT_SECRETS] = (cl.stats[qwp.STAT_SECRETS] or 0) + 1
		elseif cmd == qwp.svc_playerinfo then
			parsePlayerinfo(cl, r)
		elseif cmd == qwp.svc_nails then
			parseNails(cl, r)
		elseif cmd == qwp.svc_chokecount then
			-- mark the intervening frames as choked for the netgraph
			local n = msg.readByte(r)
			for j = 0, n - 1 do
				cl.frames[bit32.band(cl.netchan.incoming_acknowledged - 1 - j, UPDATE_MASK)].receivedtime = -2
			end
		elseif cmd == qwp.svc_modellist then
			parseModellist(cl, r)
		elseif cmd == qwp.svc_soundlist then
			parseSoundlist(cl, r)
		elseif cmd == qwp.svc_packetentities then
			parsePacketEntitiesMsg(cl, r, false)
		elseif cmd == qwp.svc_deltapacketentities then
			parsePacketEntitiesMsg(cl, r, true)
		elseif cmd == qwp.svc_maxspeed then
			cl.movevars.maxspeed = msg.readFloat(r)
		elseif cmd == qwp.svc_entgravity then
			cl.movevars.entgravity = msg.readFloat(r)
		else
			error(`CL_ParseServerMessage: Illegible server message ({cmd})`)
		end
	end

	-- find playerindex for PF_MODEL defaults
	if not cl.playerindex then
		for i, name in cl.model_name do
			if name == "progs/player.mdl" then
				cl.playerindex = i -- precache slot, 1-based like C
			elseif name == "progs/flag.mdl" then
				cl.flagindex = i -- CTF flag attachment
			end
		end
	end
end

-- process one wire packet from the server
function qwcl.processPacket(cl: any, packet: buffer)
	local r = qwnetchan.process(cl.netchan, packet)
	if not r then
		return -- stale packet
	end
	qwcl.parseServerMessage(cl, r)
	-- during the handshake, reply immediately with any queued cmds
	if cl.state ~= "active" then
		qwcl.flush(cl)
	end
end

--------------------------------------------------------------------------
-- move sending (cl_input.c CL_SendCmd)

-- CL_FinishMove's MakeChar: moves travel as signed chars of 4-unit steps
local function makeChar(i: number): number
	i = bit32.band(i // 1, bit32.bnot(3)) -- &~3 on the int
	if i >= 0x80000000 then
		i -= 0x100000000 -- undo bit32's unsigned view for negatives
	end
	return math.clamp(i, -127 * 4, 127 * 4)
end

-- quantize to the angle16 wire value so prediction replays exactly
-- what the server receives
local function quantAngle(f: number): number
	local v = f * 65536 / 360
	v = if v >= 0 then math.floor(v) else -math.floor(-v)
	v = bit32.band(v, 65535)
	if v >= 32768 then
		v -= 65536 -- signed short on the read side
	end
	return v * (360 / 65536)
end

function qwcl.sendCmd(cl: any, cmd: qwents.UserCmdWire)
	local chan = cl.netchan

	-- CL_FinishMove: chop moves and quantize angles BEFORE storing, so
	-- the predicted cmd equals the wire cmd
	cmd = table.clone(cmd)
	cmd.forwardmove = makeChar(cmd.forwardmove)
	cmd.sidemove = makeChar(cmd.sidemove)
	cmd.upmove = makeChar(cmd.upmove)
	cmd.angles = vector.create(quantAngle(cmd.angles.x), quantAngle(cmd.angles.y), quantAngle(cmd.angles.z))

	-- save this command off for prediction
	local i = bit32.band(chan.outgoing_sequence, UPDATE_MASK)
	local frame: Frame = cl.frames[i]
	frame.cmd = cmd
	frame.senttime = cl.realtime
	frame.receivedtime = -1

	-- don't send too soon after connecting: the first two moves flush
	-- stale pre-spawn input state (C: cl.movemessages <= 2)
	cl.movemessages = (cl.movemessages or 0) + 1
	if cl.movemessages <= 2 then
		return
	end

	local buf = msg.newBuf(128)
	msg.writeByte(buf, qwp.clc_move)
	msg.writeByte(buf, 0) -- checksum: transport is authenticated
	msg.writeByte(buf, 0) -- lossage: transport is reliable

	-- send this and the previous cmds in the message, so if the last
	-- packet was dropped, it can be recovered
	local oldest = cl.frames[bit32.band(chan.outgoing_sequence - 2, UPDATE_MASK)].cmd
	local oldcmd = cl.frames[bit32.band(chan.outgoing_sequence - 1, UPDATE_MASK)].cmd
	qwents.writeDeltaUsercmd(buf, qwents.nullCmd(), oldest)
	qwents.writeDeltaUsercmd(buf, oldest, oldcmd)
	qwents.writeDeltaUsercmd(buf, oldcmd, cmd)

	-- request delta compression of entities
	if chan.outgoing_sequence - cl.validsequence >= UPDATE_BACKUP - 1 then
		cl.validsequence = 0
	end
	if cl.validsequence ~= 0 and cl.state == "active" then
		frame.delta_sequence = cl.validsequence
		msg.writeByte(buf, qwp.clc_delta)
		msg.writeByte(buf, bit32.band(cl.validsequence, 255))
	else
		frame.delta_sequence = -1
	end

	local packet = qwnetchan.transmit(chan, buf)
	if cl.send then
		cl.send(packet)
	end
end

--------------------------------------------------------------------------
-- prediction (cl_pred.c)

-- CL_SetSolidEntities + CL_SetSolidPlayers
local function buildPhysents(cl: any, includePlayers: boolean): { pmovelib.PhysEnt }
	local physents: { pmovelib.PhysEnt } = { { model = cl.worldmodel, origin = vector.zero } }
	-- any packet entity whose model has clipping hulls (brush models)
	local frame: Frame = cl.frames[bit32.band(cl.parsecount, UPDATE_MASK)]
	for _, es in frame.packet_entities do
		if es.modelindex == 0 then
			continue
		end
		local m = cl.models[es.modelindex] -- wire indices are 1-based like C's cl.model_precache
		if m and m.kind == "brush" then
			table.insert(physents, { model = m.brush, origin = es.origin })
		end
	end
	if includePlayers then
		-- CL_SetSolidPlayers: other players block movement, at their
		-- PREDICTED positions
		local predicted = qwcl.predictedPlayerOrigins(cl)
		for num, ps in frame.playerstate do
			if num == cl.playernum or ps.messagenum ~= cl.parsecount then
				continue
			end
			if bit32.band(ps.flags, qwp.PF_DEAD) ~= 0 then
				continue -- dead players aren't solid
			end
			table.insert(physents, {
				origin = predicted[num] or ps.origin,
				mins = pmovelib.PLAYER_MINS,
				maxs = pmovelib.PLAYER_MAXS,
			})
		end
	end
	return physents
end

-- CL_PredictUsercmd
function qwcl.predictUsercmd(cl: any, from: PlayerState, to: PlayerState, u: qwents.UserCmdWire, spectator: boolean)
	-- split up very long moves
	if u.msec > 50 then
		local temp = newPlayerState()
		local split = table.clone(u)
		split.msec = u.msec // 2
		qwcl.predictUsercmd(cl, from, temp, split, spectator)
		qwcl.predictUsercmd(cl, temp, to, split, spectator)
		return
	end

	local pm: pmovelib.PlayerMove = {
		origin = from.origin,
		angles = u.angles,
		velocity = from.velocity,
		oldbuttons = from.oldbuttons,
		waterjumptime = from.waterjumptime,
		dead = (cl.stats[qwp.STAT_HEALTH] or 100) <= 0,
		spectator = spectator,
		physents = cl.predictPhysents or buildPhysents(cl, true),
		cmd = u :: any,
		numtouch = 0,
		touchindex = {},
		onground = -1,
		waterlevel = 0,
		watertype = 0,
	}
	pmovelib.playerMove(pm, cl.movevars)

	to.waterjumptime = pm.waterjumptime
	to.oldbuttons = pm.cmd.buttons
	to.origin = pm.origin
	to.viewangles = pm.angles
	to.velocity = pm.velocity
	to.onground = pm.onground
	to.weaponframe = from.weaponframe
end

-- CL_SetUpPlayerPrediction + CL_LinkPlayers extrapolation: predicted
-- origins for the other players (half the elapsed move, capped 255ms).
-- Returns { [playernum]: origin }; the renderer and the solid-player
-- physents both consume it.
function qwcl.predictedPlayerOrigins(cl: any): { [number]: vector }
	local out: { [number]: vector } = {}
	local playertime = cl.realtime - cl.latency + 0.02
	if playertime > cl.realtime then
		playertime = cl.realtime
	end
	local frame: Frame = cl.frames[bit32.band(cl.parsecount, UPDATE_MASK)]
	-- players predict against world + solid entities only (C runs this
	-- after CL_SetSolidEntities, before players are added)
	local saved = cl.predictPhysents
	cl.predictPhysents = buildPhysents(cl, false)
	for num, state in frame.playerstate do
		if state.messagenum ~= cl.parsecount or state.modelindex == 0 then
			continue
		end
		if num == cl.playernum then
			-- the local player moves locally: last predicted position
			out[num] = cl.frames[bit32.band(cl.netchan.outgoing_sequence, UPDATE_MASK)].playerstate[num].origin
			continue
		end
		-- only predict half the move to minimize overruns
		local msec = 500 * (playertime - state.state_time)
		if msec <= 0 then
			out[num] = state.origin
		else
			local cmd = table.clone(state.command)
			cmd.msec = math.min(msec // 1, 255)
			local exact = newPlayerState()
			qwcl.predictUsercmd(cl, state, exact, cmd, false)
			out[num] = exact.origin
		end
	end
	cl.predictPhysents = saved
	return out
end

-- CL_PredictMove
function qwcl.predictMove(cl: any)
	if cl.paused then
		return
	end
	cl.time = cl.realtime - cl.latency
	if cl.time > cl.realtime then
		cl.time = cl.realtime
	end
	if cl.intermission ~= 0 then
		return
	end
	if cl.validsequence == 0 then
		return
	end
	if cl.netchan.outgoing_sequence - cl.netchan.incoming_sequence >= UPDATE_BACKUP - 1 then
		return
	end

	cl.simangles = cl.viewangles

	-- this is the last frame received from the server
	local from: Frame = cl.frames[bit32.band(cl.netchan.incoming_sequence, UPDATE_MASK)]
	if cl.state == "onserver" then
		-- first update is the final signon stage
		cl.state = "active"
	end

	local fromState = from.playerstate[cl.playernum]
	if cl.nopred then
		cl.simvel = fromState.velocity
		cl.simorg = fromState.origin
		return
	end

	-- predict forward until cl.time <= to->senttime
	cl.predictPhysents = buildPhysents(cl, true)
	local to: Frame? = nil
	local toState = fromState
	local i = 1
	while i < UPDATE_BACKUP - 1 and cl.netchan.incoming_sequence + i < cl.netchan.outgoing_sequence do
		to = cl.frames[bit32.band(cl.netchan.incoming_sequence + i, UPDATE_MASK)]
		toState = to.playerstate[cl.playernum]
		qwcl.predictUsercmd(cl, fromState, toState, to.cmd, cl.spectator)
		if to.senttime >= cl.time then
			break
		end
		from = to
		fromState = toState
		i += 1
	end
	cl.predictPhysents = nil

	if i == UPDATE_BACKUP - 1 or not to then
		return -- net hasn't delivered packets in a long time
	end

	-- now interpolate some fraction of the final frame
	local f = 0
	if to.senttime ~= from.senttime then
		f = math.clamp((cl.time - from.senttime) / (to.senttime - from.senttime), 0, 1)
	end

	local fo = from.playerstate[cl.playernum].origin
	local dx = math.abs(fo.x - toState.origin.x)
	local dy = math.abs(fo.y - toState.origin.y)
	local dz = math.abs(fo.z - toState.origin.z)
	if dx > 128 or dy > 128 or dz > 128 then
		-- teleported, so don't lerp
		cl.simvel = toState.velocity
		cl.simorg = toState.origin
		return
	end

	local fs = from.playerstate[cl.playernum]
	cl.simorg = fs.origin + f * (toState.origin - fs.origin)
	cl.simvel = fs.velocity + f * (toState.velocity - fs.velocity)
end

return qwcl
