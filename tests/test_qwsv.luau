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
	qwsv.runCmd(svr, client, {
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
	qwsv.runCmd(svr, client, {
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
qwsv.runCmd(svr, client, {
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

t.finish("test_qwsv")
