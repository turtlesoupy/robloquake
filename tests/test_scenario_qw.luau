--!strict
-- SCENARIO: QuakeWorld two-client deathmatch over the loopback wire.
-- Two qwcl clients connect through the real protocol, one shoots the
-- other dead with the shotgun, the frag lands on BOTH scoreboards, the
-- victim respawns, and a changelevel carries the killer's inventory.
-- This is interaction coverage the per-function grid cannot express.
local t = require("./testutil")
local fs = require("@lune/fs")
local vmlib = require("../src/shared/engine/progs/vm")
local mathlib = require("../src/shared/engine/common/mathlib")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwp = require("../src/shared/engine/qw/qwprotocol")
local qwworld = require("../src/shared/engine/qw/qwworld")

local gamefs = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))

local svr = qwsv.newGame(gamefs, qwprogs)
svr.print = function(_s: string) end
qwsv.spawnServer(svr, "e1m1")
t.check(svr.active, "server spawned e1m1")

type Link = { cl: any, sc: any, queue: { buffer }, pending: { buffer } }

local function link(slot: number, name: string): Link
	local L = { cl = qwcl.new(gamefs), sc = nil :: any, queue = {} :: { buffer }, pending = {} :: { buffer } }
	L.sc = qwsv.wireConnect(svr, slot, { name = name }, function(packet: buffer)
		table.insert(L.queue, packet)
	end)
	qwcl.connect(L.cl, function(packet: buffer)
		qwsv.executeClientMessage(svr, L.sc, packet)
	end)
	return L
end

local A = link(1, "alpha")
local B = link(2, "bravo")

-- handshake both clients (client replies happen synchronously inside
-- processPacket, so pumping server replies drives the whole exchange)
for _ = 1, 40 do
	qwsv.sendClientMessages(svr)
	for _, L in { A, B } do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
	end
	if A.sc.spawned and B.sc.spawned then
		break
	end
end
t.check(A.sc.spawned and B.sc.spawned, "both clients completed the handshake")
t.eq(A.cl.playernum, 0, "alpha in slot 0")
t.eq(B.cl.playernum, 1, "bravo in slot 1")
t.check(A.cl.players[1] ~= nil and A.cl.players[1].name == "bravo", "alpha's scoreboard lists bravo")
t.check(B.cl.players[0] ~= nil and B.cl.players[0].name == "alpha", "bravo's scoreboard lists alpha")

local ent = svr.qdefs.ent
local playerA = A.sc.edict
local playerB = B.sc.edict

-- stage the duel: put bravo 80 units in front of alpha's muzzle
local yawA = vmlib.edVector(playerA, ent.angles).y
local fwd = mathlib.angleVectors(vector.create(0, yawA, 0))
local duelSpot = vmlib.edVector(playerA, ent.origin) + fwd * 80
vmlib.edSetVector(playerB, ent.origin, duelSpot)
vmlib.edSetVector(playerB, ent.velocity, vector.zero)
qwworld.linkEdict(svr.world, playerB, false)
local yawB = (yawA + 180) % 360

-- one tick of server→client latency so prediction actually predicts
local function tick(abuttons: number, bbuttons: number)
	for _, L in { A, B } do
		L.cl.realtime += 0.05
		for _, packet in L.pending do
			qwcl.processPacket(L.cl, packet)
		end
		L.pending = {}
	end
	local function cmd(yaw: number, buttons: number)
		return {
			angles = vector.create(0, yaw, 0),
			forwardmove = 0,
			sidemove = 0,
			upmove = 0,
			buttons = buttons,
			impulse = 0,
			msec = 50,
		}
	end
	qwcl.sendCmd(A.cl, cmd(yawA, abuttons))
	qwcl.sendCmd(B.cl, cmd(yawB, bbuttons))
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, L in { A, B } do
		for _, packet in L.queue do
			table.insert(L.pending, packet)
		end
		L.queue = {}
		qwcl.predictMove(L.cl)
	end
end

-- settle both into active play
for _ = 1, 5 do
	tick(0, 0)
end
t.eq(A.cl.state, "active", "alpha active")
t.eq(B.cl.state, "active", "bravo active")

-- alpha sees bravo's body at the duel spot through packet playerstates
local aframe = A.cl.frames[bit32.band(A.cl.netchan.incoming_sequence, qwp.UPDATE_MASK)]
local seenB = aframe.playerstate[1]
t.check(seenB ~= nil and vector.magnitude(seenB.origin - duelSpot) < 32, "alpha sees bravo at the duel spot")

-- FIGHT: alpha holds fire until bravo dies (shotgun, ~5 shots at 0.5s refire)
local shotsTicks = 0
for _ = 1, 400 do
	tick(1, 0)
	shotsTicks += 1
	if vmlib.edFloat(playerB, ent.health) <= 0 then
		break
	end
end
t.check(vmlib.edFloat(playerB, ent.health) <= 0, `bravo died to shotgun fire ({shotsTicks} ticks)`)
local shellsAfterFight = vmlib.edFloat(playerA, ent.ammo_shells)
t.check(shellsAfterFight < 25, `alpha spent shells ({shellsAfterFight})`)

-- the frag must reach BOTH scoreboards via SV_UpdateToReliableMessages
for _ = 1, 4 do
	tick(0, 0)
end
t.eq(vmlib.edFloat(playerA, ent.frags), 1, "server credited alpha the frag")
t.check(A.cl.players[0].frags == 1, `frag on alpha's own scoreboard ({A.cl.players[0].frags})`)
t.check(B.cl.players[0].frags == 1, `frag on bravo's scoreboard ({B.cl.players[0].frags})`)
t.check(B.cl.stats[qwp.STAT_HEALTH] <= 0, "bravo's health stat shows dead")
t.check(B.cl.damage ~= nil and B.cl.damage.take > 0, "svc_damage reached the victim (V_ParseDamage input)")

-- RESPAWN: the death animation must reach DEAD_DEAD (~1s of think
-- frames), buttons released flips DEAD_RESPAWNABLE, then attack respawns
local deathSpot = vmlib.edVector(playerB, ent.origin)
for _ = 1, 40 do
	tick(0, 0) -- all buttons up through the death animation
end
tick(0, 1) -- bravo presses fire
for _ = 1, 4 do
	tick(0, 0)
end
t.eq(vmlib.edFloat(playerB, ent.health), 100, "bravo respawned at full health")
t.check(vector.magnitude(vmlib.edVector(playerB, ent.origin) - deathSpot) > 32, "bravo respawned away from the corpse")
t.check(B.cl.stats[qwp.STAT_HEALTH] == 100, "bravo's health stat recovered over the wire")
t.eq(vmlib.edFloat(playerB, ent.frags), 0, "death by enemy is not a suicide (no frag penalty)")

-- CHANGELEVEL: alpha's inventory must carry through SV_SaveSpawnparms →
-- DecodeLevelParms across the map change. C truth (qw-qc client.qc
-- SetChangeParms): shells are FLOORED at 25, items keep weapons but
-- drop keys/powerups, weapon carries verbatim.
local itemsBefore = vmlib.edFloat(playerA, ent.items) // 1
local weaponBefore = vmlib.edFloat(playerA, ent.weapon)
qwsv.saveSpawnparms(svr)
qwsv.spawnServer(svr, "e1m2")
t.check(svr.active, "server respawned on e1m2")
for _, L in { A, B } do
	L.pending = {}
	L.queue = {}
	L.sc.spawned = false
	qwsv.newF(svr, L.sc)
	L.sc.send_message = true
	qwsv.replyToClient(svr, L.sc)
end
for _ = 1, 40 do
	for _, L in { A, B } do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
	end
	qwsv.sendClientMessages(svr)
	if A.sc.spawned and B.sc.spawned then
		break
	end
end
for _, L in { A, B } do
	while #L.queue > 0 do
		qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
	end
end
t.check(A.sc.spawned and B.sc.spawned, "both clients re-handshook after changelevel")
t.check(A.cl.model_name[1] == "maps/e1m2.bsp" and B.cl.model_name[1] == "maps/e1m2.bsp", "both clients loaded e1m2")
t.eq(
	vmlib.edFloat(A.sc.edict, ent.ammo_shells),
	math.max(shellsAfterFight, 25),
	"shells carried with the authentic SetChangeParms floor of 25"
)
t.eq(vmlib.edFloat(A.sc.edict, ent.items) // 1, itemsBefore, "alpha's items carried across the level change")
t.eq(vmlib.edFloat(A.sc.edict, ent.weapon), weaponBefore, "alpha's held weapon carried across the level change")

t.finish("test_scenario_qw")
