--!strict
--!optimize 2
-- Monster movement — port of WinQuake sv_move.c (SV_CheckBottom,
-- SV_movestep, SV_StepDirection, SV_NewChaseDir, SV_MoveToGoal) plus
-- PF_changeyaw from pr_cmds.c (which SV_StepDirection calls into).

local mathlib = require("../common/mathlib")
local defs = require("../progs/defs")
local vmlib = require("../progs/vm")
local qd = require("../quakedef")
local svlib = require("./sv")
local nqworld = require("./world")

local sv_move = {}

local STEPSIZE = 18
local DI_NODIR = -1

-- The NQ server uses the static progdefs offsets and the NQ world
-- module; the QW server carries its own ABI (svr.qdefs, name-resolved
-- from the loaded qwprogs) and its own world module (svr.worldMod).
-- Resolving per call keeps ONE sv_move.c port serving both engines.
local function abi(svr: any): ({ [string]: number }, { [string]: number }, any)
	local q = svr.qdefs
	return (if q then q.ent else defs.ent), (if q then q.glob else defs.glob), (svr.worldMod or nqworld)
end

local function randOf(svr: any): number
	return if svr.rand then svr.rand(svr) else svlib.rand(svr)
end

-- SV_CheckBottom: returns false if any part of the bottom of the entity is
-- off an edge that is not a staircase
function sv_move.checkBottom(svr: any, ed: vmlib.Edict): boolean
	local ent, _glob, world = abi(svr)
	local w = svr.world
	local origin = vmlib.edVector(ed, ent.origin)
	local mins = origin + vmlib.edVector(ed, ent.mins)
	local maxs = origin + vmlib.edVector(ed, ent.maxs)

	-- if all of the points under the corners are solid world, don't bother
	-- with the tougher checks
	local easy = true
	for x = 0, 1 do
		for y = 0, 1 do
			local start = vector.create(if x ~= 0 then maxs.x else mins.x, if y ~= 0 then maxs.y else mins.y, mins.z - 1)
			if world.pointContents(w, start) ~= qd.CONTENTS_SOLID then
				easy = false
				break
			end
		end
		if not easy then
			break
		end
	end
	if easy then
		return true -- we got out easy
	end

	-- check it for real...
	-- the midpoint must be within 16 of the bottom
	local startZ = mins.z
	local cx = (mins.x + maxs.x) * 0.5
	local cy = (mins.y + maxs.y) * 0.5
	local trace = world.move(
		w,
		vector.create(cx, cy, startZ),
		vector.zero,
		vector.zero,
		vector.create(cx, cy, startZ - 2 * STEPSIZE),
		qd.MOVE_NOMONSTERS,
		ed
	)
	if trace.fraction == 1 then
		return false
	end
	local mid = trace.endpos.z
	local bottom = mid

	-- the corners must be within 16 of the midpoint
	for x = 0, 1 do
		for y = 0, 1 do
			local px = if x ~= 0 then maxs.x else mins.x
			local py = if y ~= 0 then maxs.y else mins.y
			trace = world.move(
				w,
				vector.create(px, py, startZ),
				vector.zero,
				vector.zero,
				vector.create(px, py, startZ - 2 * STEPSIZE),
				qd.MOVE_NOMONSTERS,
				ed
			)
			if trace.fraction ~= 1 and trace.endpos.z > bottom then
				bottom = trace.endpos.z
			end
			if trace.fraction == 1 or mid - trace.endpos.z > STEPSIZE then
				return false
			end
		end
	end

	return true
end

-- SV_movestep: called by monster program code. The move will be adjusted
-- for slopes and stairs, but if the move isn't possible, no move is done
-- and false is returned.
function sv_move.movestep(svr: any, ed: vmlib.Edict, move: vector, relink: boolean): boolean
	local ent, _glob, world = abi(svr)
	local vm = svr.vm
	local w = svr.world

	-- try the move
	local oldorg = vmlib.edVector(ed, ent.origin)
	local mins = vmlib.edVector(ed, ent.mins)
	local maxs = vmlib.edVector(ed, ent.maxs)
	local flags = vmlib.edFloat(ed, ent.flags)

	-- flying monsters don't step up
	if bit32.band(flags, qd.FL_SWIM + qd.FL_FLY) ~= 0 then
		-- try one move with vertical motion, then one without
		for i = 0, 1 do
			local neworg = vmlib.edVector(ed, ent.origin) + move
			local enemyNum = vmlib.edInt(ed, ent.enemy)
			if i == 0 and enemyNum ~= 0 then
				local enemy = vmlib.edictNum(vm, enemyNum)
				local dz = vmlib.edVector(ed, ent.origin).z - vmlib.edVector(enemy, ent.origin).z
				if dz > 40 then
					neworg = vector.create(neworg.x, neworg.y, neworg.z - 8)
				end
				if dz < 30 then
					neworg = vector.create(neworg.x, neworg.y, neworg.z + 8)
				end
			end
			local trace = world.move(w, vmlib.edVector(ed, ent.origin), mins, maxs, neworg, qd.MOVE_NORMAL, ed)

			if trace.fraction == 1 then
				if bit32.band(flags, qd.FL_SWIM) ~= 0 and world.pointContents(w, trace.endpos) == qd.CONTENTS_EMPTY then
					return false -- swim monster left water
				end
				vmlib.edSetVector(ed, ent.origin, trace.endpos)
				if relink then
					world.linkEdict(w, ed, true)
				end
				return true
			end

			if enemyNum == 0 then
				break
			end
		end
		return false
	end

	-- push down from a step height above the wished position
	local neworg = oldorg + move
	neworg = vector.create(neworg.x, neworg.y, neworg.z + STEPSIZE)
	local endp = vector.create(neworg.x, neworg.y, neworg.z - STEPSIZE * 2)

	local trace = world.move(w, neworg, mins, maxs, endp, qd.MOVE_NORMAL, ed)

	if trace.allsolid then
		return false
	end

	if trace.startsolid then
		neworg = vector.create(neworg.x, neworg.y, neworg.z - STEPSIZE)
		trace = world.move(w, neworg, mins, maxs, endp, qd.MOVE_NORMAL, ed)
		if trace.allsolid or trace.startsolid then
			return false
		end
	end
	if trace.fraction == 1 then
		-- if monster had the ground pulled out, go ahead and fall
		if bit32.band(flags, qd.FL_PARTIALGROUND) ~= 0 then
			vmlib.edSetVector(ed, ent.origin, oldorg + move)
			if relink then
				world.linkEdict(w, ed, true)
			end
			vmlib.edSetFloat(ed, ent.flags, bit32.band(flags, bit32.bnot(qd.FL_ONGROUND)))
			return true
		end
		return false -- walked off an edge
	end

	-- check point traces down for dangling corners
	vmlib.edSetVector(ed, ent.origin, trace.endpos)

	if not sv_move.checkBottom(svr, ed) then
		if bit32.band(flags, qd.FL_PARTIALGROUND) ~= 0 then
			-- entity had floor mostly pulled out from underneath it and is
			-- trying to correct
			if relink then
				world.linkEdict(w, ed, true)
			end
			return true
		end
		vmlib.edSetVector(ed, ent.origin, oldorg)
		return false
	end

	if bit32.band(flags, qd.FL_PARTIALGROUND) ~= 0 then
		vmlib.edSetFloat(ed, ent.flags, bit32.band(flags, bit32.bnot(qd.FL_PARTIALGROUND)))
	end
	vmlib.edSetInt(ed, ent.groundentity, if trace.ent then trace.ent.num else 0)

	-- the move is ok
	if relink then
		world.linkEdict(w, ed, true)
	end
	return true
end

-- PF_changeyaw (operates on the edict in the self global)
function sv_move.changeYaw(svr: any)
	local ent, glob, _world = abi(svr)
	local vm = svr.vm
	local ed = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
	local angles = vmlib.edVector(ed, ent.angles)
	local current = mathlib.anglemod(angles.y)
	local ideal = vmlib.edFloat(ed, ent.ideal_yaw)
	local speed = vmlib.edFloat(ed, ent.yaw_speed)

	if current == ideal then
		return
	end
	local move = ideal - current
	if ideal > current then
		if move >= 180 then
			move -= 360
		end
	else
		if move <= -180 then
			move += 360
		end
	end
	if move > 0 then
		if move > speed then
			move = speed
		end
	else
		if move < -speed then
			move = -speed
		end
	end

	vmlib.edSetVector(ed, ent.angles, vector.create(angles.x, mathlib.anglemod(current + move), angles.z))
end

-- SV_StepDirection: turns to the movement direction, and walks the current
-- distance if facing it
local function stepDirection(svr: any, ed: vmlib.Edict, yaw: number, dist: number): boolean
	local ent, glob, world = abi(svr)
	local w = svr.world

	vmlib.edSetFloat(ed, ent.ideal_yaw, yaw)
	-- PF_changeyaw reads self; SV_StepDirection is always called with
	-- self == the actor in the C engine's flow
	local vm = svr.vm
	local oldSelf = vmlib.globalInt(vm, glob.self)
	buffer.writei32(vm.globals, glob.self * 4, ed.num)
	sv_move.changeYaw(svr)
	buffer.writei32(vm.globals, glob.self * 4, oldSelf)

	local rad = yaw * math.pi * 2 / 360
	local move = vector.create(math.cos(rad) * dist, math.sin(rad) * dist, 0)

	local oldorigin = vmlib.edVector(ed, ent.origin)
	if sv_move.movestep(svr, ed, move, false) then
		local delta = vmlib.edVector(ed, ent.angles).y - vmlib.edFloat(ed, ent.ideal_yaw)
		if delta > 45 and delta < 315 then
			-- not turned far enough, so don't take the step
			vmlib.edSetVector(ed, ent.origin, oldorigin)
		end
		world.linkEdict(w, ed, true)
		return true
	end
	world.linkEdict(w, ed, true)
	return false
end

-- SV_FixCheckBottom
local function fixCheckBottom(ent: { [string]: number }, ed: vmlib.Edict)
	vmlib.edSetFloat(ed, ent.flags, bit32.bor(vmlib.edFloat(ed, ent.flags), qd.FL_PARTIALGROUND))
end

-- SV_NewChaseDir
local function newChaseDir(svr: any, actor: vmlib.Edict, enemy: vmlib.Edict, dist: number)
	local ent, _glob, _world = abi(svr)
	local olddir = mathlib.anglemod(mathlib.trunc(vmlib.edFloat(actor, ent.ideal_yaw) / 45) * 45)
	local turnaround = mathlib.anglemod(olddir - 180)

	local actorOrg = vmlib.edVector(actor, ent.origin)
	local enemyOrg = vmlib.edVector(enemy, ent.origin)
	local deltax = enemyOrg.x - actorOrg.x
	local deltay = enemyOrg.y - actorOrg.y

	local d1, d2
	if deltax > 10 then
		d1 = 0
	elseif deltax < -10 then
		d1 = 180
	else
		d1 = DI_NODIR
	end
	if deltay < -10 then
		d2 = 270
	elseif deltay > 10 then
		d2 = 90
	else
		d2 = DI_NODIR
	end

	-- try direct route
	if d1 ~= DI_NODIR and d2 ~= DI_NODIR then
		local tdir
		if d1 == 0 then
			tdir = if d2 == 90 then 45 else 315
		else
			tdir = if d2 == 90 then 135 else 215
		end
		if tdir ~= turnaround and stepDirection(svr, actor, tdir, dist) then
			return
		end
	end

	-- try other directions
	if bit32.band(bit32.band(randOf(svr), 3), 1) ~= 0 or math.abs(deltay) > math.abs(deltax) then
		d1, d2 = d2, d1
	end

	if d1 ~= DI_NODIR and d1 ~= turnaround and stepDirection(svr, actor, d1, dist) then
		return
	end
	if d2 ~= DI_NODIR and d2 ~= turnaround and stepDirection(svr, actor, d2, dist) then
		return
	end

	-- there is no direct path to the player, so pick another direction
	if olddir ~= DI_NODIR and stepDirection(svr, actor, olddir, dist) then
		return
	end

	if bit32.band(randOf(svr), 1) ~= 0 then
		-- randomly determine direction of search
		for tdir = 0, 315, 45 do
			if tdir ~= turnaround and stepDirection(svr, actor, tdir, dist) then
				return
			end
		end
	else
		for tdir = 315, 0, -45 do
			if tdir ~= turnaround and stepDirection(svr, actor, tdir, dist) then
				return
			end
		end
	end

	if turnaround ~= DI_NODIR and stepDirection(svr, actor, turnaround, dist) then
		return
	end

	vmlib.edSetFloat(actor, ent.ideal_yaw, olddir) -- can't move

	-- if a bridge was pulled out from underneath a monster, it may not have
	-- a valid standing position at all
	if not sv_move.checkBottom(svr, actor) then
		fixCheckBottom(ent, actor)
	end
end

-- SV_CloseEnough
local function closeEnough(ent: { [string]: number }, ed: vmlib.Edict, goal: vmlib.Edict, dist: number): boolean
	local gmin = vmlib.edVector(goal, ent.absmin)
	local gmax = vmlib.edVector(goal, ent.absmax)
	local emin = vmlib.edVector(ed, ent.absmin)
	local emax = vmlib.edVector(ed, ent.absmax)
	for axis = 0, 2 do
		if mathlib.comp(gmin, axis) > mathlib.comp(emax, axis) + dist then
			return false
		end
		if mathlib.comp(gmax, axis) < mathlib.comp(emin, axis) - dist then
			return false
		end
	end
	return true
end

-- SV_MoveToGoal (builtin #67)
function sv_move.moveToGoal(svr: any)
	local ent, glob, _world = abi(svr)
	local vm = svr.vm
	local ed = vmlib.edictNum(vm, vmlib.globalInt(vm, glob.self))
	local goal = vmlib.edictNum(vm, vmlib.edInt(ed, ent.goalentity))
	local dist = vmlib.globalFloat(vm, defs.OFS_PARM0)

	if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND + qd.FL_FLY + qd.FL_SWIM) == 0 then
		vmlib.setGlobalFloat(vm, defs.OFS_RETURN, 0)
		return
	end

	-- if the next step hits the enemy, return immediately
	if vmlib.edInt(ed, ent.enemy) ~= 0 and closeEnough(ent, ed, goal, dist) then
		return
	end

	-- bump around...
	if bit32.band(randOf(svr), 3) == 1 or not stepDirection(svr, ed, vmlib.edFloat(ed, ent.ideal_yaw), dist) then
		newChaseDir(svr, ed, goal, dist)
	end
end

return sv_move
