--!strict
--!optimize 2
-- QW server physics — port of QW/server/sv_phys.c: the movetype simulation
-- (pushers, toss/bounce, step entities) driven each frame. Players do NOT
-- move here in QW — SV_RunCmd runs them through pmove. Algorithms match
-- the NQ sv_phys.c port; the entvars/globals ABI is injected via qwdefs,
-- and sounds route through the server's own startSound.

local cvarlib = require("../common/cvar")
local mathlib = require("../common/mathlib")
local vmlib = require("../progs/vm")
local qd = require("../quakedef")
local world = require("./qwworld")
local qwdefslib = require("./qwdefs")

local sv_phys = {}

-- injected via sv_phys.useDefs before any physics runs
local ent: { [string]: number } = {}
local glob: { [string]: number } = {}

function sv_phys.useDefs(qdefs: qwdefslib.QwDefs)
	ent = qdefs.ent
	glob = qdefs.glob
end

local STOP_EPSILON = 0.1
local MAX_CLIP_PLANES = 5
local STEPSIZE = 18

--------------------------------------------------------------------------
-- helpers

local function execTouch(svr: any, fn: number, self_: vmlib.Edict, other: vmlib.Edict)
	local vm = svr.vm
	local g = vm.globals
	buffer.writei32(g, glob.self * 4, self_.num)
	buffer.writei32(g, glob.other * 4, other.num)
	vmlib.exec(vm, fn)
end

-- SV_CheckVelocity
function sv_phys.checkVelocity(svr: any, ed: vmlib.Edict)
	local maxvel = cvarlib.value(svr.cvars, "sv_maxvelocity")
	local vel = vmlib.edVector(ed, ent.velocity)
	local org = vmlib.edVector(ed, ent.origin)

	-- bound velocity (NaN != NaN catches the NaN cases)
	local vx, vy, vz = vel.x, vel.y, vel.z
	local ox, oy, oz = org.x, org.y, org.z
	if vx ~= vx then
		vx = 0
	end
	if vy ~= vy then
		vy = 0
	end
	if vz ~= vz then
		vz = 0
	end
	if ox ~= ox then
		ox = 0
	end
	if oy ~= oy then
		oy = 0
	end
	if oz ~= oz then
		oz = 0
	end
	vx = math.clamp(vx, -maxvel, maxvel)
	vy = math.clamp(vy, -maxvel, maxvel)
	vz = math.clamp(vz, -maxvel, maxvel)
	vmlib.edSetVector(ed, ent.velocity, vector.create(vx, vy, vz))
	vmlib.edSetVector(ed, ent.origin, vector.create(ox, oy, oz))
end

-- SV_RunThink: returns false if the entity removed itself
function sv_phys.runThink(svr: any, ed: vmlib.Edict): boolean
	local vm = svr.vm

	local thinktime = vmlib.edFloat(ed, ent.nextthink)
	if thinktime <= 0 or thinktime > svr.time + svr.frametime then
		return true
	end

	if thinktime < svr.time then
		thinktime = svr.time -- don't let things stay in the past
	end
	vmlib.edSetFloat(ed, ent.nextthink, 0)
	buffer.writef32(vm.globals, glob.time * 4, thinktime)
	buffer.writei32(vm.globals, glob.self * 4, ed.num)
	buffer.writei32(vm.globals, glob.other * 4, 0)
	vmlib.exec(vm, vmlib.edInt(ed, ent.think))
	return not ed.free
end

-- SV_Impact: two entities have touched, so run their touch functions
function sv_phys.impact(svr: any, e1: vmlib.Edict, e2: vmlib.Edict)
	local vm = svr.vm
	local g = vm.globals
	local old_self = buffer.readi32(g, glob.self * 4)
	local old_other = buffer.readi32(g, glob.other * 4)

	buffer.writef32(g, glob.time * 4, svr.time)
	local touch1 = vmlib.edInt(e1, ent.touch)
	if touch1 ~= 0 and vmlib.edFloat(e1, ent.solid) ~= qd.SOLID_NOT then
		execTouch(svr, touch1, e1, e2)
	end
	local touch2 = vmlib.edInt(e2, ent.touch)
	if touch2 ~= 0 and vmlib.edFloat(e2, ent.solid) ~= qd.SOLID_NOT then
		execTouch(svr, touch2, e2, e1)
	end

	buffer.writei32(g, glob.self * 4, old_self)
	buffer.writei32(g, glob.other * 4, old_other)
end

-- ClipVelocity: slide off the impacting object.
-- returns (blocked flags, out velocity): 1 = floor, 2 = step/wall
function sv_phys.clipVelocity(vin: vector, normal: vector, overbounce: number): (number, vector)
	local blocked = 0
	if normal.z > 0 then
		blocked = 1 -- floor
	end
	if normal.z == 0 then
		blocked += 2 -- step
	end

	local backoff = vector.dot(vin, normal) * overbounce

	local function comp(inv: number, n: number): number
		local out = inv - n * backoff
		if out > -STOP_EPSILON and out < STOP_EPSILON then
			out = 0
		end
		return out
	end
	return blocked, vector.create(comp(vin.x, normal.x), comp(vin.y, normal.y), comp(vin.z, normal.z))
end

--------------------------------------------------------------------------
-- SV_FlyMove

-- Returns (clipflags, steptrace?): 1 = floor, 2 = wall/step, 4 = dead stop
function sv_phys.flyMove(svr: any, ed: vmlib.Edict, time: number, wantSteptrace: boolean): (number, world.Trace?)
	local w = svr.world
	local numbumps = 4

	local blocked = 0
	local original_velocity = vmlib.edVector(ed, ent.velocity)
	local primal_velocity = original_velocity
	local planes: { vector } = {}
	local steptrace: world.Trace? = nil

	local time_left = time

	for _ = 1, numbumps do
		local velocity = vmlib.edVector(ed, ent.velocity)
		if velocity == vector.zero then
			break
		end

		local origin = vmlib.edVector(ed, ent.origin)
		local endp = origin + velocity * time_left

		local trace =
			world.move(w, origin, vmlib.edVector(ed, ent.mins), vmlib.edVector(ed, ent.maxs), endp, qd.MOVE_NORMAL, ed)

		if trace.allsolid then
			-- entity is trapped in another solid
			vmlib.edSetVector(ed, ent.velocity, vector.zero)
			return 3, steptrace
		end

		if trace.fraction > 0 then
			-- actually covered some distance
			vmlib.edSetVector(ed, ent.origin, trace.endpos)
			original_velocity = vmlib.edVector(ed, ent.velocity)
			table.clear(planes)
		end

		if trace.fraction == 1 then
			break -- moved the entire distance
		end

		local traceEnt = trace.ent
		if not traceEnt then
			error("SV_FlyMove: !trace.ent")
		end

		if trace.planeNormal.z > 0.7 then
			blocked = bit32.bor(blocked, 1) -- floor
			if vmlib.edFloat(traceEnt, ent.solid) == qd.SOLID_BSP then
				vmlib.edSetFloat(ed, ent.flags, bit32.bor(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND))
				vmlib.edSetInt(ed, ent.groundentity, traceEnt.num)
			end
		end
		if trace.planeNormal.z == 0 then
			blocked = bit32.bor(blocked, 2) -- step
			if wantSteptrace then
				steptrace = trace -- save for player extrafriction
			end
		end

		-- run the impact function
		sv_phys.impact(svr, ed, traceEnt)
		if ed.free then
			break -- removed by the impact function
		end

		time_left -= time_left * trace.fraction

		-- clipped to another plane
		if #planes >= MAX_CLIP_PLANES then
			-- this shouldn't really happen
			vmlib.edSetVector(ed, ent.velocity, vector.zero)
			return 3, steptrace
		end

		table.insert(planes, trace.planeNormal)

		-- modify original_velocity so it parallels all of the clip planes
		local new_velocity = vector.zero
		local i = 1
		while i <= #planes do
			local _, clipped = sv_phys.clipVelocity(original_velocity, planes[i], 1)
			new_velocity = clipped
			local ok = true
			for j = 1, #planes do
				if j ~= i then
					if vector.dot(new_velocity, planes[j]) < 0 then
						ok = false
						break -- not ok
					end
				end
			end
			if ok then
				break
			end
			i += 1
		end

		if i <= #planes then
			-- go along this plane
			vmlib.edSetVector(ed, ent.velocity, new_velocity)
		else
			-- go along the crease
			if #planes ~= 2 then
				vmlib.edSetVector(ed, ent.velocity, vector.zero)
				return 7, steptrace
			end
			local dir = vector.cross(planes[1], planes[2])
			local d = vector.dot(dir, vmlib.edVector(ed, ent.velocity))
			vmlib.edSetVector(ed, ent.velocity, dir * d)
		end

		-- if velocity is against the original velocity, stop dead to avoid
		-- tiny oscillations in sloping corners
		if vector.dot(vmlib.edVector(ed, ent.velocity), primal_velocity) <= 0 then
			vmlib.edSetVector(ed, ent.velocity, vector.zero)
			return blocked, steptrace
		end
	end

	return blocked, steptrace
end

-- SV_AddGravity
function sv_phys.addGravity(svr: any, ed: vmlib.Edict)
	local ent_gravity = 1.0
	local gravdef = svr.vm.progs.fielddefsByName["gravity"]
	if gravdef then
		local v = vmlib.edFloat(ed, gravdef.ofs)
		if v ~= 0 then
			ent_gravity = v
		end
	end
	local vel = vmlib.edVector(ed, ent.velocity)
	vmlib.edSetVector(
		ed,
		ent.velocity,
		vector.create(vel.x, vel.y, vel.z - ent_gravity * cvarlib.value(svr.cvars, "sv_gravity") * svr.frametime)
	)
end

--------------------------------------------------------------------------
-- PUSHMOVE

-- SV_PushEntity: does not change the entity's velocity at all
function sv_phys.pushEntity(svr: any, ed: vmlib.Edict, push: vector): world.Trace
	local w = svr.world
	local origin = vmlib.edVector(ed, ent.origin)
	local endp = origin + push

	local movetype = vmlib.edFloat(ed, ent.movetype)
	local solid = vmlib.edFloat(ed, ent.solid)
	local clipType
	if movetype == qd.MOVETYPE_FLYMISSILE then
		clipType = qd.MOVE_MISSILE
	elseif solid == qd.SOLID_TRIGGER or solid == qd.SOLID_NOT then
		clipType = qd.MOVE_NOMONSTERS -- only clip against bmodels
	else
		clipType = qd.MOVE_NORMAL
	end

	local trace =
		world.move(w, origin, vmlib.edVector(ed, ent.mins), vmlib.edVector(ed, ent.maxs), endp, clipType, ed)

	vmlib.edSetVector(ed, ent.origin, trace.endpos)
	world.linkEdict(w, ed, true)

	if trace.ent then
		sv_phys.impact(svr, ed, trace.ent :: vmlib.Edict)
	end

	return trace
end

-- SV_PushMove
local function pushMove(svr: any, pusher: vmlib.Edict, movetime: number)
	local vm = svr.vm
	local w = svr.world

	local pvel = vmlib.edVector(pusher, ent.velocity)
	if pvel == vector.zero then
		vmlib.edSetFloat(pusher, ent.ltime, vmlib.edFloat(pusher, ent.ltime) + movetime)
		return
	end

	local move = pvel * movetime
	local mins = vmlib.edVector(pusher, ent.absmin) + move
	local maxs = vmlib.edVector(pusher, ent.absmax) + move

	local pushorig = vmlib.edVector(pusher, ent.origin)

	-- move the pusher to its final position
	vmlib.edSetVector(pusher, ent.origin, pushorig + move)
	vmlib.edSetFloat(pusher, ent.ltime, vmlib.edFloat(pusher, ent.ltime) + movetime)
	world.linkEdict(w, pusher, false)

	-- see if any solid entities are inside the final position
	local moved_edict: { vmlib.Edict } = {}
	local moved_from: { vector } = {}

	for e = 1, vm.num_edicts - 1 do
		local check = vm.edicts[e + 1]
		if check.free then
			continue
		end
		local movetype = vmlib.edFloat(check, ent.movetype)
		if movetype == qd.MOVETYPE_PUSH or movetype == qd.MOVETYPE_NONE or movetype == qd.MOVETYPE_NOCLIP then
			continue
		end

		-- if the entity is standing on the pusher, it will definitely be moved
		local standing = bit32.band(vmlib.edFloat(check, ent.flags), qd.FL_ONGROUND) ~= 0
			and vmlib.edInt(check, ent.groundentity) == pusher.num
		if not standing then
			local cmin = vmlib.edVector(check, ent.absmin)
			local cmax = vmlib.edVector(check, ent.absmax)
			if
				cmin.x >= maxs.x
				or cmin.y >= maxs.y
				or cmin.z >= maxs.z
				or cmax.x <= mins.x
				or cmax.y <= mins.y
				or cmax.z <= mins.z
			then
				continue
			end

			-- see if the ent's bbox is inside the pusher's final position
			if not world.testEntityPosition(w, check) then
				continue
			end
		end

		-- remove the onground flag for non-players
		if movetype ~= qd.MOVETYPE_WALK then
			vmlib.edSetFloat(check, ent.flags, bit32.band(vmlib.edFloat(check, ent.flags), bit32.bnot(qd.FL_ONGROUND)))
		end

		local entorig = vmlib.edVector(check, ent.origin)
		table.insert(moved_edict, check)
		table.insert(moved_from, entorig)

		-- try moving the contacted entity
		vmlib.edSetFloat(pusher, ent.solid, qd.SOLID_NOT)
		sv_phys.pushEntity(svr, check, move)
		vmlib.edSetFloat(pusher, ent.solid, qd.SOLID_BSP)

		-- if it is still inside the pusher, block
		local block = world.testEntityPosition(w, check)
		if block then
			-- fail the move
			local cmins = vmlib.edVector(check, ent.mins)
			local cmaxs = vmlib.edVector(check, ent.maxs)
			if cmins.x == cmaxs.x then
				continue
			end
			if
				vmlib.edFloat(check, ent.solid) == qd.SOLID_NOT
				or vmlib.edFloat(check, ent.solid) == qd.SOLID_TRIGGER
			then
				-- corpse
				vmlib.edSetVector(check, ent.mins, vector.create(0, 0, cmins.z))
				vmlib.edSetVector(check, ent.maxs, vector.create(0, 0, cmins.z))
				continue
			end

			vmlib.edSetVector(check, ent.origin, entorig)
			world.linkEdict(w, check, true)

			vmlib.edSetVector(pusher, ent.origin, pushorig)
			world.linkEdict(w, pusher, false)
			vmlib.edSetFloat(pusher, ent.ltime, vmlib.edFloat(pusher, ent.ltime) - movetime)

			-- if the pusher has a "blocked" function, call it; otherwise just
			-- stay in place until the obstacle is gone
			local blockedFn = vmlib.edInt(pusher, ent.blocked)
			if blockedFn ~= 0 then
				execTouch(svr, blockedFn, pusher, check)
			end

			-- move back any entities we already moved
			for i, moved in moved_edict do
				vmlib.edSetVector(moved, ent.origin, moved_from[i])
				world.linkEdict(w, moved, false)
			end
			return
		end
	end
end

-- SV_Physics_Pusher
local function physicsPusher(svr: any, ed: vmlib.Edict)
	local vm = svr.vm
	local oldltime = vmlib.edFloat(ed, ent.ltime)

	local thinktime = vmlib.edFloat(ed, ent.nextthink)
	local movetime
	if thinktime < oldltime + svr.frametime then
		movetime = math.max(thinktime - oldltime, 0)
	else
		movetime = svr.frametime
	end

	if movetime ~= 0 then
		pushMove(svr, ed, movetime) -- advances ltime if not blocked
	end

	if thinktime > oldltime and thinktime <= vmlib.edFloat(ed, ent.ltime) then
		vmlib.edSetFloat(ed, ent.nextthink, 0)
		buffer.writef32(vm.globals, glob.time * 4, svr.time)
		buffer.writei32(vm.globals, glob.self * 4, ed.num)
		buffer.writei32(vm.globals, glob.other * 4, 0)
		vmlib.exec(vm, vmlib.edInt(ed, ent.think))
	end
end

--------------------------------------------------------------------------
-- CLIENT MOVEMENT

-- SV_CheckStuck
function sv_phys.checkStuck(svr: any, ed: vmlib.Edict)
	local w = svr.world

	if not world.testEntityPosition(w, ed) then
		vmlib.edSetVector(ed, ent.oldorigin, vmlib.edVector(ed, ent.origin))
		return
	end

	local org = vmlib.edVector(ed, ent.origin)
	vmlib.edSetVector(ed, ent.origin, vmlib.edVector(ed, ent.oldorigin))
	if not world.testEntityPosition(w, ed) then
		svr.dprint("Unstuck.")
		world.linkEdict(w, ed, true)
		return
	end

	for z = 0, 17 do
		for i = -1, 1 do
			for j = -1, 1 do
				vmlib.edSetVector(ed, ent.origin, vector.create(org.x + i, org.y + j, org.z + z))
				if not world.testEntityPosition(w, ed) then
					svr.dprint("Unstuck.")
					world.linkEdict(w, ed, true)
					return
				end
			end
		end
	end

	vmlib.edSetVector(ed, ent.origin, org)
	svr.dprint("player is stuck.")
end

-- SV_CheckWater
function sv_phys.checkWater(svr: any, ed: vmlib.Edict): boolean
	local w = svr.world
	local origin = vmlib.edVector(ed, ent.origin)
	local mins = vmlib.edVector(ed, ent.mins)
	local maxs = vmlib.edVector(ed, ent.maxs)

	local point = vector.create(origin.x, origin.y, origin.z + mins.z + 1)

	vmlib.edSetFloat(ed, ent.waterlevel, 0)
	vmlib.edSetFloat(ed, ent.watertype, qd.CONTENTS_EMPTY)
	local cont = world.pointContents(w, point)
	if cont <= qd.CONTENTS_WATER then
		vmlib.edSetFloat(ed, ent.watertype, cont)
		vmlib.edSetFloat(ed, ent.waterlevel, 1)
		point = vector.create(origin.x, origin.y, origin.z + (mins.z + maxs.z) * 0.5)
		cont = world.pointContents(w, point)
		if cont <= qd.CONTENTS_WATER then
			vmlib.edSetFloat(ed, ent.waterlevel, 2)
			point = vector.create(origin.x, origin.y, origin.z + vmlib.edFloat(ed, ent.view_ofs + 2))
			cont = world.pointContents(w, point)
			if cont <= qd.CONTENTS_WATER then
				vmlib.edSetFloat(ed, ent.waterlevel, 3)
			end
		end
	end

	return vmlib.edFloat(ed, ent.waterlevel) > 1
end

-- SV_WallFriction
local function wallFriction(svr: any, ed: vmlib.Edict, trace: world.Trace)
	local forward = mathlib.angleVectors(vmlib.edVector(ed, ent.v_angle))
	local d = vector.dot(trace.planeNormal, forward) + 0.5
	if d >= 0 then
		return
	end

	-- cut the tangential velocity
	local vel = vmlib.edVector(ed, ent.velocity)
	local i = vector.dot(trace.planeNormal, vel)
	local into = trace.planeNormal * i
	local side = vel - into

	vmlib.edSetVector(ed, ent.velocity, vector.create(side.x * (1 + d), side.y * (1 + d), vel.z))
end

-- SV_TryUnstick
local UNSTICK_DIRS = {
	vector.create(2, 0, 0),
	vector.create(0, 2, 0),
	vector.create(-2, 0, 0),
	vector.create(0, -2, 0),
	vector.create(2, 2, 0),
	vector.create(-2, 2, 0),
	vector.create(2, -2, 0),
	vector.create(-2, -2, 0),
}

local function tryUnstick(svr: any, ed: vmlib.Edict, oldvel: vector): number
	local oldorg = vmlib.edVector(ed, ent.origin)

	for _, dir in UNSTICK_DIRS do
		sv_phys.pushEntity(svr, ed, dir)

		-- retry the original move
		vmlib.edSetVector(ed, ent.velocity, vector.create(oldvel.x, oldvel.y, 0))
		local clip = sv_phys.flyMove(svr, ed, 0.1, true)

		local neworg = vmlib.edVector(ed, ent.origin)
		if math.abs(oldorg.y - neworg.y) > 4 or math.abs(oldorg.x - neworg.x) > 4 then
			return clip
		end

		-- go back to the original pos and try again
		vmlib.edSetVector(ed, ent.origin, oldorg)
	end

	vmlib.edSetVector(ed, ent.velocity, vector.zero)
	return 7 -- still not moving
end

-- SV_WalkMove: only used by players
function sv_phys.walkMove(svr: any, ed: vmlib.Edict)
	local w = svr.world

	-- do a regular slide move unless it looks like you ran into a step
	local flags = vmlib.edFloat(ed, ent.flags)
	local oldonground = bit32.band(flags, qd.FL_ONGROUND)
	vmlib.edSetFloat(ed, ent.flags, bit32.band(flags, bit32.bnot(qd.FL_ONGROUND)))

	local oldorg = vmlib.edVector(ed, ent.origin)
	local oldvel = vmlib.edVector(ed, ent.velocity)

	local clip, steptrace = sv_phys.flyMove(svr, ed, svr.frametime, true)

	if bit32.band(clip, 2) == 0 then
		return -- move didn't block on a step
	end

	if oldonground == 0 and vmlib.edFloat(ed, ent.waterlevel) == 0 then
		return -- don't stair up while jumping
	end

	if vmlib.edFloat(ed, ent.movetype) ~= qd.MOVETYPE_WALK then
		return -- gibbed by a trigger
	end

	if cvarlib.value(svr.cvars, "sv_nostep") ~= 0 then
		return
	end

	if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_WATERJUMP) ~= 0 then
		return
	end

	local nosteporg = vmlib.edVector(ed, ent.origin)
	local nostepvel = vmlib.edVector(ed, ent.velocity)

	-- try moving up and forward to go up a step
	vmlib.edSetVector(ed, ent.origin, oldorg) -- back to start pos

	local upmove = vector.create(0, 0, STEPSIZE)
	local downmove = vector.create(0, 0, -STEPSIZE + oldvel.z * svr.frametime)

	-- move up
	sv_phys.pushEntity(svr, ed, upmove)

	-- move forward
	vmlib.edSetVector(ed, ent.velocity, vector.create(oldvel.x, oldvel.y, 0))
	local clip2, steptrace2 = sv_phys.flyMove(svr, ed, svr.frametime, true)
	if steptrace2 then
		steptrace = steptrace2
	end

	-- check for stuckness, possibly due to the limited precision of floats
	-- in the clipping hulls
	if clip2 ~= 0 then
		local neworg = vmlib.edVector(ed, ent.origin)
		if math.abs(oldorg.y - neworg.y) < 0.03125 and math.abs(oldorg.x - neworg.x) < 0.03125 then
			-- stepping up didn't make any progress
			clip2 = tryUnstick(svr, ed, oldvel)
		end
	end

	-- extra friction based on view angle
	if bit32.band(clip2, 2) ~= 0 and steptrace then
		wallFriction(svr, ed, steptrace)
	end

	-- move down
	local downtrace = sv_phys.pushEntity(svr, ed, downmove)

	if downtrace.planeNormal.z > 0.7 then
		if vmlib.edFloat(ed, ent.solid) == qd.SOLID_BSP then
			vmlib.edSetFloat(ed, ent.flags, bit32.bor(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND))
			vmlib.edSetInt(ed, ent.groundentity, if downtrace.ent then (downtrace.ent :: vmlib.Edict).num else 0)
		end
	else
		-- if the push down didn't end up on good ground, use the move
		-- without the step up. This happens near wall/slope combinations,
		-- and can cause the player to hop up higher on a slope too steep
		-- to climb.
		vmlib.edSetVector(ed, ent.origin, nosteporg)
		vmlib.edSetVector(ed, ent.velocity, nostepvel)
	end
end

-- SV_Physics_Client: player character actions
-- NQ remnant, unreachable in QW (SV_RunCmd owns players); kept for parity
function sv_phys.physicsClient(svr: any, ed: vmlib.Edict, num: number)
	local vm = svr.vm
	local w = svr.world
	if not svr.clients[num].active then
		return -- unconnected slot
	end

	-- call standard client pre-think
	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	buffer.writei32(vm.globals, glob.self * 4, ed.num)
	vmlib.exec(vm, vmlib.globalInt(vm, glob.PlayerPreThink))

	-- do a move
	sv_phys.checkVelocity(svr, ed)

	-- decide which move function to call
	local movetype = vmlib.edFloat(ed, ent.movetype)
	if movetype == qd.MOVETYPE_NONE then
		if not sv_phys.runThink(svr, ed) then
			return
		end
	elseif movetype == qd.MOVETYPE_WALK then
		if not sv_phys.runThink(svr, ed) then
			return
		end
		if not sv_phys.checkWater(svr, ed) and bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_WATERJUMP) == 0 then
			sv_phys.addGravity(svr, ed)
		end
		sv_phys.checkStuck(svr, ed)
		sv_phys.walkMove(svr, ed)
	elseif movetype == qd.MOVETYPE_TOSS or movetype == qd.MOVETYPE_BOUNCE then
		sv_phys.physicsToss(svr, ed)
	elseif movetype == qd.MOVETYPE_FLY then
		if not sv_phys.runThink(svr, ed) then
			return
		end
		sv_phys.flyMove(svr, ed, svr.frametime, false)
	elseif movetype == qd.MOVETYPE_NOCLIP then
		if not sv_phys.runThink(svr, ed) then
			return
		end
		vmlib.edSetVector(ed, ent.origin, vmlib.edVector(ed, ent.origin) + vmlib.edVector(ed, ent.velocity) * svr.frametime)
	else
		error(`SV_Physics_client: bad movetype {movetype}`)
	end

	-- call standard player post-think
	world.linkEdict(w, ed, true)

	buffer.writef32(vm.globals, glob.time * 4, svr.time)
	buffer.writei32(vm.globals, glob.self * 4, ed.num)
	vmlib.exec(vm, vmlib.globalInt(vm, glob.PlayerPostThink))
end

--------------------------------------------------------------------------
-- other movetypes

-- SV_Physics_None: non moving objects can only think
local function physicsNone(svr: any, ed: vmlib.Edict)
	sv_phys.runThink(svr, ed)
end

-- SV_Physics_Noclip: a moving object that doesn't obey physics
local function physicsNoclip(svr: any, ed: vmlib.Edict)
	if not sv_phys.runThink(svr, ed) then
		return
	end
	vmlib.edSetVector(ed, ent.angles, vmlib.edVector(ed, ent.angles) + vmlib.edVector(ed, ent.avelocity) * svr.frametime)
	vmlib.edSetVector(ed, ent.origin, vmlib.edVector(ed, ent.origin) + vmlib.edVector(ed, ent.velocity) * svr.frametime)
	world.linkEdict(svr.world, ed, false)
end

-- SV_CheckWaterTransition
local function checkWaterTransition(svr: any, ed: vmlib.Edict)
	local cont = world.pointContents(svr.world, vmlib.edVector(ed, ent.origin))
	local watertype = vmlib.edFloat(ed, ent.watertype)
	if watertype == 0 then
		-- just spawned here
		vmlib.edSetFloat(ed, ent.watertype, cont)
		vmlib.edSetFloat(ed, ent.waterlevel, 1)
		return
	end

	if cont <= qd.CONTENTS_WATER then
		if watertype == qd.CONTENTS_EMPTY then
			-- just crossed into water
			svr.startSound(svr, ed, 0, "misc/h2ohit1.wav", 255, 1)
		end
		vmlib.edSetFloat(ed, ent.watertype, cont)
		vmlib.edSetFloat(ed, ent.waterlevel, 1)
	else
		if watertype ~= qd.CONTENTS_EMPTY then
			-- just crossed out of water
			svr.startSound(svr, ed, 0, "misc/h2ohit1.wav", 255, 1)
		end
		vmlib.edSetFloat(ed, ent.watertype, qd.CONTENTS_EMPTY)
		vmlib.edSetFloat(ed, ent.waterlevel, cont)
	end
end

-- SV_Physics_Toss: toss, bounce, and fly movement. When onground, do nothing.
function sv_phys.physicsToss(svr: any, ed: vmlib.Edict)
	-- regular thinking
	if not sv_phys.runThink(svr, ed) then
		return
	end

	-- if onground, return without moving
	if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND) ~= 0 then
		return
	end

	sv_phys.checkVelocity(svr, ed)

	-- add gravity
	local movetype = vmlib.edFloat(ed, ent.movetype)
	if movetype ~= qd.MOVETYPE_FLY and movetype ~= qd.MOVETYPE_FLYMISSILE then
		sv_phys.addGravity(svr, ed)
	end

	-- move angles
	vmlib.edSetVector(ed, ent.angles, vmlib.edVector(ed, ent.angles) + vmlib.edVector(ed, ent.avelocity) * svr.frametime)

	-- move origin
	local move = vmlib.edVector(ed, ent.velocity) * svr.frametime
	local trace = sv_phys.pushEntity(svr, ed, move)
	if trace.fraction == 1 then
		return
	end
	if ed.free then
		return
	end

	local backoff = if movetype == qd.MOVETYPE_BOUNCE then 1.5 else 1

	local _, newvel = sv_phys.clipVelocity(vmlib.edVector(ed, ent.velocity), trace.planeNormal, backoff)
	vmlib.edSetVector(ed, ent.velocity, newvel)

	-- stop if on ground
	if trace.planeNormal.z > 0.7 then
		if vmlib.edVector(ed, ent.velocity).z < 60 or movetype ~= qd.MOVETYPE_BOUNCE then
			vmlib.edSetFloat(ed, ent.flags, bit32.bor(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND))
			vmlib.edSetInt(ed, ent.groundentity, if trace.ent then (trace.ent :: vmlib.Edict).num else 0)
			vmlib.edSetVector(ed, ent.velocity, vector.zero)
			vmlib.edSetVector(ed, ent.avelocity, vector.zero)
		end
	end

	-- check for in water
	checkWaterTransition(svr, ed)
end

-- SV_Physics_Step: monsters freefall when they don't have a ground entity,
-- otherwise all movement is done with discrete steps
local function physicsStep(svr: any, ed: vmlib.Edict)
	local w = svr.world

	-- freefall if not onground
	if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND + qd.FL_FLY + qd.FL_SWIM) == 0 then
		local hitsound = vmlib.edVector(ed, ent.velocity).z < cvarlib.value(svr.cvars, "sv_gravity") * -0.1

		sv_phys.addGravity(svr, ed)
		sv_phys.checkVelocity(svr, ed)
		sv_phys.flyMove(svr, ed, svr.frametime, false)
		world.linkEdict(w, ed, true)

		if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_ONGROUND) ~= 0 then
			-- just hit ground
			if hitsound then
				svr.startSound(svr, ed, 0, "demon/dland2.wav", 255, 1)
			end
		end
	end

	-- regular thinking
	sv_phys.runThink(svr, ed)
	checkWaterTransition(svr, ed)
end

--------------------------------------------------------------------------
-- SV_Physics

function sv_phys.physics(svr: any)
	local vm = svr.vm
	local g = vm.globals

	-- let the progs know that a new frame has started
	buffer.writei32(g, glob.self * 4, 0)
	buffer.writei32(g, glob.other * 4, 0)
	buffer.writef32(g, glob.time * 4, svr.time)
	vmlib.exec(vm, svr.qdefs.func.StartFrame)

	-- treat each object in turn
	local i = 0
	while i < vm.num_edicts do
		local ed = vm.edicts[i + 1]
		if ed.free then
			i += 1
			continue
		end

		if vmlib.globalFloat(vm, glob.force_retouch) ~= 0 then
			world.linkEdict(svr.world, ed, true) -- force retouch even for stationary
		end

		local movetype = vmlib.edFloat(ed, ent.movetype)
		if i > 0 and i <= svr.maxclients then
			-- QW: clients move in SV_RunCmd through pmove, never here
			i += 1
			continue
		elseif movetype == qd.MOVETYPE_PUSH then
			physicsPusher(svr, ed)
		elseif movetype == qd.MOVETYPE_NONE then
			physicsNone(svr, ed)
		elseif movetype == qd.MOVETYPE_NOCLIP then
			physicsNoclip(svr, ed)
		elseif movetype == qd.MOVETYPE_STEP then
			physicsStep(svr, ed)
		elseif
			movetype == qd.MOVETYPE_TOSS
			or movetype == qd.MOVETYPE_BOUNCE
			or movetype == qd.MOVETYPE_FLY
			or movetype == qd.MOVETYPE_FLYMISSILE
		then
			sv_phys.physicsToss(svr, ed)
		else
			error(`SV_Physics: bad movetype {movetype}`)
		end

		i += 1
	end

	if vmlib.globalFloat(vm, glob.force_retouch) ~= 0 then
		vmlib.setGlobalFloat(vm, glob.force_retouch, vmlib.globalFloat(vm, glob.force_retouch) - 1)
	end

	svr.time += svr.frametime
	vm.time = svr.time
end

return sv_phys
