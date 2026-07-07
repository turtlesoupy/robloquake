--!strict
--!optimize 2
-- Client state machine — port of WinQuake cl_parse.c / cl_main.c: server
-- message parsing, entity interpolation (CL_RelinkEntities), the signon
-- sequence, and clc_move construction. Platform-independent: rendering,
-- sound and input are hooks the Roblox (or test) layer wires up.

local mathlib = require("../common/mathlib")
local msg = require("../common/msg")
local proto = require("../protocol")
local qd = require("../quakedef")

local cl = {}

cl.SIGNONS = 4 -- signon messages to receive before connected

export type Baseline = {
	modelindex: number,
	frame: number,
	colormap: number,
	skin: number,
	origin: vector,
	angles: vector,
	effects: number,
}

export type ClEntity = {
	num: number,
	msgtime: number,
	forcelink: boolean,
	baseline: Baseline,
	msg_origins: { vector }, -- [1]=latest, [2]=previous
	msg_angles: { vector },
	origin: vector,
	angles: vector,
	modelindex: number, -- precache index (0 = none)
	frame: number,
	colormap: number,
	skinnum: number,
	effects: number,
	syncbase: number,
	visible: boolean, -- in the visedicts list this frame
}

export type Score = {
	name: string,
	frags: number,
	colors: number,
}

export type TempEntityEvent = {
	type: number,
	pos: vector,
	pos2: vector?, -- beams
	entity: number?, -- beams
	colorStart: number?, -- explosion2
	colorLength: number?,
}

export type Client = {
	signon: number,
	playerName: string,
	color: number,
	-- serverinfo
	maxclients: number,
	gametype: number,
	levelname: string,
	model_precache: { string }, -- [C index + 1]; [2] is the world
	sound_precache: { string },
	viewentity: number,
	cdtrack: number,
	-- time
	mtime0: number,
	mtime1: number,
	time: number,
	oldtime: number,
	movemessages: number,
	-- entity states
	entities: { [number]: ClEntity },
	num_entities: number,
	statics: { ClEntity },
	lightstyles: { [number]: string },
	scores: { Score },
	stats: { [number]: number },
	items: number,
	item_gettime: { [number]: number },
	-- view / player state from clientdata
	viewangles: vector,
	punchangle: vector,
	mvelocity0: vector,
	mvelocity1: vector,
	velocity: vector,
	onground: boolean,
	inwater: boolean,
	paused: boolean,
	intermission: number,
	completed_time: number,
	viewheight: number,
	idealpitch: number,
	faceanimtime: number,
	-- damage kicks (view.c)
	dmg_time: number,
	dmg_roll: number,
	dmg_pitch: number,
	-- palette flashes (V_ParseDamage / V_BonusFlash)
	cshift_damage_percent: number,
	cshift_damage_color: vector,
	cshift_bonus_percent: number,
	-- outbound reliable stream
	message: msg.SizeBuf,
	-- hooks
	print: (s: string) -> (),
	centerPrint: (s: string) -> (),
	onServerInfo: (c: Client) -> (),
	onDisconnect: (c: Client) -> (),
	onSound: (c: Client, entnum: number, channel: number, sample: string, pos: vector, vol: number, atten: number) -> (),
	onStopSound: (c: Client, entnum: number, channel: number) -> (),
	onStaticSound: (c: Client, pos: vector, sample: string, vol: number, atten: number) -> (),
	onParticle: (c: Client, org: vector, dir: vector, color: number, count: number) -> (),
	onTempEntity: (c: Client, te: TempEntityEvent) -> (),
	onStuffText: (c: Client, s: string) -> (),
	onSetAngle: (c: Client, angles: vector) -> (),
}

cl.STAT_HEALTH = 0
cl.STAT_FRAGS = 1
cl.STAT_WEAPON = 2
cl.STAT_AMMO = 3
cl.STAT_ARMOR = 4
cl.STAT_WEAPONFRAME = 5
cl.STAT_SHELLS = 6
cl.STAT_NAILS = 7
cl.STAT_ROCKETS = 8
cl.STAT_CELLS = 9
cl.STAT_ACTIVEWEAPON = 10
cl.STAT_TOTALSECRETS = 11
cl.STAT_TOTALMONSTERS = 12
cl.STAT_SECRETS = 13
cl.STAT_MONSTERS = 14

local function nop() end

local function newBaseline(): Baseline
	return {
		modelindex = 0,
		frame = 0,
		colormap = 0,
		skin = 0,
		origin = vector.zero,
		angles = vector.zero,
		effects = 0,
	}
end

local function newEntity(num: number): ClEntity
	return {
		num = num,
		msgtime = -1,
		forcelink = true,
		baseline = newBaseline(),
		msg_origins = { vector.zero, vector.zero },
		msg_angles = { vector.zero, vector.zero },
		origin = vector.zero,
		angles = vector.zero,
		modelindex = 0,
		frame = 0,
		colormap = 0,
		skinnum = 0,
		effects = 0,
		syncbase = 0,
		visible = false,
	}
end

function cl.new(playerName: string, color: number): Client
	local c: Client = {
		signon = 0,
		playerName = playerName,
		color = color,
		maxclients = 1,
		gametype = 0,
		levelname = "",
		model_precache = {},
		sound_precache = {},
		viewentity = 1,
		cdtrack = 0,
		mtime0 = 0,
		mtime1 = 0,
		time = 0,
		oldtime = 0,
		movemessages = 0,
		entities = {},
		num_entities = 0,
		statics = {},
		lightstyles = {},
		scores = {},
		stats = table.create(32, 0) :: { [number]: number }, -- C: int stats[MAX_CL_STATS] (zeroed)
		items = 0,
		item_gettime = {},
		viewangles = vector.zero,
		punchangle = vector.zero,
		mvelocity0 = vector.zero,
		mvelocity1 = vector.zero,
		velocity = vector.zero,
		onground = false,
		inwater = false,
		paused = false,
		intermission = 0,
		completed_time = 0,
		viewheight = proto.DEFAULT_VIEWHEIGHT,
		idealpitch = 0,
		faceanimtime = 0,
		dmg_time = 0,
		dmg_roll = 0,
		dmg_pitch = 0,
		cshift_damage_percent = 0,
		cshift_damage_color = vector.create(255, 0, 0),
		cshift_bonus_percent = 0,
		message = msg.newBuf(qd.MAX_MSGLEN),
		print = print,
		centerPrint = print,
		onServerInfo = nop :: any,
		onDisconnect = nop :: any,
		onSound = nop :: any,
		onStopSound = nop :: any,
		onStaticSound = nop :: any,
		onParticle = nop :: any,
		onTempEntity = nop :: any,
		onStuffText = nop :: any,
		onSetAngle = nop :: any,
	}
	for i = 0, 14 do
		c.stats[i] = 0
	end
	return c
end

-- CL_EntityNum
local function entityNum(c: Client, num: number): ClEntity
	if num >= qd.MAX_EDICTS then
		error(`CL_EntityNum: {num} is an invalid number`)
	end
	while c.num_entities <= num do
		c.entities[c.num_entities] = newEntity(c.num_entities)
		c.num_entities += 1
	end
	return c.entities[num]
end

--------------------------------------------------------------------------
-- signon

-- CL_SignonReply
local function signonReply(c: Client)
	-- Con_DPrintf in C: visible only with the developer cvar
	local dp = (c :: any).dprint
	if dp then
		dp(`CL_SignonReply: {c.signon}`)
	end
	if c.signon == 1 then
		msg.writeByte(c.message, proto.clc_stringcmd)
		msg.writeString(c.message, "prespawn")
	elseif c.signon == 2 then
		msg.writeByte(c.message, proto.clc_stringcmd)
		msg.writeString(c.message, `name "{c.playerName}"\n`)
		msg.writeByte(c.message, proto.clc_stringcmd)
		msg.writeString(c.message, `color {bit32.rshift(c.color, 4)} {bit32.band(c.color, 15)}\n`)
		msg.writeByte(c.message, proto.clc_stringcmd)
		msg.writeString(c.message, "spawn ")
	elseif c.signon == 3 then
		msg.writeByte(c.message, proto.clc_stringcmd)
		msg.writeString(c.message, "begin")
	end
end

--------------------------------------------------------------------------
-- parsing

-- CL_ParseStartSoundPacket
local function parseStartSound(c: Client, r: msg.Reader)
	local field_mask = msg.readByte(r)
	local volume = if bit32.band(field_mask, proto.SND_VOLUME) ~= 0
		then msg.readByte(r)
		else proto.DEFAULT_SOUND_PACKET_VOLUME
	local attenuation = if bit32.band(field_mask, proto.SND_ATTENUATION) ~= 0
		then msg.readByte(r) / 64
		else proto.DEFAULT_SOUND_PACKET_ATTENUATION
	local channel = msg.readShort(r)
	local sound_num = msg.readByte(r)
	local entnum = bit32.rshift(channel, 3)
	channel = bit32.band(channel, 7)
	local pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	c.onSound(c, entnum, channel, c.sound_precache[sound_num + 1] or "", pos, volume / 255, attenuation)
end

-- CL_ParseServerInfo
local function parseServerInfo(c: Client, r: msg.Reader)
	-- a new serverinfo starts a fresh signon sequence (level change)
	c.signon = 0
	c.movemessages = 0
	-- wipe the state
	c.entities = {}
	c.num_entities = 0
	c.statics = {}
	c.lightstyles = {}
	c.model_precache = { "" }
	c.sound_precache = { "" }
	c.intermission = 0
	c.items = 0
	-- C's CL_ClearState memsets the whole cl struct: without these the
	-- previous level's clock leaves item_gettime stamps AHEAD of the
	-- re-anchored c.time, so (time - gettime) goes negative and Luau's
	-- positive modulo pins every owned item on a pickup-flash frame
	-- forever (the "all inventory icons highlighted" playtest bug)
	c.item_gettime = {}
	-- C's memset leaves stats ZEROED, not absent: readers (view damage
	-- flash, sbar) run before the first clientdata of the new level
	c.stats = {}
	for i = 0, 31 do
		c.stats[i] = 0
	end
	c.faceanimtime = 0
	c.cshift_damage_percent = 0
	c.cshift_bonus_percent = 0
	c.dmg_time = 0
	c.punchangle = vector.zero
	c.time = 0
	c.oldtime = 0
	c.mtime0 = 0

	local version = msg.readLong(r)
	if version ~= proto.PROTOCOL_VERSION then
		error(`Server returned version {version}, not {proto.PROTOCOL_VERSION}`)
	end

	c.maxclients = msg.readByte(r)
	if c.maxclients < 1 or c.maxclients > qd.MAX_SCOREBOARD then
		error(`Bad maxclients ({c.maxclients}) from server`)
	end
	c.scores = {}
	for i = 1, c.maxclients do
		c.scores[i] = { name = "", frags = 0, colors = 0 }
	end

	c.gametype = msg.readByte(r)
	c.levelname = msg.readString(r)

	-- precache lists
	while true do
		local str = msg.readString(r)
		if str == "" then
			break
		end
		table.insert(c.model_precache, str)
	end
	while true do
		local str = msg.readString(r)
		if str == "" then
			break
		end
		table.insert(c.sound_precache, str)
	end

	c.onServerInfo(c)
end

-- CL_ParseUpdate (fast update)
local function parseUpdate(c: Client, r: msg.Reader, bits: number)
	if c.signon == cl.SIGNONS - 1 then
		-- first update is the final signon stage
		c.signon = cl.SIGNONS
		signonReply(c)
	end

	if bit32.band(bits, proto.U_MOREBITS) ~= 0 then
		bits = bit32.bor(bits, bit32.lshift(msg.readByte(r), 8))
	end

	local num
	if bit32.band(bits, proto.U_LONGENTITY) ~= 0 then
		num = msg.readShort(r)
	else
		num = msg.readByte(r)
	end

	local e = entityNum(c, num)

	local forcelink = e.msgtime ~= c.mtime1
	e.msgtime = c.mtime0

	local modnum
	if bit32.band(bits, proto.U_MODEL) ~= 0 then
		modnum = msg.readByte(r)
	else
		modnum = e.baseline.modelindex
	end
	if modnum ~= e.modelindex then
		e.modelindex = modnum
		if modnum == 0 then
			forcelink = true -- hack to make null model players work
		end
	end

	e.frame = if bit32.band(bits, proto.U_FRAME) ~= 0 then msg.readByte(r) else e.baseline.frame
	e.colormap = if bit32.band(bits, proto.U_COLORMAP) ~= 0 then msg.readByte(r) else e.baseline.colormap
	e.skinnum = if bit32.band(bits, proto.U_SKIN) ~= 0 then msg.readByte(r) else e.baseline.skin
	e.effects = if bit32.band(bits, proto.U_EFFECTS) ~= 0 then msg.readByte(r) else e.baseline.effects

	-- shift the known values for interpolation
	e.msg_origins[2] = e.msg_origins[1]
	e.msg_angles[2] = e.msg_angles[1]

	local ox = if bit32.band(bits, proto.U_ORIGIN1) ~= 0 then msg.readCoord(r) else e.baseline.origin.x
	local ax = if bit32.band(bits, proto.U_ANGLE1) ~= 0 then msg.readAngle(r) else e.baseline.angles.x
	local oy = if bit32.band(bits, proto.U_ORIGIN2) ~= 0 then msg.readCoord(r) else e.baseline.origin.y
	local ay = if bit32.band(bits, proto.U_ANGLE2) ~= 0 then msg.readAngle(r) else e.baseline.angles.y
	local oz = if bit32.band(bits, proto.U_ORIGIN3) ~= 0 then msg.readCoord(r) else e.baseline.origin.z
	local az = if bit32.band(bits, proto.U_ANGLE3) ~= 0 then msg.readAngle(r) else e.baseline.angles.z
	e.msg_origins[1] = vector.create(ox, oy, oz)
	e.msg_angles[1] = vector.create(ax, ay, az)

	if bit32.band(bits, proto.U_NOLERP) ~= 0 then
		e.forcelink = true
	end

	if forcelink then
		-- didn't have an update last message
		e.msg_origins[2] = e.msg_origins[1]
		e.origin = e.msg_origins[1]
		e.msg_angles[2] = e.msg_angles[1]
		e.angles = e.msg_angles[1]
		e.forcelink = true
	end
end

-- CL_ParseBaseline
local function parseBaseline(r: msg.Reader): Baseline
	local b = newBaseline()
	b.modelindex = msg.readByte(r)
	b.frame = msg.readByte(r)
	b.colormap = msg.readByte(r)
	b.skin = msg.readByte(r)
	local ox = msg.readCoord(r)
	local ax = msg.readAngle(r)
	local oy = msg.readCoord(r)
	local ay = msg.readAngle(r)
	local oz = msg.readCoord(r)
	local az = msg.readAngle(r)
	b.origin = vector.create(ox, oy, oz)
	b.angles = vector.create(ax, ay, az)
	return b
end

-- CL_ParseClientdata
local function parseClientdata(c: Client, r: msg.Reader, bits: number)
	if bit32.band(bits, proto.SU_VIEWHEIGHT) ~= 0 then
		c.viewheight = msg.readChar(r)
	else
		c.viewheight = proto.DEFAULT_VIEWHEIGHT
	end

	if bit32.band(bits, proto.SU_IDEALPITCH) ~= 0 then
		c.idealpitch = msg.readChar(r)
	else
		c.idealpitch = 0
	end

	c.mvelocity1 = c.mvelocity0
	local punch = { 0, 0, 0 }
	local mvel = { 0, 0, 0 }
	for i = 0, 2 do
		if bit32.band(bits, bit32.lshift(proto.SU_PUNCH1, i)) ~= 0 then
			punch[i + 1] = msg.readChar(r)
		end
		if bit32.band(bits, bit32.lshift(proto.SU_VELOCITY1, i)) ~= 0 then
			mvel[i + 1] = msg.readChar(r) * 16
		end
	end
	c.punchangle = vector.create(punch[1], punch[2], punch[3])
	c.mvelocity0 = vector.create(mvel[1], mvel[2], mvel[3])

	-- [always sent] items
	local items = msg.readLong(r)
	if c.items ~= items then
		-- set flash times
		for j = 0, 31 do
			if bit32.band(items, bit32.lshift(1, j)) ~= 0 and bit32.band(c.items, bit32.lshift(1, j)) == 0 then
				c.item_gettime[j] = c.time
			end
		end
		c.items = items
	end

	c.onground = bit32.band(bits, proto.SU_ONGROUND) ~= 0
	c.inwater = bit32.band(bits, proto.SU_INWATER) ~= 0

	c.stats[cl.STAT_WEAPONFRAME] = if bit32.band(bits, proto.SU_WEAPONFRAME) ~= 0 then msg.readByte(r) else 0
	c.stats[cl.STAT_ARMOR] = if bit32.band(bits, proto.SU_ARMOR) ~= 0 then msg.readByte(r) else 0
	c.stats[cl.STAT_WEAPON] = msg.readByte(r)
	c.stats[cl.STAT_HEALTH] = msg.readShort(r)
	c.stats[cl.STAT_AMMO] = msg.readByte(r)
	c.stats[cl.STAT_SHELLS] = msg.readByte(r)
	c.stats[cl.STAT_NAILS] = msg.readByte(r)
	c.stats[cl.STAT_ROCKETS] = msg.readByte(r)
	c.stats[cl.STAT_CELLS] = msg.readByte(r)
	c.stats[cl.STAT_ACTIVEWEAPON] = msg.readByte(r) -- standard_quake
end

-- CL_ParseStatic
local function parseStatic(c: Client, r: msg.Reader)
	local e = newEntity(-#c.statics - 1)
	e.baseline = parseBaseline(r)
	e.modelindex = e.baseline.modelindex
	e.frame = e.baseline.frame
	e.skinnum = e.baseline.skin
	e.effects = e.baseline.effects
	e.origin = e.baseline.origin
	e.angles = e.baseline.angles
	e.visible = true
	table.insert(c.statics, e)
end

-- CL_ParseTEnt
local function parseTEnt(c: Client, r: msg.Reader)
	local t = msg.readByte(r)
	local te: TempEntityEvent

	if t == proto.TE_LIGHTNING1 or t == proto.TE_LIGHTNING2 or t == proto.TE_LIGHTNING3 or t == proto.TE_BEAM then
		local entity = msg.readShort(r)
		local p1 = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
		local p2 = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
		te = { type = t, pos = p1, pos2 = p2, entity = entity }
	elseif t == proto.TE_EXPLOSION2 then
		local pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
		local colorStart = msg.readByte(r)
		local colorLength = msg.readByte(r)
		te = { type = t, pos = pos, colorStart = colorStart, colorLength = colorLength }
	else
		local pos = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
		te = { type = t, pos = pos }
	end

	c.onTempEntity(c, te)
end

-- V_ParseDamage (the view-kick part; cshifts are the renderer's business)
local function parseDamage(c: Client, r: msg.Reader)
	local armor = msg.readByte(r)
	local blood = msg.readByte(r)
	local from = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))

	local count = blood * 0.5 + armor * 0.5
	if count < 10 then
		count = 10
	end

	c.faceanimtime = c.time + 0.2 -- put sbar face into pain frame

	-- palette flash (cshifts[CSHIFT_DAMAGE])
	c.cshift_damage_percent = math.clamp(c.cshift_damage_percent + 3 * count, 0, 150)
	if armor > blood then
		c.cshift_damage_color = vector.create(200, 100, 100)
	elseif armor > 0 then
		c.cshift_damage_color = vector.create(220, 50, 50)
	else
		c.cshift_damage_color = vector.create(255, 0, 0)
	end

	-- calculate view angle kicks
	local e = c.entities[c.viewentity]
	if e then
		local dir = mathlib.normalize(from - e.origin)
		local forward, right = mathlib.angleVectors(e.angles)
		local side = vector.dot(dir, right)
		c.dmg_roll = count * side * 0.6 -- v_kickroll
		side = vector.dot(dir, forward)
		c.dmg_pitch = count * side * 0.6 -- v_kickpitch
		c.dmg_time = 0.5 -- v_kicktime
	end
end

-- CL_ParseServerMessage
function cl.parseServerMessage(c: Client, data: buffer)
	local r = msg.reader(data)
	c.onground = false -- unless the server says otherwise

	while true do
		if r.badread then
			error("CL_ParseServerMessage: Bad server message")
		end

		local cmd = msg.readByte(r)
		if cmd == -1 then
			return -- end of message
		end

		-- if the high bit of the command byte is set, it is a fast update
		if bit32.band(cmd, 128) ~= 0 then
			parseUpdate(c, r, bit32.band(cmd, 127))
			continue
		end

		if cmd == proto.svc_nop then
			-- nothing
		elseif cmd == proto.svc_time then
			c.mtime1 = c.mtime0
			c.mtime0 = msg.readFloat(r)
		elseif cmd == proto.svc_clientdata then
			parseClientdata(c, r, msg.readShort(r))
		elseif cmd == proto.svc_version then
			local version = msg.readLong(r)
			if version ~= proto.PROTOCOL_VERSION then
				error(`Server is protocol {version}`)
			end
		elseif cmd == proto.svc_disconnect then
			c.onDisconnect(c)
			return
		elseif cmd == proto.svc_print then
			c.print(msg.readString(r))
		elseif cmd == proto.svc_centerprint then
			c.centerPrint(msg.readString(r))
		elseif cmd == proto.svc_stufftext then
			c.onStuffText(c, msg.readString(r))
		elseif cmd == proto.svc_damage then
			parseDamage(c, r)
		elseif cmd == proto.svc_serverinfo then
			parseServerInfo(c, r)
		elseif cmd == proto.svc_setangle then
			c.viewangles = vector.create(msg.readAngle(r), msg.readAngle(r), msg.readAngle(r))
			c.onSetAngle(c, c.viewangles)
		elseif cmd == proto.svc_setview then
			c.viewentity = msg.readShort(r)
		elseif cmd == proto.svc_lightstyle then
			local style = msg.readByte(r)
			c.lightstyles[style] = msg.readString(r)
		elseif cmd == proto.svc_sound then
			parseStartSound(c, r)
		elseif cmd == proto.svc_stopsound then
			-- S_StopSound (i>>3 = entity, i&7 = channel)
			local i = msg.readShort(r)
			c.onStopSound(c, bit32.rshift(i, 3), bit32.band(i, 7))
		elseif cmd == proto.svc_updatename then
			local i = msg.readByte(r)
			c.scores[i + 1].name = msg.readString(r)
		elseif cmd == proto.svc_updatefrags then
			local i = msg.readByte(r)
			c.scores[i + 1].frags = msg.readShort(r)
		elseif cmd == proto.svc_updatecolors then
			local i = msg.readByte(r)
			c.scores[i + 1].colors = msg.readByte(r)
		elseif cmd == proto.svc_particle then
			local org = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
			local dir = vector.create(msg.readChar(r), msg.readChar(r), msg.readChar(r)) * (1 / 16)
			local count = msg.readByte(r)
			local color = msg.readByte(r)
			-- R_ParseParticleEffect: msgcount 255 means a rocket explosion
			if count == 255 then
				count = 1024
			end
			c.onParticle(c, org, dir, color, count)
		elseif cmd == proto.svc_spawnbaseline then
			local i = msg.readShort(r)
			entityNum(c, i).baseline = parseBaseline(r)
		elseif cmd == proto.svc_spawnstatic then
			parseStatic(c, r)
		elseif cmd == proto.svc_temp_entity then
			parseTEnt(c, r)
		elseif cmd == proto.svc_setpause then
			c.paused = msg.readByte(r) ~= 0
		elseif cmd == proto.svc_signonnum then
			local i = msg.readByte(r)
			if i <= c.signon then
				error(`Received signon {i} when at {c.signon}`)
			end
			c.signon = i
			signonReply(c)
		elseif cmd == proto.svc_killedmonster then
			c.stats[cl.STAT_MONSTERS] += 1
		elseif cmd == proto.svc_foundsecret then
			c.stats[cl.STAT_SECRETS] += 1
		elseif cmd == proto.svc_updatestat then
			local i = msg.readByte(r)
			c.stats[i] = msg.readLong(r)
		elseif cmd == proto.svc_spawnstaticsound then
			local org = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
			local sound_num = msg.readByte(r)
			local vol = msg.readByte(r)
			local atten = msg.readByte(r)
			c.onStaticSound(c, org, c.sound_precache[sound_num + 1] or "", vol, atten)
		elseif cmd == proto.svc_cdtrack then
			c.cdtrack = msg.readByte(r)
			msg.readByte(r) -- looptrack
		elseif cmd == proto.svc_intermission then
			c.intermission = 1
			c.completed_time = c.time
		elseif cmd == proto.svc_finale then
			c.intermission = 2
			c.completed_time = c.time
			c.centerPrint(msg.readString(r))
		elseif cmd == proto.svc_cutscene then
			c.intermission = 3
			c.completed_time = c.time
			c.centerPrint(msg.readString(r))
		elseif cmd == proto.svc_sellscreen then
			-- shareware upsell; ignore
		else
			error(`CL_ParseServerMessage: Illegible server message ({cmd})`)
		end
	end
end

--------------------------------------------------------------------------
-- interpolation

-- CL_LerpPoint
local function lerpPoint(c: Client): number
	local f = c.mtime0 - c.mtime1

	if f == 0 then
		c.time = c.mtime0
		return 1
	end

	if f > 0.1 then
		-- dropped packet, or start of demo
		c.mtime1 = c.mtime0 - 0.1
		f = 0.1
	end
	local frac = (c.time - c.mtime1) / f
	if frac < 0 then
		if frac < -0.01 then
			c.time = c.mtime1
		end
		frac = 0
	elseif frac > 1 then
		if frac > 1.01 then
			c.time = c.mtime0
		end
		frac = 1
	end
	return frac
end

-- CL_LerpAngle helper, module-level so relinkEntities doesn't allocate a
-- closure per entity per frame
local function lerpAngle(new: number, old: number, f: number): number
	local d = new - old
	if d > 180 then
		d -= 360
	elseif d < -180 then
		d += 360
	end
	return old + f * d
end

-- CL_RelinkEntities. modelFlags maps a precache index to the model's EF_*
-- flags (EF_ROTATE etc.), provided by the renderer's model registry.
function cl.relinkEntities(c: Client, modelFlags: (modelindex: number) -> number)
	local frac = lerpPoint(c)

	-- interpolate player info
	c.velocity = c.mvelocity1 + (c.mvelocity0 - c.mvelocity1) * frac

	local bobjrotate = mathlib.anglemod(100 * c.time)

	-- start on the entity after the world
	for i = 1, c.num_entities - 1 do
		local e = c.entities[i]
		-- C's cl_entities is a static array; ours grows lazily, so a nil
		-- slot (seen transiently during changelevel re-signon) is the
		-- representation of "never allocated" = modelindex 0 = skip
		if not e then
			continue
		end
		e.visible = false
		if e.modelindex == 0 then
			continue -- empty slot
		end

		-- if the object wasn't included in the last packet, remove it
		if e.msgtime ~= c.mtime0 then
			e.modelindex = 0
			continue
		end

		if e.forcelink then
			-- the entity was not updated in the last message, so move to
			-- the final spot
			e.origin = e.msg_origins[1]
			e.angles = e.msg_angles[1]
		else
			-- if the delta is large, assume a teleport and don't lerp
			local f = frac
			local delta = e.msg_origins[1] - e.msg_origins[2]
			if
				delta.x > 100
				or delta.x < -100
				or delta.y > 100
				or delta.y < -100
				or delta.z > 100
				or delta.z < -100
			then
				f = 1 -- assume a teleportation, not a motion
			end

			-- interpolate the origin and angles
			e.origin = e.msg_origins[2] + delta * f

			local a1 = e.msg_angles[1]
			local a2 = e.msg_angles[2]
			e.angles = vector.create(lerpAngle(a1.x, a2.x, f), lerpAngle(a1.y, a2.y, f), lerpAngle(a1.z, a2.z, f))
		end

		-- rotate binary objects locally
		if bit32.band(modelFlags(e.modelindex), 8) ~= 0 then -- EF_ROTATE
			e.angles = vector.create(e.angles.x, bobjrotate, e.angles.z)
		end

		e.forcelink = false
		e.visible = true
	end
end

--------------------------------------------------------------------------
-- outbound

-- CL_SendMove: returns the clc_move packet to send unreliably, or nil for
-- the first couple of messages (which may contain leftover inputs)
function cl.buildMove(
	c: Client,
	forwardmove: number,
	sidemove: number,
	upmove: number,
	attack: boolean,
	jump: boolean,
	impulse: number
): buffer?
	local buf = msg.newBuf(128)

	msg.writeByte(buf, proto.clc_move)
	msg.writeFloat(buf, c.mtime0) -- so server can get ping times
	msg.writeAngle(buf, c.viewangles.x)
	msg.writeAngle(buf, c.viewangles.y)
	msg.writeAngle(buf, c.viewangles.z)
	msg.writeShort(buf, forwardmove)
	msg.writeShort(buf, sidemove)
	msg.writeShort(buf, upmove)

	local bits = 0
	if attack then
		bits = bit32.bor(bits, 1)
	end
	if jump then
		bits = bit32.bor(bits, 2)
	end
	msg.writeByte(buf, bits)
	msg.writeByte(buf, impulse)

	-- always dump the first two messages, because they may contain leftover
	-- inputs from the last level
	c.movemessages += 1
	if c.movemessages <= 2 then
		return nil
	end

	return msg.snapshot(buf)
end

-- take and clear the pending reliable stream (send via reliable transport)
function cl.takeReliable(c: Client): buffer?
	if c.message.cursize == 0 then
		return nil
	end
	local out = msg.snapshot(c.message)
	msg.clear(c.message)
	return out
end

return cl
