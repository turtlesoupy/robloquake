--!strict
-- Perf evidence for the 2026-07-06 audit G-rows: measures the hot paths
-- the audit flagged. Run: `lune run tools/bench_audit.luau` (repo root).
-- Numbers are per-machine; the point is a re-runnable measurement and a
-- gc-allocation count for the scratch-reuse claims.

local fs = require("@lune/fs")
local t = require("../tests/testutil")
local vmlib = require("../src/shared/engine/progs/vm")
local qwsv = require("../src/shared/engine/qw/qwsv")
local pmovelib = require("../src/shared/engine/qw/pmove")

local gamefs = t.gameFs()
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(gamefs, qwprogs)
svr.print = function(_s: string) end
qwsv.spawnServer(svr, "e1m1")

local function bench(name: string, iters: number, fn: () -> ())
	local kb0 = collectgarbage("count") :: any
	local t0 = os.clock()
	for _ = 1, iters do
		fn()
	end
	local dt = os.clock() - t0
	local kb1 = collectgarbage("count")
	print(
		string.format(
			"%-28s %8d iters  %8.1f us/iter  %10.1f KB alloc (%.2f KB/iter)",
			name,
			iters,
			dt / iters * 1e6,
			kb1 - kb0,
			(kb1 - kb0) / iters
		)
	)
end

-- 1. QuakeC VM: StartFrame + a full physics tick (thinks, touch chains)
bench("SV_Physics frame (VM+phys)", 2000, function()
	qwsv.frame(svr, 0.014)
end)

-- 2. pmove: a full PlayerMove over the world + box physents
local movevars: pmovelib.MoveVars = {
	gravity = 800,
	stopspeed = 100,
	maxspeed = 320,
	spectatormaxspeed = 500,
	accelerate = 10,
	airaccelerate = 10,
	wateraccelerate = 10,
	friction = 4,
	waterfriction = 4,
	entgravity = 1,
}
local physents: { pmovelib.PhysEnt } = { { model = svr.worldmodel :: any, origin = vector.zero } }
for i = 1, 12 do
	table.insert(physents, {
		origin = vector.create(480 + i * 40, -352, 88),
		mins = vector.create(-16, -16, -24),
		maxs = vector.create(16, 16, 32),
	})
end
bench("playerMove (12 box physents)", 20000, function()
	local pm: pmovelib.PlayerMove = {
		origin = vector.create(480, -352, 88),
		angles = vector.create(0, 90, 0),
		velocity = vector.create(200, 0, 0),
		oldbuttons = 0,
		waterjumptime = 0,
		dead = false,
		spectator = false,
		physents = physents,
		cmd = { msec = 14, angles = vector.create(0, 90, 0), forwardmove = 400, sidemove = 0, upmove = 0, buttons = 0, impulse = 0 },
		numtouch = 0,
		touchindex = {},
		onground = -1,
		waterlevel = 0,
		watertype = 0,
	}
	pmovelib.playerMove(pm, movevars)
end)

-- 3. per-reply entity encode: fatPVS + players + entities for one client
local sc = qwsv.wireConnect(svr, 1, { name = "bench" }, function(_p: buffer) end)
sc.spawned = true
local msg = require("../src/shared/engine/common/msg")
local out = msg.newBuf(1450, true)
bench("reply encode (pvs+players+ents)", 20000, function()
	msg.clear(out)
	local pvs = qwsv.fatPVS(svr, vector.create(480, -352, 88))
	qwsv.writePlayersToClient(svr, sc, pvs, out)
	qwsv.writeEntitiesToClient(svr, sc, out)
end)

print("done")
