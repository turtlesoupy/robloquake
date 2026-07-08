--!strict
-- SCENARIO S7: Team Fortress 2.9 (QWTF) — an UNMODIFIED third-party
-- QuakeWorld mod running via gamedir stacking (id1 base + the TF 2.8
-- client pak + the shipped TF 2.9 qwprogs.dat + 2fort5.bsp, exactly as
-- tools/build_assets.py stages it). Two clients connect over the real
-- loopback wire, join opposite teams (impulse 140/141), pick classes
-- (impulse 100+class: Soldier/Scout), and play the 2fort loop: enemy
-- flag grab in the basement, capture at the dropoff, per-class movement
-- speeds and loadouts. The mod's progs/QC are NEVER edited; everything
-- runs on the stock engine ABI-by-name machinery.
--
-- Staging (gitignored, never committed, LOCAL/DEV ONLY — Valve IP):
-- external_assets/fortress/ from archive.org quaketf-archive
-- (see docs/mods-licenses.md).
local t = require("./testutil")
local fs = require("@lune/fs")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local cvarlib = require("../src/shared/engine/common/cvar")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwworld = require("../src/shared/engine/qw/qwworld")

local ID1 = "external_assets/quake106/extracted/id1/"
local TF = "external_assets/fortress/"
if not fs.isFile(TF .. "qwprogs.dat") or not fs.isFile(ID1 .. "pak1.pak") then
	print("test_scenario_tf: SKIPPED (fortress mod or registered id1 assets not staged)")
	return
end

-- gamedir stack: id1 base, then the mod's pak, then its loose files as a
-- synthetic pak — the same shape tools/build_assets.py ships to the place
local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("id1/" .. name, buffer.fromstring(fs.readFile(ID1 .. name .. ".pak"))))
end
vfs.addPack(fsys, pak.load("fortress/pak0", buffer.fromstring(fs.readFile(TF .. "pak0.pak"))))
vfs.addPack(
	fsys,
	pak.load(
		"fortress/pak1",
		t.writePak({
			{ name = "qwprogs.dat", data = buffer.fromstring(fs.readFile(TF .. "qwprogs.dat")) },
			{ name = "maps/2fort5.bsp", data = buffer.fromstring(fs.readFile(TF .. "maps/2fort5.bsp")) },
		})
	)
)

local svr = qwsv.newGame(fsys) -- qwprogs.dat comes from the searchpath stack
svr.print = function(_s: string) end
-- the tf preset's rules (modepresets.luau): TF's own teamplay bitfield,
-- deathmatch 3 = classes changeable (and nextpc applied on respawn)
cvarlib.setValue(svr.cvars, "teamplay", 21)
cvarlib.setValue(svr.cvars, "deathmatch", 3)
cvarlib.setValue(svr.cvars, "timelimit", 30)
cvarlib.setValue(svr.cvars, "fraglimit", 100)
qwsv.spawnServer(svr, "2fort5")
t.check(svr.active == true, "TF 2.9 qwprogs spawned 2fort5")

local ent = svr.qdefs.ent
local function classnameOf(ed: any): string
	return vmlib.edString(svr.vm, ed, ent.classname)
end
local function netnameOf(ed: any): string
	return vmlib.edString(svr.vm, ed, ent.netname)
end
local function eachEdict(f: (ed: any) -> ())
	for i = 1, svr.vm.num_edicts do
		local ed = vmlib.edictNum(svr.vm, i - 1)
		if not ed.free then
			f(ed)
		end
	end
end

-- mod-added entity fields, resolved from TF's own 2.9 fielddefs by name
local function fieldOfs(name: string): number
	local def = svr.progs.fielddefsByName[name]
	t.check(def ~= nil, `TF declares the .{name} field`)
	return def.ofs
end
local playerclassOfs = fieldOfs("playerclass")
local teamNoOfs = fieldOfs("team_no")

-- the map's TF layout spawned: both flags, both dropoffs, team spawns
local flag1: any, flag2: any = nil, nil -- "Team N flag" = stolen BY team N
local drop1: any = nil
local teamSpawns = 0
eachEdict(function(ed)
	local cn = classnameOf(ed)
	if cn == "item_tfgoal" then
		local nn = netnameOf(ed)
		if nn:find("Team 1") then
			flag1 = ed
		elseif nn:find("Team 2") then
			flag2 = ed
		end
	elseif cn == "info_tfgoal" and netnameOf(ed):find("Team 1 dropoff") then
		drop1 = ed
	elseif cn == "info_player_teamspawn" then
		teamSpawns += 1
	end
end)
t.check(flag1 ~= nil and flag2 ~= nil, "both team flags (item_tfgoal) spawned")
t.check(drop1 ~= nil, "team 1 capture dropoff (info_tfgoal) spawned")
t.check(teamSpawns >= 40, "info_player_teamspawn points present")

-- two clients over the real wire ------------------------------------------
-- pants colors matter: the FIRST player to join a team seeds that team's
-- color from his own pants (TeamFortress_TeamSetColor)
type Link = { cl: any, sc: any, queue: { buffer } }
local function link(slot: number, name: string, color: string): Link
	local L = { cl = qwcl.new(fsys), sc = nil :: any, queue = {} :: { buffer } }
	L.sc = qwsv.wireConnect(
		svr,
		slot,
		{ name = name, topcolor = color, bottomcolor = color },
		function(packet: buffer)
			table.insert(L.queue, packet)
		end
	)
	qwcl.connect(L.cl, function(packet: buffer)
		qwsv.executeClientMessage(svr, L.sc, packet)
	end)
	return L
end
local A = link(1, "bluesoldier", "13") -- pants 13 = blue, seeds team 1
local B = link(2, "redscout", "4") -- pants 4 = red, seeds team 2

for _ = 1, 60 do
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
t.check(A.sc.spawned == true and B.sc.spawned == true, "both clients completed the QW handshake")

type CmdOpts = { yaw: number?, buttons: number?, impulse: number?, forward: number? }
local function cmd(opts: CmdOpts?)
	local o: CmdOpts = opts or {}
	return {
		angles = vector.create(0, o.yaw or 0, 0),
		forwardmove = o.forward or 0,
		sidemove = 0,
		upmove = 0,
		buttons = o.buttons or 0,
		impulse = o.impulse or 0,
		msec = 50,
	}
end
local function tick(acmd: any, bcmd: any)
	qwcl.sendCmd(A.cl, acmd or cmd())
	qwcl.sendCmd(B.cl, bcmd or cmd())
	qwsv.frame(svr, 0.05)
	qwsv.sendClientMessages(svr)
	for _, L in { A, B } do
		while #L.queue > 0 do
			qwcl.processPacket(L.cl, table.remove(L.queue, 1) :: buffer)
		end
	end
end
local function run(n: number)
	for _ = 1, n do
		tick(nil, nil)
	end
end

-- Quake colored text sets the high bit; strip it to match message text
local function deglyph(s: string): string
	local out = table.create(#s)
	for i = 1, #s do
		table.insert(out, string.char(bit32.band(string.byte(s, i), 0x7f)))
	end
	return table.concat(out)
end
-- wire prints arrive in pieces (QC bprints "name", " has started Team No ",
-- "1.\n" as separate messages), so match against the concatenated stream
-- from AFTER the `since` count
local function sawPrint(L: Link, pattern: string, since: number?): boolean
	local parts = {}
	for i = (since or 0) + 1, #L.cl.prints do
		table.insert(parts, L.cl.prints[i].text)
	end
	return deglyph(table.concat(parts)):find(pattern) ~= nil
end
local function sawCenter(L: Link, pattern: string, since: number?): boolean
	local parts = {}
	for i = (since or 0) + 1, #L.cl.centerprints do
		table.insert(parts, L.cl.centerprints[i])
	end
	return deglyph(table.concat(parts)):find(pattern) ~= nil
end

local function teleport(ed: any, to: vector)
	vmlib.edSetVector(ed, ent.origin, to)
	vmlib.edSetVector(ed, ent.velocity, vector.zero)
	qwworld.linkEdict(svr.world, ed, true)
end

run(10) -- let PutClientInServer settle
local playerA, playerB = A.sc.edict, B.sc.edict

-- everyone starts in Observer mode (playerclass 0, no team)
t.eq(vmlib.edFloat(playerA, playerclassOfs), 0, "fresh client is an observer (playerclass 0)")
t.eq(vmlib.edFloat(playerA, teamNoOfs), 0, "fresh client has no team")

-- TEAM JOIN: impulse 140 = join team 1, 141 = join team 2 ------------------
tick(cmd({ impulse = 140 }), cmd())
run(3)
t.eq(vmlib.edFloat(playerA, teamNoOfs), 1, "impulse 140 joined team 1")
t.check(sawPrint(A, "has joined Team No 1"), "team-join broadcast reached the client")
tick(cmd(), cmd({ impulse = 141 }))
run(3)
t.eq(vmlib.edFloat(playerB, teamNoOfs), 2, "impulse 141 joined team 2")

-- CLASS PICK: impulse 100+class; the respawn applies it (deathmatch 3) -----
-- A: 103 = Soldier, B: 101 = Scout
tick(cmd({ impulse = 103 }), cmd({ impulse = 101 }))
for _ = 1, 40 do
	run(1)
	if vmlib.edFloat(playerA, playerclassOfs) == 3 and vmlib.edFloat(playerB, playerclassOfs) == 1 then
		break
	end
end
t.eq(vmlib.edFloat(playerA, playerclassOfs), 3, "impulse 103 made A a Soldier (PC_SOLDIER)")
t.eq(vmlib.edFloat(playerB, playerclassOfs), 1, "impulse 101 made B a Scout (PC_SCOUT)")

-- per-class movement speeds land in the QW maxspeed field the engine
-- honors (Soldier 240, Scout 450 — DEFS.H)
local optfield = svr.qdefs.optfield or {}
t.check(optfield.maxspeed ~= nil, "TF declares the QC maxspeed field")
t.eq(vmlib.edFloat(playerA, optfield.maxspeed), 240, "Soldier maxspeed is 240")
t.eq(vmlib.edFloat(playerB, optfield.maxspeed), 450, "Scout maxspeed is 450")

-- class loadout: Soldier respawns with his rocket launcher ammo (4 rockets)
t.check(vmlib.edFloat(playerA, ent.ammo_rockets) > 0, "Soldier spawned with rocket ammo")
t.check(vmlib.edFloat(playerA, ent.health) == 100, "Soldier spawned at 100 health")

-- FLAG GRAB: team 1 soldier steals the enemy flag from the north basement --
-- (the goal named "Team 2 flag" has team_no=1: it is the one team 1 can
-- activate — TF goals name the flag by the base it sits in)
local flag2Home = vmlib.edVector(flag2, ent.origin)
local cpBefore = #A.cl.centerprints
teleport(playerA, flag2Home + vector.create(0, 0, 1))
run(10)
t.check(sawCenter(A, "You have the enemy flag", cpBefore), "grab centerprint: You have the enemy flag")
t.eq(vmlib.edFloat(flag2, ent.solid), 0, "carried flag went non-solid")

-- CAPTURE: carry it home to the team 1 dropoff ------------------------------
local cpBeforeCap = #A.cl.centerprints
teleport(playerA, vmlib.edVector(drop1, ent.origin) + vector.create(0, 0, 1))
run(10)
t.check(sawCenter(A, "CAPTURED the ENEMY flag", cpBeforeCap), "capture centerprint: You CAPTURED the ENEMY flag!")

-- the captured flag returns home and is stealable again
local homeAgain = false
for _ = 1, 100 do
	run(1)
	eachEdict(function(ed)
		if
			classnameOf(ed) == "item_tfgoal"
			and netnameOf(ed):find("Team 2")
			and vector.magnitude(vmlib.edVector(ed, ent.origin) - flag2Home) < 1
			and vmlib.edFloat(ed, ent.solid) ~= 0
		then
			homeAgain = true
		end
	end)
	if homeAgain then
		break
	end
end
t.check(homeAgain, "captured flag returned home, touchable again")

t.finish("test_scenario_tf")
