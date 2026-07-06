--!strict
--!optimize 2
-- Server state and messaging — port of the sv_main.c core: server_t /
-- server_static_t / client_t state, precache tables, event messages
-- (SV_StartSound, SV_StartParticle), PVS-culled entity updates, clientdata,
-- and baselines. The frame loop lives in host.luau; physics in sv_phys.luau.

local vfslib = require("../common/vfs")
local cvarlib = require("../common/cvar")
local msg = require("../common/msg")
local bsp = require("../bsp/bsp")
local modelslib = require("../models/models")
local defs = require("../progs/defs")
local progslib = require("../progs/progs")
local vmlib = require("../progs/vm")
local proto = require("../protocol")
local qd = require("../quakedef")
local world = require("./world")

local sv = {}

local ent = defs.ent
local glob = defs.glob

sv.ss_loading = 1
sv.ss_active = 2

local ZERO_BASELINE = {
	origin = vector.zero,
	angles = vector.zero,
	modelindex = 0,
	frame = 0,
	colormap = 0,
	skin = 0,
	effects = 0,
}

export type UserCmd = {
	forwardmove: number,
	sidemove: number,
	upmove: number,
}

export type Baseline = {
	origin: vector,
	angles: vector,
	modelindex: number,
	frame: number,
	colormap: number,
	skin: number,
	effects: number,
}

export type Client = {
	active: boolean,
	spawned: boolean,
	sendsignon: boolean,
	dropasap: boolean,
	name: string,
	colors: number,
	edict: vmlib.Edict,
	message: msg.SizeBuf, -- reliable stream
	cmd: UserCmd,
	wishdir: vector,
	spawn_parms: { number }, -- [16]
	old_frags: number,
	num: number, -- 1-based client number (edict num == num)
	-- transport hooks (wired by the platform layer)
	sendUnreliable: (data: buffer) -> boolean,
	sendReliable: (data: buffer) -> boolean,
	canSendReliable: () -> boolean,
	-- inbound queue of raw clc messages, drained each frame
	inbox: { buffer },
	last_message: number,
	privileged: boolean,
}

export type Server = {
	-- statics
	fs: vfslib.Vfs,
	cvars: cvarlib.Cvars,
	maxclients: number,
	clients: { Client },
	serverflags: number,
	changelevelIssued: boolean,
	print: (s: string) -> (),
	dprint: (s: string) -> (),
	-- per-level
	active: boolean,
	paused: boolean,
	loadgame: boolean,
	state: number,
	name: string,
	modelname: string,
	time: number,
	frametime: number, -- host_frametime for the current tick
	realtime: number,
	lastcheck: number,
	lastchecktime: number,
	checkpvs: buffer?,
	vm: vmlib.VM,
	progs: progslib.Progs,
	reg: modelslib.Registry,
	worldmodel: bsp.Model,
	world: world.World,
	models: { modelslib.Model? }, -- [C index + 1]
	model_precache: { string },
	sound_precache: { string },
	brushModels: { [number]: bsp.Model },
	lightstyles: { [number]: string },
	datagram: msg.SizeBuf,
	reliable_datagram: msg.SizeBuf,
	signon: msg.SizeBuf,
	-- rand() state (msvc LCG for determinism)
	randSeed: number,
	-- wired late to break module cycles
	setIdealPitch: ((svr: Server, player: vmlib.Edict) -> ())?,
	-- level change requested by QC (changelevel builtin)
	changelevelTo: string?,
	-- platform hook: called when a client is dropped
	onDropClient: ((svr: Server, client: Client) -> ())?,
}

--------------------------------------------------------------------------
-- rand(): the msvcrt LCG, deterministic across platforms

function sv.rand(svr: Server): number
	-- seed = seed * 214013 + 2531011 (mod 2^32); return (seed >> 16) & 0x7fff
	local seed = svr.randSeed
	local lo = seed % 65536
	local hi = math.floor(seed / 65536)
	seed = ((lo * 214013) + (hi * 214013 % 65536) * 65536 + 2531011) % 4294967296
	svr.randSeed = seed
	return bit32.band(bit32.rshift(seed, 16), 0x7fff)
end

--------------------------------------------------------------------------
-- construction

function sv.new(fs: vfslib.Vfs, maxclients: number): Server
	local svr = {} :: Server
	svr.fs = fs
	svr.cvars = cvarlib.new()
	svr.maxclients = maxclients
	svr.clients = {}
	svr.serverflags = 0
	svr.changelevelIssued = false
	svr.print = print
	svr.dprint = function(_s: string) end
	svr.active = false
	svr.paused = false
	svr.loadgame = false
	svr.state = 0
	svr.name = ""
	svr.modelname = ""
	svr.time = 0
	svr.frametime = 0
	svr.realtime = 0
	svr.lastcheck = 1
	svr.lastchecktime = 0
	svr.models = {}
	svr.model_precache = {}
	svr.sound_precache = {}
	svr.brushModels = {}
	svr.lightstyles = {}
	svr.datagram = msg.newBuf(qd.MAX_DATAGRAM)
	svr.reliable_datagram = msg.newBuf(qd.MAX_DATAGRAM)
	svr.signon = msg.newBuf(qd.MAX_MSGLEN)
	svr.randSeed = 12345
	svr.changelevelTo = nil
	return svr
end

--------------------------------------------------------------------------
-- precache lookups

-- SV_ModelIndex: returns the C precache index
function sv.modelIndex(svr: Server, name: string): number
	if name == "" then
		return 0
	end
	for i, n in svr.model_precache do
		if n == name then
			return i - 1
		end
	end
	error(`SV_ModelIndex: model {name} not precached`)
end

function sv.soundIndex(svr: Server, sample: string): number?
	-- find precache number for sound (index 1..): sound 0 is the null string
	for i = 2, #svr.sound_precache do
		if svr.sound_precache[i] == sample then
			return i - 1
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- event messages

-- SV_StartParticle
function sv.startParticle(svr: Server, org: vector, dir: vector, color: number, count: number)
	local dg = svr.datagram
	if dg.cursize > qd.MAX_DATAGRAM - 16 then
		return
	end
	msg.writeByte(dg, proto.svc_particle)
	msg.writeCoord(dg, org.x)
	msg.writeCoord(dg, org.y)
	msg.writeCoord(dg, org.z)
	for _, comp in { dir.x, dir.y, dir.z } do
		local v = math.clamp(comp * 16, -128, 127)
		msg.writeChar(dg, if v >= 0 then math.floor(v) else -math.floor(-v))
	end
	msg.writeByte(dg, count)
	msg.writeByte(dg, color)
end

-- SV_StartSound
function sv.startSound(svr: Server, entity: vmlib.Edict, channel: number, sample: string, volume: number, attenuation: number)
	if volume < 0 or volume > 255 then
		error(`SV_StartSound: volume = {volume}`)
	end
	if attenuation < 0 or attenuation > 4 then
		error(`SV_StartSound: attenuation = {attenuation}`)
	end
	if channel < 0 or channel > 7 then
		error(`SV_StartSound: channel = {channel}`)
	end

	local dg = svr.datagram
	if dg.cursize > qd.MAX_DATAGRAM - 16 then
		return
	end

	local sound_num = sv.soundIndex(svr, sample)
	if not sound_num then
		svr.print(`SV_StartSound: {sample} not precacheed`)
		return
	end

	local chan = bit32.bor(bit32.lshift(entity.num, 3), channel)

	local field_mask = 0
	if volume ~= proto.DEFAULT_SOUND_PACKET_VOLUME then
		field_mask = bit32.bor(field_mask, proto.SND_VOLUME)
	end
	if attenuation ~= proto.DEFAULT_SOUND_PACKET_ATTENUATION then
		field_mask = bit32.bor(field_mask, proto.SND_ATTENUATION)
	end

	msg.writeByte(dg, proto.svc_sound)
	msg.writeByte(dg, field_mask)
	if bit32.band(field_mask, proto.SND_VOLUME) ~= 0 then
		msg.writeByte(dg, volume)
	end
	if bit32.band(field_mask, proto.SND_ATTENUATION) ~= 0 then
		msg.writeByte(dg, attenuation * 64)
	end
	msg.writeShort(dg, chan)
	msg.writeByte(dg, sound_num)
	local origin = vmlib.edVector(entity, ent.origin)
	local mins = vmlib.edVector(entity, ent.mins)
	local maxs = vmlib.edVector(entity, ent.maxs)
	local center = origin + (mins + maxs) * 0.5
	msg.writeCoord(dg, center.x)
	msg.writeCoord(dg, center.y)
	msg.writeCoord(dg, center.z)
end

-- SV_BroadcastPrintf
function sv.broadcastPrint(svr: Server, s: string)
	for _, client in svr.clients do
		if client.active and client.spawned then
			msg.writeByte(client.message, proto.svc_print)
			msg.writeString(client.message, s)
		end
	end
	svr.print(s)
end

-- Host_ClientCommands (stufftext to one client)
function sv.clientCommands(svr: Server, client: Client, s: string)
	msg.writeByte(client.message, proto.svc_stufftext)
	msg.writeString(client.message, s)
end

--------------------------------------------------------------------------
-- fat PVS

local function addToFatPVS(svr: Server, org: vector, child: number, fatpvs: buffer, fatbytes: number)
	local data = svr.worldmodel.brush
	while true do
		-- if this is a leaf, accumulate the pvs bits
		if child < 0 then
			local leaf = data.leafs[-child]
			if leaf.contents ~= qd.CONTENTS_SOLID then
				local pvs = bsp.leafPVS(leaf, svr.worldmodel)
				-- fatbytes rounds up past the pvs row size (C reads stale
				-- static-buffer bytes there; zero is the sane equivalent)
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
			-- go down both
			addToFatPVS(svr, org, node.children[1], fatpvs, fatbytes)
			child = node.children[2]
		end
	end
end

-- SV_FatPVS
function sv.fatPVS(svr: Server, org: vector): buffer
	local fatbytes = bit32.rshift(svr.worldmodel.numleafs + 31, 3)
	local fatpvs = buffer.create(fatbytes)
	addToFatPVS(svr, org, 0, fatpvs, fatbytes)
	return fatpvs
end

--------------------------------------------------------------------------
-- frame updates

-- SV_WriteEntitiesToClient
function sv.writeEntitiesToClient(svr: Server, clent: vmlib.Edict, out: msg.SizeBuf)
	local vm = svr.vm

	-- find the client's PVS
	local org = vmlib.edVector(clent, ent.origin) + vmlib.edVector(clent, ent.view_ofs)
	local pvs = sv.fatPVS(svr, org)

	-- send over all entities (except the client) that touch the pvs
	for e = 1, vm.num_edicts - 1 do
		local edict = vm.edicts[e + 1]
		if edict.free then
			continue
		end

		if edict ~= clent then -- clent is ALWAYS sent
			-- ignore ents without visible models
			if vmlib.edFloat(edict, ent.modelindex) == 0 or vmlib.edString(vm, edict, ent.model) == "" then
				continue
			end

			local visible = false
			for i = 1, edict.num_leafs do
				local ln = edict.leafnums[i]
				if bit32.band(buffer.readu8(pvs, bit32.rshift(ln, 3)), bit32.lshift(1, bit32.band(ln, 7))) ~= 0 then
					visible = true
					break
				end
			end
			if not visible then
				continue
			end
		end

		if out.maxsize - out.cursize < 16 then
			svr.print("packet overflow")
			return
		end

		-- send an update (entities spawned after SV_CreateBaseline have no
		-- baseline; C uses the embedded zeroed struct)
		local baseline = (edict.baseline or ZERO_BASELINE) :: Baseline
		local bits = 0

		local origin = vmlib.edVector(edict, ent.origin)
		local angles = vmlib.edVector(edict, ent.angles)

		local function differs(a: number, b: number): boolean
			local miss = a - b
			return miss < -0.1 or miss > 0.1
		end
		if differs(origin.x, baseline.origin.x) then
			bits = bit32.bor(bits, proto.U_ORIGIN1)
		end
		if differs(origin.y, baseline.origin.y) then
			bits = bit32.bor(bits, proto.U_ORIGIN2)
		end
		if differs(origin.z, baseline.origin.z) then
			bits = bit32.bor(bits, proto.U_ORIGIN3)
		end

		if angles.x ~= baseline.angles.x then
			bits = bit32.bor(bits, proto.U_ANGLE1)
		end
		if angles.y ~= baseline.angles.y then
			bits = bit32.bor(bits, proto.U_ANGLE2)
		end
		if angles.z ~= baseline.angles.z then
			bits = bit32.bor(bits, proto.U_ANGLE3)
		end

		if vmlib.edFloat(edict, ent.movetype) == qd.MOVETYPE_STEP then
			bits = bit32.bor(bits, proto.U_NOLERP) -- don't mess up the step animation
		end

		if baseline.colormap ~= vmlib.edFloat(edict, ent.colormap) then
			bits = bit32.bor(bits, proto.U_COLORMAP)
		end
		if baseline.skin ~= vmlib.edFloat(edict, ent.skin) then
			bits = bit32.bor(bits, proto.U_SKIN)
		end
		if baseline.frame ~= vmlib.edFloat(edict, ent.frame) then
			bits = bit32.bor(bits, proto.U_FRAME)
		end
		if baseline.effects ~= vmlib.edFloat(edict, ent.effects) then
			bits = bit32.bor(bits, proto.U_EFFECTS)
		end
		if baseline.modelindex ~= vmlib.edFloat(edict, ent.modelindex) then
			bits = bit32.bor(bits, proto.U_MODEL)
		end

		if e >= 256 then
			bits = bit32.bor(bits, proto.U_LONGENTITY)
		end
		if bits >= 256 then
			bits = bit32.bor(bits, proto.U_MOREBITS)
		end

		-- write the message
		msg.writeByte(out, bit32.bor(bit32.band(bits, 0xff), proto.U_SIGNAL))
		if bit32.band(bits, proto.U_MOREBITS) ~= 0 then
			msg.writeByte(out, bit32.rshift(bits, 8))
		end
		if bit32.band(bits, proto.U_LONGENTITY) ~= 0 then
			msg.writeShort(out, e)
		else
			msg.writeByte(out, e)
		end

		if bit32.band(bits, proto.U_MODEL) ~= 0 then
			msg.writeByte(out, vmlib.edFloat(edict, ent.modelindex))
		end
		if bit32.band(bits, proto.U_FRAME) ~= 0 then
			msg.writeByte(out, vmlib.edFloat(edict, ent.frame))
		end
		if bit32.band(bits, proto.U_COLORMAP) ~= 0 then
			msg.writeByte(out, vmlib.edFloat(edict, ent.colormap))
		end
		if bit32.band(bits, proto.U_SKIN) ~= 0 then
			msg.writeByte(out, vmlib.edFloat(edict, ent.skin))
		end
		if bit32.band(bits, proto.U_EFFECTS) ~= 0 then
			msg.writeByte(out, vmlib.edFloat(edict, ent.effects))
		end
		if bit32.band(bits, proto.U_ORIGIN1) ~= 0 then
			msg.writeCoord(out, origin.x)
		end
		if bit32.band(bits, proto.U_ANGLE1) ~= 0 then
			msg.writeAngle(out, angles.x)
		end
		if bit32.band(bits, proto.U_ORIGIN2) ~= 0 then
			msg.writeCoord(out, origin.y)
		end
		if bit32.band(bits, proto.U_ANGLE2) ~= 0 then
			msg.writeAngle(out, angles.y)
		end
		if bit32.band(bits, proto.U_ORIGIN3) ~= 0 then
			msg.writeCoord(out, origin.z)
		end
		if bit32.band(bits, proto.U_ANGLE3) ~= 0 then
			msg.writeAngle(out, angles.z)
		end
	end
end

-- SV_CleanupEnts
function sv.cleanupEnts(svr: Server)
	local vm = svr.vm
	for e = 1, vm.num_edicts - 1 do
		local edict = vm.edicts[e + 1]
		local effects = vmlib.edFloat(edict, ent.effects)
		vmlib.edSetFloat(edict, ent.effects, bit32.band(effects, bit32.bnot(qd.EF_MUZZLEFLASH)))
	end
end

-- SV_WriteClientdataToMessage
function sv.writeClientdataToMessage(svr: Server, player: vmlib.Edict, out: msg.SizeBuf)
	local vm = svr.vm

	-- send a damage message
	local dmg_take = vmlib.edFloat(player, ent.dmg_take)
	local dmg_save = vmlib.edFloat(player, ent.dmg_save)
	if dmg_take ~= 0 or dmg_save ~= 0 then
		local other = vmlib.edictNum(vm, vmlib.edInt(player, ent.dmg_inflictor))
		msg.writeByte(out, proto.svc_damage)
		msg.writeByte(out, dmg_save)
		msg.writeByte(out, dmg_take)
		local center = vmlib.edVector(other, ent.origin)
			+ (vmlib.edVector(other, ent.mins) + vmlib.edVector(other, ent.maxs)) * 0.5
		msg.writeCoord(out, center.x)
		msg.writeCoord(out, center.y)
		msg.writeCoord(out, center.z)

		vmlib.edSetFloat(player, ent.dmg_take, 0)
		vmlib.edSetFloat(player, ent.dmg_save, 0)
	end

	-- how much to look up / down ideally
	local setIdealPitch = svr.setIdealPitch
	if setIdealPitch then
		setIdealPitch(svr, player)
	end

	-- a fixangle might get lost in a dropped packet. Oh well.
	if vmlib.edFloat(player, ent.fixangle) ~= 0 then
		msg.writeByte(out, proto.svc_setangle)
		local angles = vmlib.edVector(player, ent.angles)
		msg.writeAngle(out, angles.x)
		msg.writeAngle(out, angles.y)
		msg.writeAngle(out, angles.z)
		vmlib.edSetFloat(player, ent.fixangle, 0)
	end

	local bits = 0
	local view_ofs_z = vmlib.edFloat(player, ent.view_ofs + 2)
	if view_ofs_z ~= proto.DEFAULT_VIEWHEIGHT then
		bits = bit32.bor(bits, proto.SU_VIEWHEIGHT)
	end
	local idealpitch = vmlib.edFloat(player, ent.idealpitch)
	if idealpitch ~= 0 then
		bits = bit32.bor(bits, proto.SU_IDEALPITCH)
	end

	-- stuff the sigil bits into the high bits of items for sbar, or else
	-- mix in items2
	local items
	local items2def = vm.progs.fielddefsByName["items2"]
	local itemsBase = vmlib.edFloat(player, ent.items)
	if items2def then
		items = bit32.bor(itemsBase, bit32.lshift(vmlib.edFloat(player, items2def.ofs), 23))
	else
		local serverflags = vmlib.globalFloat(vm, glob.serverflags)
		items = bit32.bor(itemsBase, bit32.lshift(bit32.band(serverflags, 0xf), 28))
	end

	bits = bit32.bor(bits, proto.SU_ITEMS)

	if bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_ONGROUND) ~= 0 then
		bits = bit32.bor(bits, proto.SU_ONGROUND)
	end
	if vmlib.edFloat(player, ent.waterlevel) >= 2 then
		bits = bit32.bor(bits, proto.SU_INWATER)
	end

	local punch = vmlib.edVector(player, ent.punchangle)
	local vel = vmlib.edVector(player, ent.velocity)
	local punchComps = { punch.x, punch.y, punch.z }
	local velComps = { vel.x, vel.y, vel.z }
	for i = 0, 2 do
		if punchComps[i + 1] ~= 0 then
			bits = bit32.bor(bits, bit32.lshift(proto.SU_PUNCH1, i))
		end
		if velComps[i + 1] ~= 0 then
			bits = bit32.bor(bits, bit32.lshift(proto.SU_VELOCITY1, i))
		end
	end

	local weaponframe = vmlib.edFloat(player, ent.weaponframe)
	if weaponframe ~= 0 then
		bits = bit32.bor(bits, proto.SU_WEAPONFRAME)
	end
	local armorvalue = vmlib.edFloat(player, ent.armorvalue)
	if armorvalue ~= 0 then
		bits = bit32.bor(bits, proto.SU_ARMOR)
	end
	bits = bit32.bor(bits, proto.SU_WEAPON)

	-- send the data
	msg.writeByte(out, proto.svc_clientdata)
	msg.writeShort(out, bits)

	if bit32.band(bits, proto.SU_VIEWHEIGHT) ~= 0 then
		msg.writeChar(out, view_ofs_z)
	end
	if bit32.band(bits, proto.SU_IDEALPITCH) ~= 0 then
		msg.writeChar(out, idealpitch)
	end
	for i = 0, 2 do
		if bit32.band(bits, bit32.lshift(proto.SU_PUNCH1, i)) ~= 0 then
			msg.writeChar(out, punchComps[i + 1])
		end
		if bit32.band(bits, bit32.lshift(proto.SU_VELOCITY1, i)) ~= 0 then
			msg.writeChar(out, velComps[i + 1] / 16)
		end
	end

	msg.writeLong(out, items)

	if bit32.band(bits, proto.SU_WEAPONFRAME) ~= 0 then
		msg.writeByte(out, weaponframe)
	end
	if bit32.band(bits, proto.SU_ARMOR) ~= 0 then
		msg.writeByte(out, armorvalue)
	end
	msg.writeByte(out, sv.modelIndex(svr, vmlib.edString(vm, player, ent.weaponmodel)))

	msg.writeShort(out, vmlib.edFloat(player, ent.health))
	msg.writeByte(out, vmlib.edFloat(player, ent.currentammo))
	msg.writeByte(out, vmlib.edFloat(player, ent.ammo_shells))
	msg.writeByte(out, vmlib.edFloat(player, ent.ammo_nails))
	msg.writeByte(out, vmlib.edFloat(player, ent.ammo_rockets))
	msg.writeByte(out, vmlib.edFloat(player, ent.ammo_cells))
	msg.writeByte(out, vmlib.edFloat(player, ent.weapon)) -- standard_quake
end

--------------------------------------------------------------------------
-- baselines / serverinfo

-- SV_CreateBaseline
function sv.createBaseline(svr: Server)
	local vm = svr.vm
	for entnum = 0, vm.num_edicts - 1 do
		local svent = vm.edicts[entnum + 1]
		if svent.free then
			continue
		end
		if entnum > svr.maxclients and vmlib.edFloat(svent, ent.modelindex) == 0 then
			continue
		end

		-- create entity baseline
		local baseline: Baseline = {
			origin = vmlib.edVector(svent, ent.origin),
			angles = vmlib.edVector(svent, ent.angles),
			frame = vmlib.edFloat(svent, ent.frame),
			skin = vmlib.edFloat(svent, ent.skin),
			colormap = 0,
			modelindex = 0,
			effects = 0,
		}
		if entnum > 0 and entnum <= svr.maxclients then
			baseline.colormap = entnum
			baseline.modelindex = sv.modelIndex(svr, "progs/player.mdl")
		else
			baseline.colormap = 0
			baseline.modelindex = sv.modelIndex(svr, vmlib.edString(vm, svent, ent.model))
		end
		svent.baseline = baseline

		-- add to the message
		local sg = svr.signon
		msg.writeByte(sg, proto.svc_spawnbaseline)
		msg.writeShort(sg, entnum)
		msg.writeByte(sg, baseline.modelindex)
		msg.writeByte(sg, baseline.frame)
		msg.writeByte(sg, baseline.colormap)
		msg.writeByte(sg, baseline.skin)
		msg.writeCoord(sg, baseline.origin.x)
		msg.writeAngle(sg, baseline.angles.x)
		msg.writeCoord(sg, baseline.origin.y)
		msg.writeAngle(sg, baseline.angles.y)
		msg.writeCoord(sg, baseline.origin.z)
		msg.writeAngle(sg, baseline.angles.z)
	end
end

-- SV_SendServerinfo
function sv.sendServerinfo(svr: Server, client: Client)
	local vm = svr.vm
	local m = client.message

	msg.writeByte(m, proto.svc_print)
	msg.writeString(m, `\2\nVERSION 1.09 SERVER ({vm.progs.crc} CRC)`)

	msg.writeByte(m, proto.svc_serverinfo)
	msg.writeLong(m, proto.PROTOCOL_VERSION)
	msg.writeByte(m, svr.maxclients)

	local cv = svr.cvars
	if cvarlib.value(cv, "coop") == 0 and cvarlib.value(cv, "deathmatch") ~= 0 then
		msg.writeByte(m, proto.GAME_DEATHMATCH)
	else
		msg.writeByte(m, proto.GAME_COOP)
	end

	local worldEd = vmlib.edictNum(vm, 0)
	msg.writeString(m, vmlib.edString(vm, worldEd, ent.message))

	for i = 2, #svr.model_precache do
		msg.writeString(m, svr.model_precache[i])
	end
	msg.writeByte(m, 0)
	for i = 2, #svr.sound_precache do
		msg.writeString(m, svr.sound_precache[i])
	end
	msg.writeByte(m, 0)

	-- send music
	msg.writeByte(m, proto.svc_cdtrack)
	msg.writeByte(m, vmlib.edFloat(worldEd, ent.sounds))
	msg.writeByte(m, vmlib.edFloat(worldEd, ent.sounds))

	-- set view
	msg.writeByte(m, proto.svc_setview)
	msg.writeShort(m, client.edict.num)

	msg.writeByte(m, proto.svc_signonnum)
	msg.writeByte(m, 1)

	client.sendsignon = true
	client.spawned = false -- need prespawn, spawn, etc
end

--------------------------------------------------------------------------
-- client lifecycle

function sv.newClient(num: number): Client
	return {
		active = false,
		spawned = false,
		sendsignon = false,
		dropasap = false,
		-- C leaves never-connected slots at "" (hunk-zeroed); "unconnected"
		-- is stamped by SV_ConnectClient only. Sbar_SortFrags skips empty
		-- names, so pre-stamping every slot made the DM overlay list 15
		-- phantom "unconnected" rows.
		name = "",
		colors = 0,
		edict = nil :: any,
		message = msg.newBuf(qd.MAX_MSGLEN, true),
		cmd = { forwardmove = 0, sidemove = 0, upmove = 0 },
		wishdir = vector.zero,
		spawn_parms = table.create(proto.NUM_SPAWN_PARMS, 0),
		old_frags = 0,
		num = num,
		sendUnreliable = function(_data: buffer)
			return true
		end,
		sendReliable = function(_data: buffer)
			return true
		end,
		canSendReliable = function()
			return true
		end,
		inbox = {},
		last_message = 0,
		privileged = false,
	}
end

-- SV_ConnectClient
function sv.connectClient(svr: Server, clientnum: number, preserveParms: boolean?)
	local cc = svr.clients[clientnum] :: any
	if cc then
		cc.connecttime = svr.time -- Host_Status_f's session clock
	end
	local client = svr.clients[clientnum]
	local vm = svr.vm

	local edictnum = clientnum
	local edict = vmlib.edictNum(vm, edictnum)

	client.name = "unconnected"
	client.active = true
	client.spawned = false
	client.edict = edict
	msg.clear(client.message)
	table.clear(client.inbox)
	client.cmd = { forwardmove = 0, sidemove = 0, upmove = 0 }
	client.old_frags = 0

	if not svr.loadgame and not preserveParms then
		-- call the progs to get default spawn parms for the new client
		-- (changelevel reconnects keep the SetChangeParms-saved parms —
		-- in C the connection persists and never re-enters this path)
		vmlib.exec(vm, vmlib.globalInt(vm, glob.SetNewParms))
		for i = 0, proto.NUM_SPAWN_PARMS - 1 do
			client.spawn_parms[i + 1] = vmlib.globalFloat(vm, glob.parm1 + i)
		end
	end

	sv.sendServerinfo(svr, client)
end

-- SV_DropClient
function sv.dropClient(svr: Server, client: Client, crash: boolean)
	local vm = svr.vm
	if not crash and client.active then
		-- call the prog function for removing a client; this will set the
		-- body to a dead frame, among other things
		local saveSelf = vmlib.globalInt(vm, glob.self)
		buffer.writei32(vm.globals, glob.self * 4, client.edict.num)
		vmlib.exec(vm, vmlib.globalInt(vm, glob.ClientDisconnect))
		buffer.writei32(vm.globals, glob.self * 4, saveSelf)
	end

	-- free the client (the body stays around)
	client.active = false
	client.name = ""
	client.old_frags = -999999
	msg.clear(client.message)
	table.clear(client.inbox)

	-- send notification to all clients
	for _, cl in svr.clients do
		if not cl.active then
			continue
		end
		msg.writeByte(cl.message, proto.svc_updatename)
		msg.writeByte(cl.message, client.num - 1)
		msg.writeString(cl.message, "")
		msg.writeByte(cl.message, proto.svc_updatefrags)
		msg.writeByte(cl.message, client.num - 1)
		msg.writeShort(cl.message, 0)
		msg.writeByte(cl.message, proto.svc_updatecolors)
		msg.writeByte(cl.message, client.num - 1)
		msg.writeByte(cl.message, 0)
	end

	local onDrop = svr.onDropClient
	if onDrop then
		onDrop(svr, client)
	end
end

--------------------------------------------------------------------------
-- sending

-- SV_SendClientDatagram
local function sendClientDatagram(svr: Server, client: Client): boolean
	local out = msg.newBuf(qd.MAX_DATAGRAM)

	msg.writeByte(out, proto.svc_time)
	msg.writeFloat(out, svr.time)

	-- add the client specific data to the datagram
	sv.writeClientdataToMessage(svr, client.edict, out)
	sv.writeEntitiesToClient(svr, client.edict, out)

	-- copy the server datagram if there is space
	if out.cursize + svr.datagram.cursize < out.maxsize then
		msg.writeBuf(out, svr.datagram.data, svr.datagram.cursize)
	end

	-- send the datagram
	if not client.sendUnreliable(msg.snapshot(out)) then
		sv.dropClient(svr, client, true)
		return false
	end
	return true
end

-- SV_UpdateToReliableMessages
local function updateToReliableMessages(svr: Server)
	local vm = svr.vm

	-- check for changes to be sent over the reliable streams
	for i, hc in svr.clients do
		local frags = if hc.edict then vmlib.edFloat(hc.edict, ent.frags) else 0
		if hc.old_frags ~= frags then
			for _, client in svr.clients do
				if not client.active then
					continue
				end
				msg.writeByte(client.message, proto.svc_updatefrags)
				msg.writeByte(client.message, i - 1)
				msg.writeShort(client.message, frags)
			end
			hc.old_frags = frags
		end
	end

	for _, client in svr.clients do
		if client.active then
			msg.writeBuf(client.message, svr.reliable_datagram.data, svr.reliable_datagram.cursize)
		end
	end
	msg.clear(svr.reliable_datagram)
end

-- SV_SendClientMessages
function sv.sendClientMessages(svr: Server)
	-- update frags, names, etc
	updateToReliableMessages(svr)

	-- build individual updates
	for _, client in svr.clients do
		if not client.active then
			continue
		end

		if client.spawned then
			if not sendClientDatagram(svr, client) then
				continue
			end
		else
			-- the player isn't totally in the game yet; send small keepalive
			-- messages if too much time has passed, and a full message when
			-- the next signon stage has been requested
			if not client.sendsignon then
				if svr.realtime - client.last_message > 5 then
					local nop = msg.newBuf(4)
					msg.writeChar(nop, proto.svc_nop)
					client.sendUnreliable(msg.snapshot(nop))
					client.last_message = svr.realtime
				end
				continue -- don't send out non-signon messages
			end
		end

		if client.message.overflowed then
			sv.dropClient(svr, client, true)
			client.message.overflowed = false
			continue
		end

		if client.message.cursize > 0 or client.dropasap then
			if not client.canSendReliable() then
				continue
			end
			if client.dropasap then
				sv.dropClient(svr, client, false) -- went to another level
			else
				if not client.sendReliable(msg.snapshot(client.message)) then
					sv.dropClient(svr, client, true)
				end
				msg.clear(client.message)
				client.last_message = svr.realtime
				client.sendsignon = false
			end
		end
	end

	-- clear muzzle flashes
	sv.cleanupEnts(svr)
end

return sv
