--!strict
-- SCENARIO S5: Threewave CTF 4.21 — an UNMODIFIED third-party QuakeWorld mod
-- running via gamedir stacking (id1 base + threewave paks + the mod's shipped
-- qwprogs.dat, exactly as tools/build_assets.py stages it). Two clients
-- connect over the real loopback wire, get team-assigned, and play the CTF
-- loop: enemy flag grab, capture (+15 frags, flag rehomes), carrier death
-- drops the flag, defender touch returns it, grapple fires, runes spawn and
-- are picked up. The mod's progs/QC are NEVER edited; everything here runs
-- on the stock engine ABI-by-name machinery.
--
-- Staging (gitignored, never committed): external_assets/threewave/ from
-- github.com/Jason2Brownlee/ThreeWaveCTF bin/3wave421d.zip + 3wctfc.zip
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
local TW = "external_assets/threewave/"
if not fs.isFile(TW .. "qwprogs.dat") or not fs.isFile(ID1 .. "pak1.pak") then
	print("test_scenario_ctf: SKIPPED (threewave mod or registered id1 assets not staged)")
	return
end

-- gamedir stack: id1 base, then the mod's paks, then its loose files as a
-- synthetic pak — the same shape tools/build_assets.py ships to the place
local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("id1/" .. name, buffer.fromstring(fs.readFile(ID1 .. name .. ".pak"))))
end
for _, name in { "pak0", "pak1" } do
	vfs.addPack(fsys, pak.load("threewave/" .. name, buffer.fromstring(fs.readFile(TW .. name .. ".pak"))))
end
vfs.addPack(
	fsys,
	pak.load(
		"threewave/pak2",
		t.writePak({ { name = "qwprogs.dat", data = buffer.fromstring(fs.readFile(TW .. "qwprogs.dat")) } })
	)
)

local svr = qwsv.newGame(fsys) -- qwprogs.dat comes from the searchpath stack
svr.print = function(_s: string) end
-- the mod's own shipped server.cfg settings (teamplay "419?QWCTF4.21")
cvarlib.setValue(svr.cvars, "teamplay", 419)
cvarlib.setValue(svr.cvars, "timelimit", 35)
cvarlib.setValue(svr.cvars, "fraglimit", 150)
qwsv.spawnServer(svr, "ctf2m3")
t.check(svr.active == true, "threewave qwprogs spawned ctf2m3")

local ent = svr.qdefs.ent
local function classnameOf(ed: any): string
	return vmlib.edString(svr.vm, ed, ent.classname)
end
local function modelOf(ed: any): string
	return vmlib.edString(svr.vm, ed, ent.model)
end
local function eachEdict(f: (ed: any) -> ())
	for i = 1, svr.vm.num_edicts do
		local ed = vmlib.edictNum(svr.vm, i - 1)
		if not ed.free then
			f(ed)
		end
	end
end

-- the map's CTF layout spawned
local flag1: any, flag2: any = nil, nil
local teamSpawns = { 0, 0 }
eachEdict(function(ed)
	local cn = classnameOf(ed)
	if cn == "item_flag_team1" then
		flag1 = ed
	elseif cn == "item_flag_team2" then
		flag2 = ed
	elseif cn == "info_player_team1" then
		teamSpawns[1] += 1
	elseif cn == "info_player_team2" then
		teamSpawns[2] += 1
	end
end)
t.check(flag1 ~= nil and flag2 ~= nil, "both team flags spawned")
t.check(teamSpawns[1] >= 8 and teamSpawns[2] >= 8, "team spawn points present")

-- two clients over the real wire ------------------------------------------
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
local A = link(1, "redguy", "4") -- pants 4 = red team
local B = link(2, "blueguy", "13") -- pants 13 = blue team

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

-- SV_Spawn_f seeds the mod-declared QC gravity/maxspeed fields (audit
-- D10): Threewave's grapple reads self.gravity before assigning it
local optfield = svr.qdefs.optfield or {}
t.check(optfield.gravity ~= nil, "threewave declares the QC gravity field")
t.check(vmlib.edFloat(A.sc.edict, optfield.gravity) == 1, "spawn seeded self.gravity = 1")
t.check(
	optfield.maxspeed ~= nil and vmlib.edFloat(A.sc.edict, optfield.maxspeed) == 320,
	"spawn seeded self.maxspeed = sv_maxspeed"
)

local function cmd(opts: { yaw: number?, buttons: number?, impulse: number?, forward: number? }?)
	local o = opts or {}
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
local function sawPrint(L: Link, pattern: string, since: number?): boolean
	for i = since or 1, #L.cl.prints do
		if deglyph(L.cl.prints[i].text):find(pattern) then
			return true
		end
	end
	return false
end

local function teleport(ed: any, to: vector)
	vmlib.edSetVector(ed, ent.origin, to)
	vmlib.edSetVector(ed, ent.velocity, vector.zero)
	qwworld.linkEdict(svr.world, ed, true)
end

run(10) -- let PutClientInServer/team think chains + place_flag droptofloor settle
local flag1Home = vmlib.edVector(flag1, ent.origin)
local flag2Home = vmlib.edVector(flag2, ent.origin)

-- team assignment from pants color (TeamAssign/TeamCheckLock, color lock 32)
t.check(sawPrint(A, "assigned to"), "team auto-assignment message reached the client")
local playerA, playerB = A.sc.edict, B.sc.edict
local aSpawn = vmlib.edVector(playerA, ent.origin)
local bSpawn = vmlib.edVector(playerB, ent.origin)
t.check(
	vector.magnitude(aSpawn - flag1Home) < vector.magnitude(aSpawn - flag2Home),
	"red player spawned at the red base"
)
t.check(
	vector.magnitude(bSpawn - flag2Home) < vector.magnitude(bSpawn - flag1Home),
	"blue player spawned at the blue base"
)

-- runes spawned (SpawnRunes: four sigil-model entities, blank classname)
local runeOrigins: { vector } = {}
eachEdict(function(ed)
	if modelOf(ed):find("progs/end%d%.mdl") then
		table.insert(runeOrigins, vmlib.edVector(ed, ent.origin))
	end
end)
t.eq(#runeOrigins, 4, "all four runes spawned on the map")

-- FLAG GRAB: red touches the blue flag ------------------------------------
teleport(playerA, flag2Home + vector.create(0, 0, 1))
run(10)
t.check(sawPrint(A, "got the BLUE flag"), "grab broadcast: got the BLUE flag")
t.eq(vmlib.edFloat(flag2, ent.solid), 0, "carried flag is non-solid")

-- CAPTURE: carrier brings it home ------------------------------------------
local fragsBefore = vmlib.edFloat(playerA, ent.frags)
teleport(playerA, flag1Home + vector.create(0, 0, 1))
run(10)
t.check(sawPrint(A, "captured the BLUE flag"), "capture broadcast: captured the BLUE flag")
t.eq(vmlib.edFloat(playerA, ent.frags) - fragsBefore, 15, "capture bonus is +15 frags")
local f2now = vmlib.edVector(flag2, ent.origin)
t.check(vector.magnitude(f2now - flag2Home) < 1, "captured flag respawned at home")
t.eq(vmlib.edFloat(flag2, ent.solid), 1, "rehomed flag is touchable again")

-- DROP + RETURN: carrier dies, defender touch-returns ----------------------
teleport(playerA, flag2Home + vector.create(0, 0, 1))
run(10)
t.check(sawPrint(A, "got the BLUE flag", #A.cl.prints - 6), "red re-grabbed the blue flag")

-- stage the kill: blue shoots the carrier point-blank (spawn shotgun)
local killSpot = bSpawn
teleport(playerB, killSpot)
local yawB = 90
local fwd = vector.create(math.cos(math.rad(yawB)), math.sin(math.rad(yawB)), 0)
teleport(playerA, killSpot + fwd * 80)
local printsBeforeKill = #B.cl.prints
for _ = 1, 400 do
	tick(cmd(), cmd({ yaw = yawB, buttons = 1 }))
	if vmlib.edFloat(playerA, ent.health) <= 0 then
		break
	end
end
t.check(vmlib.edFloat(playerA, ent.health) <= 0, "flag carrier died")
run(5)

-- the flag dropped near the corpse (a tossed, solid item_flag_team2)
local dropped: any = nil
eachEdict(function(ed)
	if ed ~= flag2 and classnameOf(ed) == "item_flag_team2" then
		dropped = ed
	end
end)
if dropped == nil and vector.magnitude(vmlib.edVector(flag2, ent.origin) - flag2Home) > 1 then
	dropped = flag2 -- some CTF builds toss the original entity instead
end
t.check(dropped ~= nil, "death dropped the carried flag in the field")
t.check(sawPrint(B, "lost the BLUE flag", printsBeforeKill), "loss broadcast: lost the BLUE flag")

-- let the tossed flag LAND before returning it: the QC teleports the
-- returned flag home without re-grounding it, and relies on the landed
-- FL_ONGROUND to keep toss physics inert there (authentic QW behavior —
-- returning a still-airborne flag loses it through the floor on real
-- servers too)
local FL_ONGROUND = 512
for _ = 1, 100 do
	run(1)
	if bit32.band(vmlib.edFloat(dropped, ent.flags), FL_ONGROUND) ~= 0 then
		break
	end
end
t.check(bit32.band(vmlib.edFloat(dropped, ent.flags), FL_ONGROUND) ~= 0, "dropped flag landed")

teleport(playerB, vmlib.edVector(dropped, ent.origin) + vector.create(0, 0, 1))
run(10)
t.check(sawPrint(B, "returned the BLUE flag", printsBeforeKill), "return broadcast: returned the BLUE flag")
run(10)
-- the regenerated home flag may be a fresh entity: rescan rather than
-- trusting the pre-drop reference
local homeAgain = false
eachEdict(function(ed)
	if
		classnameOf(ed) == "item_flag_team2"
		and vector.magnitude(vmlib.edVector(ed, ent.origin) - flag2Home) < 1
		and vmlib.edFloat(ed, ent.solid) == 1
	then
		homeAgain = true
	end
end)
t.check(homeAgain, "returned flag is back at home base")

-- GRAPPLE: select with impulse 22, fire, hook entity flies ------------------
-- (redguy respawns on death automatically on the next +attack-free tick)
for _ = 1, 40 do
	tick(cmd({ buttons = 1 }), cmd()) -- fire button also respawns the dead
	if vmlib.edFloat(playerA, ent.health) > 0 then
		break
	end
end
t.check(vmlib.edFloat(playerA, ent.health) > 0, "carrier respawned for the grapple test")
local printsBeforeHook = #A.cl.prints
tick(cmd({ impulse = 22 }), cmd())
run(2)
t.check(sawPrint(A, "Grappling Hook Selected", printsBeforeHook), "impulse 22 selects the grapple")
for _ = 1, 6 do
	tick(cmd({ buttons = 1 }), cmd())
end
-- mod-added entity field, resolved from the mod's own fielddefs by name —
-- the same mechanism qwdefs uses for the standard ABI
local hookOutDef = svr.progs.fielddefsByName["hook_out"]
t.check(hookOutDef ~= nil, "mod-added field hook_out present in fielddefs")
local hookOut = vmlib.edFloat(playerA, hookOutDef.ofs)
t.eq(hookOut, 1, "mod-specific field .hook_out set while grappling")
local hook: any = nil
eachEdict(function(ed)
	if modelOf(ed):find("star%.mdl") or classnameOf(ed) == "hook" then
		hook = ed
	end
end)
t.check(hook ~= nil, "grapple hook entity exists in the world")
for _ = 1, 4 do
	tick(cmd(), cmd()) -- release +attack retracts
end

-- RUNE PICKUP ---------------------------------------------------------------
-- rescan and pick a LANDED, still-pickupable rune (solid trigger; carried
-- runes go non-solid). blueguy does the pickup — he has clean hands
local runeEd: any = nil
eachEdict(function(ed)
	if
		modelOf(ed):find("progs/end%d%.mdl")
		and vmlib.edFloat(ed, ent.solid) == 1
		and bit32.band(vmlib.edFloat(ed, ent.flags), FL_ONGROUND) ~= 0
	then
		runeEd = runeEd or ed
	end
end)
t.check(runeEd ~= nil, "a pickupable rune remains on the map")
-- the QW 4.21 build announces rune pickups with no chat text; the evidence
-- is the state change: a rune bit lands in the mod's own player_flag field
-- and the rune entity goes non-solid (carried)
local pfDef = svr.progs.fielddefsByName["player_flag"]
local pfBefore = vmlib.edFloat(playerB, pfDef.ofs)
teleport(playerB, vmlib.edVector(runeEd, ent.origin) + vector.create(0, 0, 1))
run(10)
local pfAfter = vmlib.edFloat(playerB, pfDef.ofs)
t.check(pfAfter ~= pfBefore and pfAfter % 16 ~= pfBefore % 16, "rune bit set in the mod's player_flag field")
t.eq(vmlib.edFloat(runeEd, ent.solid), 0, "picked-up rune went non-solid (carried)")

t.finish("test_scenario_ctf")
