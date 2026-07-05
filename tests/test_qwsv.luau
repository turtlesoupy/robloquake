--!strict
-- QW server boot: qwprogs on e1m1, client spawn, movement through pmove,
-- weapons via QC think chain
local t = require("./testutil")
local fs = require("@lune/fs")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")

local fsys = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(fsys, qwprogs)
qwsv.spawnServer(svr, "e1m1")
t.check(svr.active, "qw server spawned e1m1")

local vm = svr.vm
local ent = svr.qdefs.ent

-- deathmatch world: monsters inhibited/failed, items spawned
local shells, monsters = 0, 0
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free then
		local cn = vmlib.edString(vm, e, ent.classname)
		if cn == "item_shells" then
			shells += 1
		elseif cn:sub(1, 8) == "monster_" then
			monsters += 1
		end
	end
end
t.check(shells > 0, `item_shells spawned ({shells})`)
t.eq(monsters, 0, "no monsters in qw deathmatch")

-- connect and spawn a player
qwsv.connectClient(svr, 1, { name = "ranger" })
local client = svr.clients[1]
t.check(client.spawned, "client spawned")
local player = client.edict
t.eq(vmlib.edString(vm, player, ent.classname), "player", "player classname")
t.eq(vmlib.edFloat(player, ent.health), 100, "health 100")
local org0 = vmlib.edVector(player, ent.origin)
t.check(vector.magnitude(org0) > 0, `spawned somewhere ({org0})`)

-- run movement: forward along the spawn point's own facing
local spawnYaw = vmlib.edVector(player, ent.angles).y
for i = 1, 40 do
	qwsv.executeCmd(svr, client, {
		angles = vector.create(0, spawnYaw, 0),
		forwardmove = 400,
		sidemove = 0,
		upmove = 0,
		buttons = 0,
		msec = 50,
	})
	qwsv.frame(svr, 0.05)
end
local org1 = vmlib.edVector(player, ent.origin)
local moved = vector.magnitude(org1 - org0)
t.check(moved > 100, `player moved {math.floor(moved)} units via pmove`)

-- stand still until settled, then the player is grounded or swimming
for i = 1, 20 do
	qwsv.executeCmd(svr, client, {
		angles = vector.create(0, spawnYaw, 0),
		forwardmove = 0,
		sidemove = 0,
		upmove = 0,
		buttons = 0,
		msec = 50,
	})
	qwsv.frame(svr, 0.05)
end
local grounded = bit32.band(vmlib.edFloat(player, ent.flags), 512) ~= 0
local wl = vmlib.edFloat(player, ent.waterlevel)
t.check(grounded or wl > 0, `settled (onground={tostring(grounded)} waterlevel={wl})`)

-- fire the shotgun: button0 held one cmd
local shellsBefore = vmlib.edFloat(player, ent.ammo_shells)
qwsv.executeCmd(svr, client, {
	angles = vector.create(0, spawnYaw, 0),
	forwardmove = 0,
	sidemove = 0,
	upmove = 0,
	buttons = 1,
	msec = 50,
})
local shellsAfter = vmlib.edFloat(player, ent.ammo_shells)
t.eq(shellsAfter, shellsBefore - 1, "shotgun fired: shell consumed")
local sawFire = false
for _, snd in svr.soundLog do
	if snd.sample == "weapons/guncock.wav" then
		sawFire = true
	end
end
t.check(sawFire, "guncock sound emitted")

-- world runs: lightstyles registered, time advances
t.check(svr.lightstyles[0] ~= nil or svr.time > 1, "server frames ran")

-- fire the nailgun: spawns a MOVETYPE_FLYMISSILE spike that SV_RunEntity
-- must fly through the world on subsequent frames
vmlib.edSetFloat(player, ent.items, bit32.bor(vmlib.edFloat(player, ent.items) // 1, 4)) -- IT_NAILGUN
vmlib.edSetFloat(player, ent.ammo_nails, 40)
for _ = 1, 12 do
	qwsv.frame(svr, 0.05) -- let the shotgun's attack_finished elapse
end
-- face back down the corridor the player came from, so the nail has
-- open air to fly through (RunNewmis flies it immediately on spawn)
local backYaw = (spawnYaw + 180) % 360
qwsv.executeCmd(svr, client, {
	angles = vector.create(0, backYaw, 0),
	forwardmove = 0,
	sidemove = 0,
	upmove = 0,
	buttons = 0,
	impulse = 4,
	msec = 50,
})
qwsv.executeCmd(svr, client, {
	angles = vector.create(0, backYaw, 0),
	forwardmove = 0,
	sidemove = 0,
	upmove = 0,
	buttons = 1,
	msec = 50,
})
local spike: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "spike" then
		spike = e
		break
	end
end
assert(spike, "nailgun spawned a spike")
local spikeOrg = vmlib.edVector(spike, ent.origin)
qwsv.frame(svr, 0.05)
local flew = vector.magnitude(vmlib.edVector(spike, ent.origin) - spikeOrg)
t.check(not spike.free and flew > 20, `SV_RunEntity flew the spike {math.floor(flew)} units in one frame`)

-- SV_Impact: the spike eventually hits a wall; spike_touch removes it
local impacted = false
for _ = 1, 60 do
	qwsv.frame(svr, 0.05)
	if spike.free then
		impacted = true
		break
	end
end
t.check(impacted, "spike impacted a wall and spike_touch removed it (SV_Impact)")

-- V_CalcRoll server side: a strafing player leans (angles roll * 4).
-- Roll reads the velocity from BEFORE the current move, so strafe twice.
for _ = 1, 2 do
	qwsv.executeCmd(svr, client, {
		angles = vector.create(0, spawnYaw, 0),
		forwardmove = 0,
		sidemove = 350,
		upmove = 0,
		buttons = 0,
		msec = 50,
	})
end
t.check(math.abs(vmlib.edVector(player, ent.angles).z) > 0.1, "V_CalcRoll leaned the strafing player")

-- SV_Physics_Pusher / SV_Push: a door's use function drives a full
-- travel-and-return cycle
local qwworldlib = require("../src/shared/engine/qw/qwworld")
local useDoor: vmlib.Edict? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "door" and vmlib.edInt(e, ent.use) ~= 0 then
		useDoor = e
		break
	end
end
assert(useDoor, "door with a use function")
local glob = svr.qdefs.glob
local doorStart = vmlib.edVector(useDoor, ent.origin)
buffer.writef32(vm.globals, glob.time * 4, svr.time)
buffer.writei32(vm.globals, glob.self * 4, useDoor.num)
buffer.writei32(vm.globals, glob.other * 4, player.num)
vmlib.exec(vm, vmlib.edInt(useDoor, ent.use))
local maxTravel = 0
for _ = 1, 40 do
	qwsv.frame(svr, 0.05)
	maxTravel = math.max(maxTravel, vector.magnitude(vmlib.edVector(useDoor, ent.origin) - doorStart))
end
t.check(maxTravel > 30, `door traveled through SV_Push ({math.floor(maxTravel)} units)`)
for _ = 1, 140 do
	qwsv.frame(svr, 0.05)
end
t.check(vector.magnitude(vmlib.edVector(useDoor, ent.origin) - doorStart) < 1, "door returned home (SV_Physics_Pusher waits)")

-- SV_Physics_Toss + SV_CheckVelocity: a lobbed edict with an absurd
-- velocity component is clamped to sv_maxvelocity, then arcs and rests
local qdl = require("../src/shared/engine/quakedef")
local tossEd = vmlib.alloc(vm)
vmlib.edSetFloat(tossEd, ent.movetype, qdl.MOVETYPE_TOSS)
vmlib.edSetFloat(tossEd, ent.solid, qdl.SOLID_BBOX)
vmlib.edSetVector(tossEd, ent.mins, vector.zero)
vmlib.edSetVector(tossEd, ent.maxs, vector.zero)
vmlib.edSetVector(tossEd, ent.origin, vmlib.edVector(player, ent.origin) + vector.create(0, 0, 30))
vmlib.edSetVector(tossEd, ent.velocity, vector.create(0, 60, 99999))
qwworldlib.linkEdict(svr.world, tossEd, false)
qwsv.frame(svr, 0.05)
t.check(vmlib.edVector(tossEd, ent.velocity).z <= 2000, "SV_CheckVelocity clamped to sv_maxvelocity")
vmlib.edSetVector(tossEd, ent.velocity, vector.create(0, 60, 160))
vmlib.edSetVector(tossEd, ent.origin, vmlib.edVector(player, ent.origin) + vector.create(0, 0, 30))
qwworldlib.linkEdict(svr.world, tossEd, false)
for _ = 1, 80 do
	qwsv.frame(svr, 0.05)
end
t.check(
	bit32.band(vmlib.edFloat(tossEd, ent.flags), qdl.FL_ONGROUND) ~= 0 and vmlib.edVector(tossEd, ent.velocity) == vector.zero,
	"toss came to rest (SV_Physics_Toss / SV_PushEntity / ClipVelocity / SV_AddGravity)"
)

--------------------------------------------------------------------------
-- frame updates: full frame, then a delta frame against the acked one

local msg = require("../src/shared/engine/common/msg")
local qwents = require("../src/shared/engine/qw/qwents")
local qwp = require("../src/shared/engine/qw/qwprotocol")

local function baselineFor(n: number)
	return qwsv.baselineFor(svr, n)
end

-- hand-parse one svc_playerinfo (the client's parser lands in qwcl)
local function parsePlayerinfo(r: msg.Reader)
	local num = msg.readByte(r)
	local flags = msg.readShort(r)
	local origin = vector.create(msg.readCoord(r), msg.readCoord(r), msg.readCoord(r))
	local frame = msg.readByte(r)
	local info = { num = num, flags = flags, origin = origin, frame = frame, msec = 0 }
	if bit32.band(flags, qwp.PF_MSEC) ~= 0 then
		info.msec = msg.readByte(r)
	end
	if bit32.band(flags, qwp.PF_COMMAND) ~= 0 then
		info.cmd = qwents.readDeltaUsercmd(r, qwents.nullCmd())
	end
	local vel = { 0, 0, 0 }
	for i = 1, 3 do
		if bit32.band(flags, bit32.lshift(qwp.PF_VELOCITY1, i - 1)) ~= 0 then
			vel[i] = msg.readShort(r)
		end
	end
	info.velocity = vector.create(vel[1], vel[2], vel[3])
	if bit32.band(flags, qwp.PF_MODEL) ~= 0 then
		info.modelindex = msg.readByte(r)
	end
	if bit32.band(flags, qwp.PF_SKINNUM) ~= 0 then
		info.skinnum = msg.readByte(r)
	end
	if bit32.band(flags, qwp.PF_EFFECTS) ~= 0 then
		info.effects = msg.readByte(r)
	end
	if bit32.band(flags, qwp.PF_WEAPONFRAME) ~= 0 then
		info.weaponframe = msg.readByte(r)
	end
	return info
end

local lastNailCount = 0
local function parseFrame(r: msg.Reader, fromEnts)
	local players = {}
	local ents = nil
	while true do
		local cmdByte = msg.readByte(r)
		if cmdByte == -1 or r.badread then
			break
		end
		if cmdByte == qwp.svc_playerinfo then
			local pi = parsePlayerinfo(r)
			players[pi.num] = pi
		elseif cmdByte == qwp.svc_packetentities then
			ents = qwents.parsePacketEntities(r, {}, baselineFor)
		elseif cmdByte == qwp.svc_deltapacketentities then
			local _seq = msg.readByte(r)
			ents = qwents.parsePacketEntities(r, fromEnts, baselineFor)
		elseif cmdByte == qwp.svc_nails then
			local n = msg.readByte(r)
			lastNailCount = n
			for _ = 1, n * 6 do
				msg.readByte(r)
			end
		else
			error(`unexpected svc {cmdByte}`)
		end
	end
	return players, ents
end

t.check(svr.baselines ~= nil and svr.baselines[0] ~= nil, "baselines created")
t.check(svr.sv_playermodel >= 0, "player model number found")

-- full (non-delta) frame
client.netchan.incoming_sequence = 12
client.delta_sequence = -1
local out = msg.newBuf(8000)
qwsv.writeEntitiesToClient(svr, client, out)
t.check(out.cursize > 0, "frame written")
local r = msg.reader(msg.snapshot(out))
local players, ents1 = parseFrame(r, {})
t.check(players[0] ~= nil, "self playerinfo present")
t.check(bit32.band(players[0].flags, qwp.PF_MSEC) == 0, "self playerinfo omits PF_MSEC")
local porg = vmlib.edVector(player, ent.origin)
t.check(vector.magnitude(players[0].origin - porg) < 0.22, "playerinfo origin matches edict (1/8 coord quantization)")
t.check(ents1 ~= nil and #ents1 > 0, `packet entities present ({ents1 and #ents1})`)
t.check(#ents1 <= qwents.MAX_PACKET_ENTITIES, "within MAX_PACKET_ENTITIES")
local frameSlot = svr.clients[1].frames[bit32.band(12, qwp.UPDATE_MASK)]
t.eq(#frameSlot.entities, #ents1, "frame ring stored what was sent")

-- delta frame: client acks seq 12, server writes seq 13 against it
client.netchan.incoming_sequence = 13
client.delta_sequence = 12
local out2 = msg.newBuf(8000)
qwsv.writeEntitiesToClient(svr, client, out2)
t.check(out2.cursize < out.cursize, "delta frame smaller than full frame")
local r2 = msg.reader(msg.snapshot(out2))
local _players2, ents2 = parseFrame(r2, ents1)
t.check(ents2 ~= nil, "delta frame parsed")
t.eq(#ents2, #ents1, "static world: delta reproduces same entity set")
local allMatch = true
for i = 1, #ents1 do
	if ents2[i].number ~= ents1[i].number then
		allMatch = false
	end
	if vector.magnitude(ents2[i].origin - ents1[i].origin) >= 0.001 then
		allMatch = false
	end
end
t.check(allMatch, "delta round-trip: every entity number and origin matches")

-- SV_AddNailUpdate / SV_EmitNailUpdate: with a spike in flight the
-- frame carries svc_nails
for _ = 1, 12 do
	qwsv.frame(svr, 0.05)
end
qwsv.executeCmd(svr, client, {
	angles = vector.create(0, (spawnYaw + 180) % 360, 0),
	forwardmove = 0,
	sidemove = 0,
	upmove = 0,
	buttons = 1,
	msec = 50,
})
lastNailCount = 0
local nout = msg.newBuf(8000)
client.netchan.incoming_sequence += 1
client.delta_sequence = -1
qwsv.writeEntitiesToClient(svr, client, nout)
parseFrame(msg.reader(msg.snapshot(nout)), {})
t.check(lastNailCount >= 1, `svc_nails carried the in-flight spike ({lastNailCount})`)

--------------------------------------------------------------------------
-- spectator lifecycle: SV_SpawnSpectator places at info_player_start,
-- ptrack/msg user commands update the client
qwsv.connectClient(svr, 2, { name = "spec", spectator = "1" })
local spec = svr.clients[2]
t.check(spec.spectator == true, "userinfo spectator=1 marks the client")
local sorg = vmlib.edVector(spec.edict, ent.origin)
local atStart = false
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if not e.free and vmlib.edString(vm, e, ent.classname) == "info_player_start" then
		if vector.magnitude(vmlib.edVector(e, ent.origin) - sorg) < 1 then
			atStart = true
		end
	end
end
t.check(atStart, "SV_SpawnSpectator placed the spectator at info_player_start")
qwsv.executeUserCommand(svr, spec, "ptrack 0")
-- C stores i+1 (0 = not tracking)
t.eq((spec :: any).spec_track, 1, "SV_PTrack_f set the tracked player (stored +1 as C)")
qwsv.executeUserCommand(svr, spec, "msg 1")
t.eq((spec :: any).messagelevel, 1, "SV_Msg_f set the message level")

--------------------------------------------------------------------------
-- SV_Physics_None / Noclip / Step dispatch (qwphys)
local qwworldlib2 = require("../src/shared/engine/qw/qwworld")
local qdl2 = require("../src/shared/engine/quakedef")
local noneEd = vmlib.alloc(vm)
vmlib.edSetFloat(noneEd, ent.movetype, qdl2.MOVETYPE_NONE)
vmlib.edSetVector(noneEd, ent.origin, vmlib.edVector(player, ent.origin) + vector.create(0, 0, 200))
vmlib.edSetVector(noneEd, ent.velocity, vector.create(0, 0, -100))
qwworldlib2.linkEdict(svr.world, noneEd, false)
local noneOrg = vmlib.edVector(noneEd, ent.origin)
local clipEd = vmlib.alloc(vm)
vmlib.edSetFloat(clipEd, ent.movetype, qdl2.MOVETYPE_NOCLIP)
vmlib.edSetVector(clipEd, ent.origin, vmlib.edVector(player, ent.origin))
vmlib.edSetVector(clipEd, ent.velocity, vector.create(0, 0, 500))
qwworldlib2.linkEdict(svr.world, clipEd, false)
local stepEd = vmlib.alloc(vm)
vmlib.edSetFloat(stepEd, ent.movetype, qdl2.MOVETYPE_STEP)
vmlib.edSetFloat(stepEd, ent.solid, qdl2.SOLID_BBOX)
vmlib.edSetVector(stepEd, ent.mins, vector.zero)
vmlib.edSetVector(stepEd, ent.maxs, vector.zero)
-- open air above the spawn floor (staging inside a ceiling would hit
-- C's trapped-entity velocity zeroing instead of falling)
vmlib.edSetVector(stepEd, ent.origin, vector.create(480, -352, 120))
qwworldlib2.linkEdict(svr.world, stepEd, false)
local stepStart = vmlib.edVector(stepEd, ent.origin)
for _ = 1, 30 do
	qwsv.frame(svr, 0.05)
end
t.check(vmlib.edVector(noneEd, ent.origin) == noneOrg, "MOVETYPE_NONE never moves despite velocity (SV_Physics_None)")
t.check(vmlib.edVector(clipEd, ent.origin).z > vmlib.edVector(player, ent.origin).z + 300, "MOVETYPE_NOCLIP flies through the ceiling (SV_Physics_Noclip)")
t.check(
	vmlib.edVector(stepEd, ent.origin).z < stepStart.z - 30
		and bit32.band(vmlib.edFloat(stepEd, ent.flags), qdl2.FL_ONGROUND) ~= 0,
	"MOVETYPE_STEP falls under gravity and lands (SV_Physics_Step)"
)

-- QW's SV_Physics_Toss unstick: upward velocity clears FL_ONGROUND (a line
-- QW added over NQ; QC that flings resting items relies on it — found via
-- Threewave CTF's flag tosses)
local tossEd = vmlib.alloc(vm)
vmlib.edSetFloat(tossEd, ent.movetype, qdl2.MOVETYPE_TOSS)
vmlib.edSetFloat(tossEd, ent.solid, qdl2.SOLID_BBOX)
vmlib.edSetVector(tossEd, ent.mins, vector.zero)
vmlib.edSetVector(tossEd, ent.maxs, vector.zero)
vmlib.edSetVector(tossEd, ent.origin, vector.create(480, -352, 120))
qwworldlib2.linkEdict(svr.world, tossEd, false)
for _ = 1, 30 do
	qwsv.frame(svr, 0.05)
end
t.check(bit32.band(vmlib.edFloat(tossEd, ent.flags), qdl2.FL_ONGROUND) ~= 0, "toss item landed (FL_ONGROUND)")
local restZ = vmlib.edVector(tossEd, ent.origin).z
vmlib.edSetVector(tossEd, ent.velocity, vector.create(0, 0, 300))
for _ = 1, 4 do
	qwsv.frame(svr, 0.05)
end
t.check(
	vmlib.edVector(tossEd, ent.origin).z > restZ + 20,
	"upward velocity unsticks a grounded toss item (SV_Physics_Toss QW onground clear)"
)

t.finish("test_qwsv")
