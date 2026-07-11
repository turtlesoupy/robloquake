--!strict
-- SCENARIO: Rocket Arena over the LibreQuake base (the lq-arena preset,
-- modepresets.luau) — the arena gamedir stacked on lq1 instead of id1.
-- The new risk vs test_scenario_ra (which proves the mod's round logic
-- over id1) is ASSET RESOLUTION: RA's progs precache stock id1 model and
-- sound names, and every one must resolve through the arena→lq1
-- searchpath fallthrough. So this test spawns crandome on the lq1 stack,
-- asserts every server precache resolves in the vfs, then smoke-runs a
-- round (queue → countdown → FIGHT → loadout → rocket kill) to prove the
-- mod actually plays over the replacement content.
--
-- Staging (gitignored): external_assets/rocketarena/ (see
-- docs/mods-licenses.md — LOCAL/DEV ONLY) + external_assets/librequake/.
local t = require("./testutil")
local fs = require("@lune/fs")
local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local mathlib = require("../src/shared/engine/common/mathlib")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwworld = require("../src/shared/engine/qw/qwworld")

local LQ1 = "external_assets/librequake/full/id1/"
local RA = "external_assets/rocketarena/"
if not fs.isFile(RA .. "qwprogs.dat") or not fs.isFile(RA .. "pak0.pak") then
	print("test_scenario_lq_arena: SKIPPED (rocketarena mod not staged)")
	return
end
if not fs.isFile(LQ1 .. "pak0.pak") then
	print("test_scenario_lq_arena: SKIPPED (librequake not staged)")
	return
end

-- lq1 base paks, then the arena gamedir on top (searched first)
local fsys = vfs.new()
for _, name in { "pak0", "pak1" } do
	if fs.isFile(LQ1 .. name .. ".pak") then
		vfs.addPack(fsys, pak.load("lq1/" .. name, buffer.fromstring(fs.readFile(LQ1 .. name .. ".pak"))))
	end
end
vfs.addPack(fsys, pak.load("arena/pak0", buffer.fromstring(fs.readFile(RA .. "pak0.pak"))))
vfs.addPack(
	fsys,
	pak.load(
		"arena/pak1",
		t.writePak({ { name = "qwprogs.dat", data = buffer.fromstring(fs.readFile(RA .. "qwprogs.dat")) } })
	)
)

local svr = qwsv.newGame(fsys)
svr.print = function(_s: string) end
-- the mod's rotate.cfg mechanism (applied by qwserver at boot in Studio)
svr.localinfo["crandome"] = "2pyramid"
qwsv.spawnServer(svr, "crandome")
t.check(svr.active == true, "rocket arena qwprogs spawned crandome over lq1")

-- every server precache must resolve through the arena→lq1 stack: this is
-- the whole point of the lq base swap (RA references stock id1 names)
local missingModels = {}
for i, name in svr.model_precache do
	-- [1] is the empty sentinel; "*N" are the map's inline brush submodels
	if name ~= "" and name:sub(1, 1) ~= "*" and not vfs.loadFile(fsys, name) then
		table.insert(missingModels, name)
	end
	local _ = i
end
t.eq(table.concat(missingModels, " "), "", "all model precaches resolve on the lq1 stack")
local missingSounds = {}
for _, name in svr.sound_precache do
	if name ~= "" and not vfs.loadFile(fsys, "sound/" .. name) then
		table.insert(missingSounds, name)
	end
end
-- known lq1 gap: LibreQuake names its slime-burn sound slmbrn2.wav (no
-- "i"), so id-QC's slimbrn2.wav precache never resolves — at runtime
-- that's one warn + a silent slime-pain, nothing more. Pin it so any NEW
-- gap fails the test.
t.eq(table.concat(missingSounds, " "), "player/slimbrn2.wav", "sound precaches resolve on the lq1 stack (only the known slmbrn2 naming gap)")

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
local function sawPrint(L: Link, pattern: string): boolean
	for i = 1, #L.cl.prints do
		if deglyph(L.cl.prints[i].text):find(pattern) then
			return true
		end
	end
	return false
end
local function sawCenter(L: Link, pattern: string): boolean
	for i = 1, #L.cl.centerprints do
		if deglyph(L.cl.centerprints[i]):find(pattern) then
			return true
		end
	end
	return false
end

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

-- queue → countdown → FIGHT
local fought = false
for _ = 1, 300 do
	run(1, 0)
	if sawCenter(A, "FIGHT!") then
		fought = true
		break
	end
end
t.check(fought, "countdown reached FIGHT! on the lq1 stack")
t.check(sawPrint(A, "Welcome To Rocket Arena"), "RA welcome message")
t.check(sawPrint(A, "is the new challenger"), "bravo announced as the challenger")
run(4, 0)

-- arena loadout still issues over the replacement content
t.eq(vmlib.edFloat(playerA, ent.health), 100, "arena spawn health 100")
t.eq(vmlib.edFloat(playerA, ent.armorvalue), 200, "arena loadout: 200 armor")
t.eq(vmlib.edFloat(playerA, ent.ammo_rockets), 60, "arena loadout: 60 rockets")

-- one rocket kill: exercises the rocket model/sounds resolved from lq1
local fwd = mathlib.angleVectors(vector.create(0, yawA, 0))
vmlib.edSetVector(playerB, ent.origin, vmlib.edVector(playerA, ent.origin) + fwd * 250)
vmlib.edSetVector(playerB, ent.velocity, vector.zero)
qwworld.linkEdict(svr.world, playerB, false)
for _ = 1, 600 do
	run(1, 1)
	if vmlib.edFloat(playerB, ent.health) <= 0 then
		break
	end
end
t.check(vmlib.edFloat(playerB, ent.health) <= 0, "challenger died to rockets over lq1")
run(40, 0)
t.check(sawPrint(A, "Victory"), "winner announcement")

t.finish("test_scenario_lq_arena")
