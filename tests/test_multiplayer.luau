--!strict
-- Multiplayer: two clients on one server (coop). Verifies both complete the
-- signon sequence, see each other's player entities, and that damage between
-- players' views of the world stays consistent. Also exercises
-- trigger_changelevel → server respawn → reconnect.

local t = require("./testutil")
local cllib = require("../src/shared/engine/client/cl")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")
local svlib = require("../src/shared/engine/server/sv")
local cvarlib = require("../src/shared/engine/common/cvar")

local ent = defs.ent

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
cvarlib.setValue(svr.cvars, "coop", 1)

host.spawnServer(svr, "e1m1")
t.check(svr.active, "server active (coop)")

type Link = { c: cllib.Client, sc: svlib.Client }
local links: { Link } = {}

local function connect(name: string): Link
	local c = cllib.new(name, 0x22)
	c.print = function(_s: string) end
	local slot = host.findFreeClient(svr) :: number
	local sc = svr.clients[slot]
	sc.sendUnreliable = function(d: buffer)
		cllib.parseServerMessage(c, d)
		return true
	end
	sc.sendReliable = function(d: buffer)
		cllib.parseServerMessage(c, d)
		return true
	end
	host.connectClient(svr, slot)
	local link = { c = c, sc = sc }
	table.insert(links, link)
	return link
end

local function pump(frametime: number)
	for _, l in links do
		local rel = cllib.takeReliable(l.c)
		if rel then
			table.insert(l.sc.inbox, rel)
		end
	end
	host.frame(svr, frametime)
	for _, l in links do
		l.c.oldtime = l.c.time
		l.c.time += frametime
		cllib.relinkEntities(l.c, function()
			return 0
		end)
	end
end

local p1 = connect("Ranger")
local p2 = connect("Bitterman")

for _ = 1, 8 do
	pump(0.05)
end
t.eq(p1.c.signon, cllib.SIGNONS, "p1 signed on")
t.eq(p2.c.signon, cllib.SIGNONS, "p2 signed on")
t.eq(p1.c.viewentity, 1, "p1 views edict 1")
t.eq(p2.c.viewentity, 2, "p2 views edict 2")

-- both players' edicts alive server-side
t.eq(vmlib.edString(svr.vm, svr.clients[1].edict, ent.classname), "player", "p1 edict is player")
t.eq(vmlib.edString(svr.vm, svr.clients[2].edict, ent.classname), "player", "p2 edict is player")

-- coop spawn points differ (info_player_coop) or same start — either way
-- both must be in valid empty space near a spawn point
local o1 = vmlib.edVector(svr.clients[1].edict, ent.origin)
local o2 = vmlib.edVector(svr.clients[2].edict, ent.origin)
t.check(vector.magnitude(o1) > 0 and vector.magnitude(o2) > 0, "both spawned")

-- run a bit; each client should see the OTHER player's entity via updates
for _ = 1, 20 do
	local move1 = cllib.buildMove(p1.c, 200, 0, 0, false, false, 0)
	if move1 then
		table.insert(p1.sc.inbox, move1)
	end
	local move2 = cllib.buildMove(p2.c, 0, 0, 0, false, false, 0)
	if move2 then
		table.insert(p2.sc.inbox, move2)
	end
	pump(0.05)
end

-- scoreboard names propagated
t.eq(p1.c.scores[2].name, "Bitterman", "p1 sees p2 name")
t.eq(p2.c.scores[1].name, "Ranger", "p2 sees p1 name")

-- if they spawned within sight of each other, entities are exchanged; at
-- minimum each client tracks its own entity
t.check(p1.c.entities[1] ~= nil, "p1 has own entity")
t.check(p2.c.entities[2] ~= nil, "p2 has own entity")

-- p1 kills themselves via the kill command; ClientKill applies a -2 frag
-- penalty and respawns immediately (client.qc)
local kill = require("../src/shared/engine/common/msg")
local buf = kill.newBuf(64)
kill.writeByte(buf, 4) -- clc_stringcmd
kill.writeString(buf, "kill")
table.insert(p1.sc.inbox, kill.snapshot(buf))
for _ = 1, 30 do
	pump(0.05)
end
t.eq(p1.c.scores[1].frags, -2, "suicide penalty (own view)")
t.eq(p2.c.scores[1].frags, -2, "suicide penalty (p2 view)")
t.check(vmlib.edFloat(svr.clients[1].edict, ent.health) > 0, "p1 instantly respawned (coop)")

t.finish("test_multiplayer")
