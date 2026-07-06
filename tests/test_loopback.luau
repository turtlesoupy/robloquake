--!strict
-- Full-stack loopback: the real client state machine connected to the real
-- server through in-memory transports. Verifies the whole protocol path:
-- serverinfo → signon → baselines → entity updates → interpolation.

local t = require("./testutil")
local cllib = require("../src/shared/engine/client/cl")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local qd = require("../src/shared/engine/quakedef")

local ent = defs.ent

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end

host.spawnServer(svr, "e1m1")

-- wire a loopback client
local c = cllib.new("Ranger", 0x44)
local prints: { string } = {}
c.print = function(s: string)
	table.insert(prints, s)
end
local sounds: { string } = {}
c.onSound = function(_c, _entnum, _channel, sample, _pos, _vol, _atten)
	table.insert(sounds, sample)
end
local staticSounds = 0
c.onStaticSound = function()
	staticSounds += 1
end

local clientnum = host.findFreeClient(svr) :: number
local sclient = svr.clients[clientnum]
sclient.sendUnreliable = function(data: buffer)
	cllib.parseServerMessage(c, data)
	return true
end
sclient.sendReliable = function(data: buffer)
	cllib.parseServerMessage(c, data)
	return true
end
host.connectClient(svr, clientnum)

-- pump: client reliable stream -> server inbox, then run a server frame
local function pump(frametime: number, move: buffer?)
	local rel = cllib.takeReliable(c)
	if rel then
		table.insert(sclient.inbox, rel)
	end
	if move then
		table.insert(sclient.inbox, move)
	end
	host.frame(svr, frametime)
end

-- a few frames complete the whole signon sequence automatically
for _ = 1, 6 do
	pump(0.05)
end
t.eq(c.signon, cllib.SIGNONS, "client fully signed on")
t.eq(c.levelname, "the Slipgate Complex", "level name")
t.eq(c.maxclients, 4, "maxclients")
t.eq(c.viewentity, 1, "view entity")
t.check(#c.model_precache > 30, "client got model precache")
t.eq(c.model_precache[2], "maps/e1m1.bsp", "world model name")
t.check(c.lightstyles[0] == "m", "lightstyle 0 received")
-- e1m1 is a base map: no torch statics, but ambient hums are in the signon
t.check(staticSounds >= 4, "ambient sounds spawned")

-- player state flows
t.eq(c.stats[cllib.STAT_HEALTH], 100, "health via clientdata")
t.eq(c.stats[cllib.STAT_SHELLS], 25, "shells")
t.check(bit32.band(c.items, qd.IT_SHOTGUN) ~= 0, "has shotgun")
t.check(c.stats[cllib.STAT_TOTALMONSTERS] > 20, "total monsters stat")

-- run a while: entities should appear and interpolate
local function modelFlags(_mi: number): number
	return 0
end
for _ = 1, 30 do
	pump(0.05, cllib.buildMove(c, 0, 0, 0, false, false, 0))
	c.oldtime = c.time
	c.time += 0.05
	cllib.relinkEntities(c, modelFlags)
end

-- the spawn area's PVS really does contain only ~2 entities (verified
-- against an independent PVS decode); just require the player itself
t.check(c.entities[c.viewentity].visible, "player entity visible")
local porg = c.entities[c.viewentity].origin
t.check(vector.magnitude(porg - vector.create(480, -352, 88)) < 60, `client sees player near start ({porg})`)

-- move forward and verify client's own entity moves via updates
local startY = porg.y
for _ = 1, 40 do
	c.viewangles = vector.create(0, 90, 0)
	pump(0.05, cllib.buildMove(c, 400, 0, 0, false, false, 0))
	c.oldtime = c.time
	c.time += 0.05
	cllib.relinkEntities(c, modelFlags)
end
local endY = c.entities[c.viewentity].origin.y
t.check(endY - startY > 100, `client observed forward motion ({startY} -> {endY})`)
-- deeper in the map more of the world is visible
local visible = 0
for i = 1, c.num_entities - 1 do
	if c.entities[i] and c.entities[i].visible then
		visible += 1
	end
end
t.check(visible >= 4, `visible entities after moving ({visible})`)
t.check(c.velocity ~= vector.zero, "client velocity from clientdata")
t.check(c.onground, "client onground flag")

-- fire: shells drop and the shotgun sound arrives
local shells0 = c.stats[cllib.STAT_SHELLS]
for _ = 1, 6 do
	pump(0.05, cllib.buildMove(c, 0, 0, 0, true, false, 0))
	c.oldtime = c.time
	c.time += 0.05
	cllib.relinkEntities(c, modelFlags)
end
t.check(c.stats[cllib.STAT_SHELLS] < shells0, "shells consumed (client view)")
local sawShotgun = false
for _, s in sounds do
	if s == "weapons/guncock.wav" then
		sawShotgun = true
	end
end
t.check(sawShotgun, "shotgun sound event received")

--------------------------------------------------------------------------
-- S_StopSound: a crafted svc_stopsound routes entity/channel through the
-- onStopSound hook (the boot wires it to sound.stop)
do
	local proto = require("../src/shared/engine/protocol")
	local msg = require("../src/shared/engine/common/msg")
	local stopped: { number } = {}
	c.onStopSound = function(_c2, entnum: number, channel: number)
		stopped = { entnum, channel }
	end
	local sb = msg.newBuf(16)
	msg.writeByte(sb, proto.svc_stopsound)
	msg.writeShort(sb, 5 * 8 + 3) -- entity 5, channel 3
	local pkt = buffer.create(sb.cursize)
	buffer.copy(pkt, 0, sb.data, 0, sb.cursize)
	cllib.parseServerMessage(c, pkt)
	t.check(stopped[1] == 5 and stopped[2] == 3, "svc_stopsound: ent 5 chan 3 through onStopSound (S_StopSound)")
end

t.finish("test_loopback")
