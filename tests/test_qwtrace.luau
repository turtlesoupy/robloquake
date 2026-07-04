--!strict
-- QW server-side collision (qwworld.luau = QW world.c) against ground
-- truth and against its own areanode contract:
--  1) the compiled-C trace fixture (tools/trace_truth.c, verbatim
--     WinQuake world.c hull code — QW's hull math is the same source)
--     replayed through qwworld.recursiveHullCheck/hullPointContents;
--  2) a live areanode battery on a booted qwprogs e1m1: SV_Move clips
--     on a linked SOLID_BSP door and a SOLID_SLIDEBOX player box,
--     unlink/relink toggles the clip, testEntityPosition agrees.
local t = require("./testutil")
local fs = require("@lune/fs")
local vfslib = require("../src/shared/engine/common/vfs")
local bsplib = require("../src/shared/engine/bsp/bsp")
local qwworld = require("../src/shared/engine/qw/qwworld")
local qwsv = require("../src/shared/engine/qw/qwsv")
local vmlib = require("../src/shared/engine/progs/vm")
local mathlib = require("../src/shared/engine/common/mathlib")

local fsys = t.gameFs()
local buf = vfslib.loadFile(fsys, "maps/e1m1.bsp")
assert(buf)
local wm = bsplib.load("maps/e1m1.bsp", buf)[1]

--------------------------------------------------------------------------
-- 1) fixture replay (same battery as tests/test_trace.luau runs against
-- the NQ world module)
local fixture = fs.readFile("tests/fixtures/trace_truth.txt")
local lines = fixture:split("\n")

local function nums(line: string): { number }
	local out = {}
	for w in line:gmatch("[^ ]+") do
		table.insert(out, tonumber(w) :: number)
	end
	return out
end

local li = 1
t.eq(lines[li], "POINTS", "fixture header")
li += 1

local pointCount = 0
local pointMismatch = 0
while lines[li] ~= "TRACES" do
	local v = nums(lines[li])
	local p = vector.create(v[4], v[5], v[6])
	for h = 1, 3 do
		local hull = wm.hulls[h]
		if qwworld.hullPointContents(hull, hull.firstclipnode, p) ~= v[h] then
			pointMismatch += 1
		end
	end
	pointCount += 1
	li += 1
end
t.eq(pointCount, 200, "point count")
t.eq(pointMismatch, 0, "qwworld point contents match the compiled C for all 200 points x 3 hulls")
li += 1

local traceCount = 0
local mismatches = 0
while li <= #lines and lines[li] ~= "" do
	local hullLines = { nums(lines[li]), nums(lines[li + 1]), nums(lines[li + 2]) }
	local seg = lines[li + 3]
	assert(seg:sub(1, 4) == "SEG ", "expected SEG line, got: " .. seg)
	local sv = nums(seg:sub(5))
	local p1 = vector.create(sv[1], sv[2], sv[3])
	local p2 = vector.create(sv[4], sv[5], sv[6])

	for h = 1, 3 do
		local want = hullLines[h]
		local hull = wm.hulls[h]
		local trace: qwworld.Trace = {
			allsolid = true,
			startsolid = false,
			inopen = false,
			inwater = false,
			fraction = 1,
			endpos = p2,
			planeNormal = vector.zero,
			planeDist = 0,
			ent = nil,
		}
		qwworld.recursiveHullCheck(hull, hull.firstclipnode, 0, 1, p1, p2, trace)

		local ok = (trace.allsolid == (want[1] == 1))
			and (trace.startsolid == (want[2] == 1))
			and (trace.inopen == (want[3] == 1))
			and (trace.inwater == (want[4] == 1))
			and math.abs(trace.fraction - want[5]) < 1e-4
			and math.abs(trace.endpos.x - want[6]) < 0.01
			and math.abs(trace.endpos.y - want[7]) < 0.01
			and math.abs(trace.endpos.z - want[8]) < 0.01
			and math.abs(trace.planeNormal.x - want[9]) < 1e-5
			and math.abs(trace.planeNormal.y - want[10]) < 1e-5
			and math.abs(trace.planeNormal.z - want[11]) < 1e-5
			and math.abs(trace.planeDist - want[12]) < 0.01
		if not ok then
			mismatches += 1
		end
	end
	traceCount += 1
	li += 4
end
t.check(traceCount > 100, `trace count ({traceCount})`)
t.eq(mismatches, 0, "qwworld hull traces match the compiled C on every segment x 3 hulls")

--------------------------------------------------------------------------
-- 2) live areanode battery on a booted qwprogs server
local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
local svr = qwsv.newGame(fsys, qwprogs)
svr.print = function(_s: string) end
qwsv.spawnServer(svr, "e1m1")
t.check(svr.active, "qwprogs e1m1 booted (SV_ClearWorld + links ran)")
local vm = svr.vm
local ent = svr.qdefs.ent
local qd = require("../src/shared/engine/quakedef")

-- find a door the areanode attributes cleanly: qwprogs sets classname
-- to "door"; many doors extend into their frames, so scan for one whose
-- crossing segment reports the door itself as the hit entity
local door: vmlib.Edict? = nil
local from, to = vector.zero, vector.zero
local tr: qwworld.Trace? = nil
for i = 1, vm.num_edicts - 1 do
	local e = vm.edicts[i + 1]
	if e.free or vmlib.edString(vm, e, ent.classname) ~= "door" then
		continue
	end
	local dmin = vmlib.edVector(e, ent.absmin)
	local dmax = vmlib.edVector(e, ent.absmax)
	local dctr = (dmin + dmax) / 2
	local span = dmax - dmin
	local axis = if span.x < span.y then vector.create(1, 0, 0) else vector.create(0, 1, 0)
	local halfThin = (if span.x < span.y then span.x else span.y) / 2
	from = dctr - axis * (halfThin + 48)
	to = dctr + axis * (halfThin + 48)
	local probe = qwworld.move(svr.world, from, vector.zero, vector.zero, to, 0, vm.edicts[1])
	if probe.fraction < 1 and probe.ent == e then
		door = e
		tr = probe
		break
	end
end
assert(door and tr, "found a door the trace attributes cleanly")
local trFraction = (tr :: qwworld.Trace).fraction
t.check(trFraction < 1, `SV_Move clips through the areanode ({string.format("%.3f", trFraction)})`)
t.check((tr :: qwworld.Trace).ent == door, "SV_ClipToLinks attributed the hit to the door edict")

-- SV_UnlinkEdict removes it from the clip lists; the same move no
-- longer hits the door
qwworld.unlinkEdict(door)
local tr2 = qwworld.move(svr.world, from, vector.zero, vector.zero, to, 0, vm.edicts[1])
t.check(tr2.ent ~= door, "unlinked door no longer clips")

-- relink restores the clip
qwworld.linkEdict(svr.world, door, false)
local tr3 = qwworld.move(svr.world, from, vector.zero, vector.zero, to, 0, vm.edicts[1])
t.check(tr3.ent == door and math.abs(tr3.fraction - trFraction) < 1e-6, "relinked door clips identically")

-- player-size hull vs point hull: SV_HullForEntity picks hull 1 for a
-- player-sized box against the bsp door, so the box trace stops earlier
local pmins = vector.create(-16, -16, -24)
local pmaxs = vector.create(16, 16, 32)
local trBox = qwworld.move(svr.world, from, pmins, pmaxs, to, 0, vm.edicts[1])
t.check(trBox.fraction < trFraction, "player-hull trace stops before the point trace (hull selection)")

-- SOLID_SLIDEBOX bbox clipping: connect two clients and trace into
-- one with the other as passedict (the real shotgun-trace shape; a
-- world-edict passedict would skip unowned entities through the
-- authentic owner==0 quirk in SV_ClipToLinks)
qwsv.connectClient(svr, 1, { name = "tracee" })
qwsv.connectClient(svr, 2, { name = "shooter" })
local pl = svr.clients[1].edict
local shooter = svr.clients[2].edict
local porg = vmlib.edVector(pl, ent.origin)
local pyaw = vmlib.edVector(pl, ent.angles).y
local pfwd = mathlib.angleVectors(vector.create(0, pyaw, 0))
local eyeFrom = porg + pfwd * 64 + vector.create(0, 0, 10)
local ptr = qwworld.move(svr.world, eyeFrom, vector.zero, vector.zero, porg + vector.create(0, 0, 10), 0, shooter)
t.check(ptr.fraction < 1 and ptr.ent == pl, "SV_Move clips on the spawned player's SOLID_SLIDEBOX box (SV_InitBoxHull path)")

-- testEntityPosition: free at spawn, solid inside the door
t.check(qwworld.testEntityPosition(svr.world, pl) == nil, "player spawn spot tests free")
local dmin2 = vmlib.edVector(door, ent.absmin)
local dmax2 = vmlib.edVector(door, ent.absmax)
local dctr2 = (dmin2 + dmax2) / 2
vmlib.edSetVector(pl, ent.origin, dctr2)
t.check(qwworld.testEntityPosition(svr.world, pl) ~= nil, "player inside the door tests solid")
vmlib.edSetVector(pl, ent.origin, porg)
qwworld.linkEdict(svr.world, pl, false)

local _ = qd
t.finish("test_qwtrace")
