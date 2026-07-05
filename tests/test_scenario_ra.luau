--!strict
-- SCENARIO S6: Rocket Arena "Final Arena" 1.20 — a second UNMODIFIED
-- third-party QuakeWorld mod through the same gamedir pipeline (zero
-- special cases). Round/queue logic is the stress test: challenger queue,
-- the 10..1 countdown, arena loadout, winner-stays round cycling, and
-- fraglimit map rotation driven by QW localinfo (the rotate.cfg
-- mechanism), which exercises PF_infokey's serverinfo→localinfo fallback.
--
-- Staging (gitignored, never committed): external_assets/rocketarena/
-- from quaddicted.com's telefragged mirror (fasrv12.zip + farena12.zip);
-- provenance + license in docs/mods-licenses.md. Mod progs/QC NEVER edited.
local t = require("./testutil")
local fs = require("@lune/fs")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local cvarlib = require("../src/shared/engine/common/cvar")
local mathlib = require("../src/shared/engine/common/mathlib")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwworld = require("../src/shared/engine/qw/qwworld")

local ID1 = "external_assets/quake106/extracted/id1/"
local RA = "external_assets/rocketarena/"
if not fs.isFile(RA .. "qwprogs.dat") or not fs.isFile(RA .. "pak0.pak") then
	print("test_scenario_ra: SKIPPED (rocketarena mod not staged)")
	return
end

local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	if fs.isFile(ID1 .. name .. ".pak") then
		vfs.addPack(fsys, pak.load("id1/" .. name, buffer.fromstring(fs.readFile(ID1 .. name .. ".pak"))))
	end
end
vfs.addPack(fsys, pak.load("rocketarena/pak0", buffer.fromstring(fs.readFile(RA .. "pak0.pak"))))
vfs.addPack(
	fsys,
	pak.load(
		"rocketarena/pak1",
		t.writePak({ { name = "qwprogs.dat", data = buffer.fromstring(fs.readFile(RA .. "qwprogs.dat")) } })
	)
)

local svr = qwsv.newGame(fsys)
svr.print = function(_s: string) end
-- the mod's own rotate.cfg mechanism: localinfo <thismap> <nextmap>
svr.localinfo["crandome"] = "2pyramid"
cvarlib.setValue(svr.cvars, "fraglimit", 2)
qwsv.spawnServer(svr, "crandome")
t.check(svr.active == true, "rocket arena qwprogs spawned crandome")

local ent = svr.qdefs.ent
local function deglyph(s: string): string
	local out = table.create(#s)
	for i = 1, #s do
		table.insert(out, string.char(bit32.band(string.byte(s, i), 0x7f)))
	end
	return table.concat(out)
end

type Link = { cl: any, sc: any, queue: { buffer } }
local function link(slot: number, name: string): Link
	local L = { cl = qwcl.new(fsys), sc = nil :: any, queue = {} :: { buffer } }
	L.sc = qwsv.wireConnect(svr, slot, { name = name }, function(p: buffer)
		table.insert(L.queue, p)
	end)
	qwcl.connect(L.cl, function(p: buffer)
		qwsv.executeClientMessage(svr, L.sc, p)
	end)
	return L
end
local function pump(links: { Link })
	for _, L in links do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
	end
end
local function sawPrint(L: Link, pattern: string, since: number?): boolean
	for i = since or 1, #L.cl.prints do
		if deglyph(L.cl.prints[i].text):find(pattern) then
			return true
		end
	end
	return false
end
local function sawCenter(L: Link, pattern: string, since: number?): boolean
	for i = since or 1, #L.cl.centerprints do
		if deglyph(L.cl.centerprints[i]):find(pattern) then
			return true
		end
	end
	return false
end

-- first player alone: queued, waiting
local A = link(1, "alpha")
for _ = 1, 40 do
	qwsv.sendClientMessages(svr)
	pump({ A })
	if A.sc.spawned then
		break
	end
end
t.check(A.sc.spawned == true, "alpha completed the handshake")

local B = link(2, "bravo")
for _ = 1, 40 do
	qwsv.sendClientMessages(svr)
	pump({ A, B })
	if B.sc.spawned then
		break
	end
end
t.check(B.sc.spawned == true, "bravo completed the handshake")

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
local playerA, playerB = A.sc.edict, B.sc.edict
local yawA = vmlib.edVector(playerA, ent.angles).y
local function run(n: number, abtn: number, bbtn: number?)
	for _ = 1, n do
		qwcl.sendCmd(A.cl, cmd(yawA, abtn))
		qwcl.sendCmd(B.cl, cmd(yawA + 180, bbtn or 0))
		qwsv.frame(svr, 0.05)
		qwsv.sendClientMessages(svr)
		pump({ A, B })
	end
end

-- the 10..1 countdown runs, then FIGHT!
local fought = false
for _ = 1, 300 do
	run(1, 0)
	if sawCenter(A, "FIGHT!") then
		fought = true
		break
	end
end
t.check(fought, "countdown reached FIGHT!")
t.check(sawCenter(A, "3") and sawCenter(A, "2") and sawCenter(A, "1"), "countdown centerprints ticked")
-- queue prints all delivered by now (they ride the frame packets)
t.check(sawPrint(A, "Welcome To Rocket Arena"), "RA welcome message")
t.check(sawPrint(A, "Waiting for opponent"), "lone player waited in the arena queue")
t.check(sawPrint(A, "is the new challenger"), "bravo announced as the challenger")
run(4, 0)

-- arena loadout: full armor and rockets, no pickups involved
t.eq(vmlib.edFloat(playerA, ent.health), 100, "arena spawn health 100")
t.eq(vmlib.edFloat(playerA, ent.armorvalue), 200, "arena loadout: 200 armor")
t.eq(vmlib.edFloat(playerA, ent.ammo_rockets), 60, "arena loadout: 60 rockets")
t.eq(vmlib.edFloat(playerB, ent.armorvalue), 200, "challenger got the loadout too")

-- ROUND 1: alpha rockets bravo from 250 units (outside self-splash)
local fwd = mathlib.angleVectors(vector.create(0, yawA, 0))
local duelSpot = vmlib.edVector(playerA, ent.origin) + fwd * 250
vmlib.edSetVector(playerB, ent.origin, duelSpot)
vmlib.edSetVector(playerB, ent.velocity, vector.zero)
qwworld.linkEdict(svr.world, playerB, false)
for _ = 1, 600 do
	run(1, 1)
	if vmlib.edFloat(playerB, ent.health) <= 0 then
		break
	end
end
t.check(vmlib.edFloat(playerB, ent.health) <= 0, "challenger died to rockets")
local printsAfterKill = #A.cl.prints
run(40, 0)
t.check(sawPrint(A, "has failed"), "round result: the challenger has failed")
t.check(sawPrint(A, "Victory"), "winner announcement (FLAWLESS Victory)")

-- winner stays: the loser respawns into a fresh round with a fresh
-- loadout (functional re-queue — RA reissues the 200 armor per round)
-- (fraglimit is 2 so round 1's win does NOT start the intermission —
-- intermission freezes PlayerPreThink and with it RA's autorespawn)
local recycled = false
for _ = 1, 600 do
	run(1, 0)
	if vmlib.edFloat(playerB, ent.health) > 0 and vmlib.edFloat(playerB, ent.armorvalue) >= 200 then
		recycled = true
		break
	end
end
t.check(recycled, "loser re-queued into round 2 with a fresh arena loadout (winner stays)")
local _ = printsAfterKill

-- ROUND 2 win hits fraglimit: RA rotates via localinfo (rotate.cfg chain)
vmlib.edSetVector(playerB, ent.origin, vmlib.edVector(playerA, ent.origin) + fwd * 250)
vmlib.edSetVector(playerB, ent.velocity, vector.zero)
qwworld.linkEdict(svr.world, playerB, false)
for _ = 1, 600 do
	run(1, 1)
	if vmlib.edFloat(playerB, ent.health) <= 0 then
		break
	end
end
-- fraglimit hit: intermission runs; a button press exits it and the
-- server changelevels to the localinfo successor
for i = 1, 600 do
	run(1, i % 2, i % 2)
	if svr.changelevelTo ~= nil then
		break
	end
end
t.eq(svr.changelevelTo, "2pyramid", "fraglimit rotation read the next map from localinfo")

t.finish("test_scenario_ra")
