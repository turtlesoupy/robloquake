--!strict
--!optimize 2
-- QuakeWorld player movement — verbatim port of QW/client/pmove.c and
-- pmovetst.c. This is the movement code shared by the QW server
-- (SV_RunCmd) and the predicting client (CL_PredictUsercmd); determinism
-- between the two is the whole point.

local bsp = require("../bsp/bsp")
local mathlib = require("../common/mathlib")

local pmove = {}

local CONTENTS_EMPTY = -1
local CONTENTS_SOLID = -2
local CONTENTS_WATER = -3
local CONTENTS_SLIME = -4

local STEPSIZE = 18
local BUTTON_JUMP = 2
local STOP_EPSILON = 0.1
local MAX_CLIP_PLANES = 5
local DIST_EPSILON = 0.03125

pmove.PLAYER_MINS = vector.create(-16, -16, -24)
pmove.PLAYER_MAXS = vector.create(16, 16, 32)
local player_mins = pmove.PLAYER_MINS
local player_maxs = pmove.PLAYER_MAXS

export type MoveVars = {
	gravity: number,
	stopspeed: number,
	maxspeed: number,
	spectatormaxspeed: number,
	accelerate: number,
	airaccelerate: number,
	wateraccelerate: number,
	friction: number,
	waterfriction: number,
	entgravity: number,
}

-- QW server cvar defaults
function pmove.defaultMoveVars(): MoveVars
	return {
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
end

export type PhysEnt = {
	model: bsp.Model?, -- world + brush models use their hulls
	origin: vector,
	mins: vector?, -- box entities
	maxs: vector?,
}

export type UserCmd = {
	angles: vector,
	forwardmove: number,
	sidemove: number,
	upmove: number,
	buttons: number,
	msec: number,
}

export type PlayerMove = {
	origin: vector,
	angles: vector,
	velocity: vector,
	oldbuttons: number,
	waterjumptime: number,
	dead: boolean,
	spectator: boolean,
	physents: { PhysEnt }, -- [1] is the world
	cmd: UserCmd,
	-- results
	numtouch: number,
	touchindex: { number }, -- physent indices (0-based like the C)
	onground: number, -- physent index or -1
	waterlevel: number,
	watertype: number,
}

type PmTrace = {
	allsolid: boolean,
	startsolid: boolean,
	inopen: boolean,
	inwater: boolean,
	fraction: number,
	endpos: vector,
	planeNormal: vector,
	planeDist: number,
	ent: number,
}

--------------------------------------------------------------------------
-- pmovetst.c

-- PM_InitBoxHull equivalent: a fresh 6-clipnode hull per call site is
-- cheap in Luau; PM_HullForBox fills the plane distances
local function hullForBox(mins: vector, maxs: vector): bsp.Hull
	local planenum = table.create(6)
	local child0 = table.create(6)
	local child1 = table.create(6)
	local planes = table.create(6)
	local dists = { maxs.x, mins.x, maxs.y, mins.y, maxs.z, mins.z }
	for i = 0, 5 do
		planenum[i + 1] = i
		local side = bit32.band(i, 1)
		local children = { 0, 0 }
		children[side + 1] = CONTENTS_EMPTY
		children[(bit32.bxor(side, 1)) + 1] = if i ~= 5 then i + 1 else CONTENTS_SOLID
		child0[i + 1] = children[1]
		child1[i + 1] = children[2]
		local axis = bit32.rshift(i, 1)
		planes[i + 1] = {
			normal = vector.create(
				if axis == 0 then 1 else 0,
				if axis == 1 then 1 else 0,
				if axis == 2 then 1 else 0
			),
			dist = dists[i + 1],
			type = axis,
		}
	end
	return {
		clipnodes = { planenum = planenum, child0 = child0, child1 = child1 },
		planes = planes,
		firstclipnode = 0,
		lastclipnode = 5,
		clip_mins = mins,
		clip_maxs = maxs,
	} :: any
end

-- PM_HullPointContents
local function hullPointContents(hull: bsp.Hull, num: number, p: vector): number
	local cn = hull.clipnodes
	while num >= 0 do
		local plane = hull.planes[cn.planenum[num + 1] + 1]
		local d
		if plane.type < 3 then
			d = (if plane.type == 0 then p.x elseif plane.type == 1 then p.y else p.z) - plane.dist
		else
			d = vector.dot(plane.normal, p) - plane.dist
		end
		if d < 0 then
			num = cn.child1[num + 1]
		else
			num = cn.child0[num + 1]
		end
	end
	return num
end

-- PM_RecursiveHullCheck
local function recursiveHullCheck(hull: bsp.Hull, num: number, p1f: number, p2f: number, p1: vector, p2: vector, trace: PmTrace): boolean
	if num < 0 then
		if num ~= CONTENTS_SOLID then
			trace.allsolid = false
			if num == CONTENTS_EMPTY then
				trace.inopen = true
			else
				trace.inwater = true
			end
		else
			trace.startsolid = true
		end
		return true
	end

	local cn = hull.clipnodes
	local plane = hull.planes[cn.planenum[num + 1] + 1]
	local t1, t2
	if plane.type < 3 then
		local axis = plane.type
		t1 = (if axis == 0 then p1.x elseif axis == 1 then p1.y else p1.z) - plane.dist
		t2 = (if axis == 0 then p2.x elseif axis == 1 then p2.y else p2.z) - plane.dist
	else
		t1 = vector.dot(plane.normal, p1) - plane.dist
		t2 = vector.dot(plane.normal, p2) - plane.dist
	end

	if t1 >= 0 and t2 >= 0 then
		return recursiveHullCheck(hull, cn.child0[num + 1], p1f, p2f, p1, p2, trace)
	end
	if t1 < 0 and t2 < 0 then
		return recursiveHullCheck(hull, cn.child1[num + 1], p1f, p2f, p1, p2, trace)
	end

	-- put the crosspoint DIST_EPSILON pixels on the near side
	local frac
	if t1 < 0 then
		frac = (t1 + DIST_EPSILON) / (t1 - t2)
	else
		frac = (t1 - DIST_EPSILON) / (t1 - t2)
	end
	if frac < 0 then
		frac = 0
	end
	if frac > 1 then
		frac = 1
	end

	local midf = p1f + (p2f - p1f) * frac
	local mid = p1 + (p2 - p1) * frac
	local side = if t1 < 0 then 1 else 0
	local childNear = if side == 1 then cn.child1[num + 1] else cn.child0[num + 1]
	local childFar = if side == 1 then cn.child0[num + 1] else cn.child1[num + 1]

	if not recursiveHullCheck(hull, childNear, p1f, midf, p1, mid, trace) then
		return false
	end

	if hullPointContents(hull, childFar, mid) ~= CONTENTS_SOLID then
		return recursiveHullCheck(hull, childFar, midf, p2f, mid, p2, trace)
	end

	if trace.allsolid then
		return false -- never got out of the solid area
	end

	if side == 0 then
		trace.planeNormal = plane.normal
		trace.planeDist = plane.dist
	else
		trace.planeNormal = -plane.normal
		trace.planeDist = -plane.dist
	end

	while hullPointContents(hull, hull.firstclipnode, mid) == CONTENTS_SOLID do
		-- shouldn't really happen, but does occasionally
		frac -= 0.1
		if frac < 0 then
			trace.fraction = midf
			trace.endpos = mid
			return false
		end
		midf = p1f + (p2f - p1f) * frac
		mid = p1 + (p2 - p1) * frac
	end

	trace.fraction = midf
	trace.endpos = mid
	return false
end

local function physentHull(pe: PhysEnt): bsp.Hull
	if pe.model then
		return (pe.model :: bsp.Model).hulls[2] -- hull 1: the player hull
	end
	local mins = (pe.mins :: vector) - player_maxs
	local maxs = (pe.maxs :: vector) - player_mins
	return hullForBox(mins, maxs)
end

-- PM_TestPlayerPosition
local function testPlayerPosition(pm: PlayerMove, pos: vector): boolean
	for i, pe in pm.physents do
		local hull = physentHull(pe)
		local test = pos - pe.origin
		if hullPointContents(hull, hull.firstclipnode, test) == CONTENTS_SOLID then
			return false
		end
	end
	return true
end

-- PM_PointContents (world hull 0)
local function pointContents(pm: PlayerMove, p: vector): number
	local model = pm.physents[1].model :: bsp.Model
	local hull = model.hulls[1]
	return hullPointContents(hull, hull.firstclipnode, p)
end

-- PM_PlayerMove (the trace)
local function playerTrace(pm: PlayerMove, start: vector, endp: vector): PmTrace
	local total: PmTrace = {
		allsolid = false,
		startsolid = false,
		inopen = false,
		inwater = false,
		fraction = 1,
		endpos = endp,
		planeNormal = vector.zero,
		planeDist = 0,
		ent = -1,
	}
	for i, pe in pm.physents do
		local hull = physentHull(pe)
		local offset = pe.origin
		local start_l = start - offset
		local end_l = endp - offset

		local trace: PmTrace = {
			allsolid = true,
			startsolid = false,
			inopen = false,
			inwater = false,
			fraction = 1,
			endpos = endp,
			planeNormal = vector.zero,
			planeDist = 0,
			ent = -1,
		}
		recursiveHullCheck(hull, hull.firstclipnode, 0, 1, start_l, end_l, trace)

		if trace.allsolid then
			trace.startsolid = true
		end
		if trace.startsolid then
			trace.fraction = 0
		end

		if trace.fraction < total.fraction then
			trace.endpos += offset
			total = trace
			total.ent = i - 1 -- physent index, 0-based like the C
		end
	end
	return total
end

--------------------------------------------------------------------------
-- pmove.c

-- per-move working state (the C globals)
local frametime = 0
local fwd = vector.zero
local right = vector.zero
local up = vector.zero
local onground = -1
local waterlevel = 0
local watertype = CONTENTS_EMPTY

-- PM_ClipVelocity
local function clipVelocity(inv: vector, normal: vector, overbounce: number): (vector, number)
	local blocked = 0
	if normal.z > 0 then
		blocked = bit32.bor(blocked, 1)
	end
	if normal.z == 0 then
		blocked = bit32.bor(blocked, 2)
	end

	local backoff = vector.dot(inv, normal) * overbounce
	local ox = inv.x - normal.x * backoff
	local oy = inv.y - normal.y * backoff
	local oz = inv.z - normal.z * backoff
	if ox > -STOP_EPSILON and ox < STOP_EPSILON then
		ox = 0
	end
	if oy > -STOP_EPSILON and oy < STOP_EPSILON then
		oy = 0
	end
	if oz > -STOP_EPSILON and oz < STOP_EPSILON then
		oz = 0
	end
	return vector.create(ox, oy, oz), blocked
end

-- PM_FlyMove
local function flyMove(pm: PlayerMove): number
	local numbumps = 4
	local blocked = 0
	local original_velocity = pm.velocity
	local primal_velocity = pm.velocity
	local numplanes = 0
	local planes: { vector } = {}
	local time_left = frametime

	for _ = 1, numbumps do
		local endp = pm.origin + pm.velocity * time_left
		local trace = playerTrace(pm, pm.origin, endp)

		if trace.startsolid or trace.allsolid then
			pm.velocity = vector.zero
			return 3
		end

		if trace.fraction > 0 then
			pm.origin = trace.endpos
			numplanes = 0
		end

		if trace.fraction == 1 then
			break
		end

		pm.numtouch += 1
		pm.touchindex[pm.numtouch] = trace.ent

		if trace.planeNormal.z > 0.7 then
			blocked = bit32.bor(blocked, 1)
		end
		if trace.planeNormal.z == 0 then
			blocked = bit32.bor(blocked, 2)
		end

		time_left -= time_left * trace.fraction

		if numplanes >= MAX_CLIP_PLANES then
			pm.velocity = vector.zero
			break
		end

		numplanes += 1
		planes[numplanes] = trace.planeNormal

		-- modify original_velocity so it parallels all of the clip planes
		local i = 1
		while i <= numplanes do
			pm.velocity = (clipVelocity(original_velocity, planes[i], 1))
			local ok = true
			for j = 1, numplanes do
				if j ~= i then
					if vector.dot(pm.velocity, planes[j]) < 0 then
						ok = false
						break
					end
				end
			end
			if ok then
				break
			end
			i += 1
		end

		if i <= numplanes then
			-- go along this plane
		else
			-- go along the crease
			if numplanes ~= 2 then
				pm.velocity = vector.zero
				break
			end
			local dir = vector.cross(planes[1], planes[2])
			local d = vector.dot(dir, pm.velocity)
			pm.velocity = dir * d
		end

		if vector.dot(pm.velocity, primal_velocity) <= 0 then
			pm.velocity = vector.zero
			break
		end
	end

	if pm.waterjumptime ~= 0 then
		pm.velocity = primal_velocity
	end
	return blocked
end

-- PM_GroundMove
local function groundMove(pm: PlayerMove)
	pm.velocity = vector.create(pm.velocity.x, pm.velocity.y, 0)
	if pm.velocity.x == 0 and pm.velocity.y == 0 and pm.velocity.z == 0 then
		return
	end

	-- first try just moving to the destination
	local dest = vector.create(
		pm.origin.x + pm.velocity.x * frametime,
		pm.origin.y + pm.velocity.y * frametime,
		pm.origin.z
	)

	local trace = playerTrace(pm, pm.origin, dest)
	if trace.fraction == 1 then
		pm.origin = trace.endpos
		return
	end

	-- try sliding forward both on ground and up 16 pixels
	-- take the move that goes farthest
	local original = pm.origin
	local originalvel = pm.velocity

	-- slide move
	flyMove(pm)

	local down = pm.origin
	local downvel = pm.velocity

	pm.origin = original
	pm.velocity = originalvel

	-- move up a stair height
	dest = pm.origin + vector.create(0, 0, STEPSIZE)
	trace = playerTrace(pm, pm.origin, dest)
	if not trace.startsolid and not trace.allsolid then
		pm.origin = trace.endpos
	end

	-- slide move
	flyMove(pm)

	-- press down the stepheight
	dest = pm.origin - vector.create(0, 0, STEPSIZE)
	trace = playerTrace(pm, pm.origin, dest)
	local usedown = false
	if trace.planeNormal.z < 0.7 then
		usedown = true
	else
		if not trace.startsolid and not trace.allsolid then
			pm.origin = trace.endpos
		end
	end

	if not usedown then
		local upPos = pm.origin
		-- decide which one went farther
		local downdist = (down.x - original.x) ^ 2 + (down.y - original.y) ^ 2
		local updist = (upPos.x - original.x) ^ 2 + (upPos.y - original.y) ^ 2
		if downdist > updist then
			usedown = true
		else
			-- copy z value from slide move
			pm.velocity = vector.create(pm.velocity.x, pm.velocity.y, downvel.z)
		end
	end

	if usedown then
		pm.origin = down
		pm.velocity = downvel
	end
end

-- PM_Friction
local function friction(pm: PlayerMove, movevars: MoveVars)
	if pm.waterjumptime ~= 0 then
		return
	end

	local vel = pm.velocity
	local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
	if speed < 1 then
		pm.velocity = vector.create(0, 0, vel.z) -- vel[0] = vel[1] = 0
		return
	end

	local fric = movevars.friction

	-- if the leading edge is over a dropoff, increase friction
	if onground ~= -1 then
		local startv = vector.create(
			pm.origin.x + vel.x / speed * 16,
			pm.origin.y + vel.y / speed * 16,
			pm.origin.z + player_mins.z
		)
		local stopv = vector.create(startv.x, startv.y, startv.z - 34)
		local trace = playerTrace(pm, startv, stopv)
		if trace.fraction == 1 then
			fric *= 2
		end
	end

	local drop = 0
	if waterlevel >= 2 then
		drop += speed * movevars.waterfriction * waterlevel * frametime
	elseif onground ~= -1 then
		local control = if speed < movevars.stopspeed then movevars.stopspeed else speed
		drop += control * fric * frametime
	end

	local newspeed = speed - drop
	if newspeed < 0 then
		newspeed = 0
	end
	newspeed /= speed

	pm.velocity = vel * newspeed
end

-- PM_Accelerate
local function accelerate(pm: PlayerMove, wishdir: vector, wishspeed: number, accel: number)
	if pm.dead then
		return
	end
	if pm.waterjumptime ~= 0 then
		return
	end
	local currentspeed = vector.dot(pm.velocity, wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = accel * frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	pm.velocity += wishdir * accelspeed
end

-- PM_AirAccelerate
local function airAccelerate(pm: PlayerMove, wishdir: vector, wishspeed: number, accel: number)
	if pm.dead then
		return
	end
	if pm.waterjumptime ~= 0 then
		return
	end
	local wishspd = wishspeed
	if wishspd > 30 then
		wishspd = 30
	end
	local currentspeed = vector.dot(pm.velocity, wishdir)
	local addspeed = wishspd - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = accel * wishspeed * frametime
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	pm.velocity += wishdir * accelspeed
end

-- PM_WaterMove
local function waterMove(pm: PlayerMove, movevars: MoveVars)
	local wishvel = fwd * pm.cmd.forwardmove + right * pm.cmd.sidemove

	if pm.cmd.forwardmove == 0 and pm.cmd.sidemove == 0 and pm.cmd.upmove == 0 then
		wishvel -= vector.create(0, 0, 60) -- drift towards bottom
	else
		wishvel += vector.create(0, 0, pm.cmd.upmove)
	end

	local wishspeed = vector.magnitude(wishvel)
	local wishdir = if wishspeed > 0 then wishvel / wishspeed else vector.zero

	if wishspeed > movevars.maxspeed then
		wishvel *= movevars.maxspeed / wishspeed
		wishspeed = movevars.maxspeed
	end
	wishspeed *= 0.7

	accelerate(pm, wishdir, wishspeed, movevars.wateraccelerate)

	-- assume it is a stair or a slope, so press down from stepheight above
	local dest = pm.origin + pm.velocity * frametime
	local start = dest + vector.create(0, 0, STEPSIZE + 1)
	local trace = playerTrace(pm, start, dest)
	if not trace.startsolid and not trace.allsolid then
		pm.origin = trace.endpos
		return
	end

	flyMove(pm)
end

-- PM_AirMove
local function airMove(pm: PlayerMove, movevars: MoveVars)
	local fmove = pm.cmd.forwardmove
	local smove = pm.cmd.sidemove

	fwd = vector.create(fwd.x, fwd.y, 0)
	right = vector.create(right.x, right.y, 0)
	fwd = mathlib.normalize(fwd)
	right = mathlib.normalize(right)

	local wishvel = vector.create(
		fwd.x * fmove + right.x * smove,
		fwd.y * fmove + right.y * smove,
		0
	)

	local wishspeed = vector.magnitude(wishvel)
	local wishdir = if wishspeed > 0 then wishvel / wishspeed else vector.zero

	if wishspeed > movevars.maxspeed then
		wishvel *= movevars.maxspeed / wishspeed
		wishspeed = movevars.maxspeed
	end

	if onground ~= -1 then
		pm.velocity = vector.create(pm.velocity.x, pm.velocity.y, 0)
		accelerate(pm, wishdir, wishspeed, movevars.accelerate)
		pm.velocity -= vector.create(0, 0, movevars.entgravity * movevars.gravity * frametime)
		groundMove(pm)
	else
		airAccelerate(pm, wishdir, wishspeed, movevars.accelerate)
		pm.velocity -= vector.create(0, 0, movevars.entgravity * movevars.gravity * frametime)
		flyMove(pm)
	end
end

-- PM_CatagorizePosition
local function catagorizePosition(pm: PlayerMove)
	-- see if standing on something solid
	local point = vector.create(pm.origin.x, pm.origin.y, pm.origin.z - 1)
	if pm.velocity.z > 180 then
		onground = -1
	else
		local tr = playerTrace(pm, pm.origin, point)
		if tr.planeNormal.z < 0.7 then
			onground = -1 -- too steep
		else
			onground = tr.ent
		end
		if onground ~= -1 then
			pm.waterjumptime = 0
			if not tr.startsolid and not tr.allsolid then
				pm.origin = tr.endpos
			end
		end
		-- standing on an entity other than the world
		if tr.ent > 0 then
			pm.numtouch += 1
			pm.touchindex[pm.numtouch] = tr.ent
		end
	end

	-- get waterlevel
	waterlevel = 0
	watertype = CONTENTS_EMPTY

	local pt = vector.create(pm.origin.x, pm.origin.y, pm.origin.z + player_mins.z + 1)
	local cont = pointContents(pm, pt)
	if cont <= CONTENTS_WATER then
		watertype = cont
		waterlevel = 1
		pt = vector.create(pm.origin.x, pm.origin.y, pm.origin.z + (player_mins.z + player_maxs.z) * 0.5)
		cont = pointContents(pm, pt)
		if cont <= CONTENTS_WATER then
			waterlevel = 2
			pt = vector.create(pm.origin.x, pm.origin.y, pm.origin.z + 22)
			cont = pointContents(pm, pt)
			if cont <= CONTENTS_WATER then
				waterlevel = 3
			end
		end
	end
end

-- JumpButton
local function jumpButton(pm: PlayerMove)
	if pm.dead then
		pm.oldbuttons = bit32.bor(pm.oldbuttons, BUTTON_JUMP)
		return
	end

	if pm.waterjumptime ~= 0 then
		pm.waterjumptime -= frametime
		if pm.waterjumptime < 0 then
			pm.waterjumptime = 0
		end
		return
	end

	if waterlevel >= 2 then
		-- swimming, not jumping
		onground = -1
		local vz
		if watertype == CONTENTS_WATER then
			vz = 100
		elseif watertype == CONTENTS_SLIME then
			vz = 80
		else
			vz = 50
		end
		pm.velocity = vector.create(pm.velocity.x, pm.velocity.y, vz)
		return
	end

	if onground == -1 then
		return -- in air, so no effect
	end

	if bit32.band(pm.oldbuttons, BUTTON_JUMP) ~= 0 then
		return -- don't pogo stick
	end

	onground = -1
	pm.velocity += vector.create(0, 0, 270)
	pm.oldbuttons = bit32.bor(pm.oldbuttons, BUTTON_JUMP)
end

-- CheckWaterJump
local function checkWaterJump(pm: PlayerMove)
	if pm.waterjumptime ~= 0 then
		return
	end

	-- don't hop out if we just jumped in
	if pm.velocity.z < -180 then
		return
	end

	-- see if near an edge
	local flatforward = mathlib.normalize(vector.create(fwd.x, fwd.y, 0))

	local spot = pm.origin + flatforward * 24
	spot += vector.create(0, 0, 8)
	if pointContents(pm, spot) ~= CONTENTS_SOLID then
		return
	end
	spot += vector.create(0, 0, 24)
	if pointContents(pm, spot) ~= CONTENTS_EMPTY then
		return
	end
	-- jump out of water
	pm.velocity = vector.create(flatforward.x * 50, flatforward.y * 50, 310)
	pm.waterjumptime = 2 -- safety net
	pm.oldbuttons = bit32.bor(pm.oldbuttons, BUTTON_JUMP)
end

-- NudgePosition
local sign = { 0, -1, 1 }
local function nudgePosition(pm: PlayerMove)
	-- Subtlety preserved from the C: base is copied BEFORE the 1/8-grid
	-- truncation and all candidates derive from base, so the truncation is
	-- dead code — the first valid candidate restores the ORIGINAL origin.
	local base = pm.origin

	for z = 1, 3 do
		for x = 1, 3 do
			for y = 1, 3 do
				pm.origin = vector.create(
					base.x + sign[x] * (1 / 8),
					base.y + sign[y] * (1 / 8),
					base.z + sign[z] * (1 / 8)
				)
				if testPlayerPosition(pm, pm.origin) then
					return
				end
			end
		end
	end
	pm.origin = base
end

-- SpectatorMove
local function spectatorMove(pm: PlayerMove, movevars: MoveVars)
	-- friction
	local speed = vector.magnitude(pm.velocity)
	if speed < 1 then
		pm.velocity = vector.zero
	else
		local fric = movevars.friction * 1.5 -- extra friction
		local control = if speed < movevars.stopspeed then movevars.stopspeed else speed
		local drop = control * fric * frametime

		local newspeed = speed - drop
		if newspeed < 0 then
			newspeed = 0
		end
		newspeed /= speed
		pm.velocity *= newspeed
	end

	-- accelerate
	local fmove = pm.cmd.forwardmove
	local smove = pm.cmd.sidemove

	fwd = mathlib.normalize(fwd)
	right = mathlib.normalize(right)

	local wishvel = fwd * fmove + right * smove
	wishvel += vector.create(0, 0, pm.cmd.upmove)

	local wishspeed = vector.magnitude(wishvel)
	local wishdir = if wishspeed > 0 then wishvel / wishspeed else vector.zero

	if wishspeed > movevars.spectatormaxspeed then
		wishvel *= movevars.spectatormaxspeed / wishspeed
		wishspeed = movevars.spectatormaxspeed
	end

	local currentspeed = vector.dot(pm.velocity, wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = movevars.accelerate * frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	pm.velocity += wishdir * accelspeed

	-- move
	pm.origin += pm.velocity * frametime
end

-- PlayerMove: origin, angles, and velocity modified in place
function pmove.playerMove(pm: PlayerMove, movevars: MoveVars)
	frametime = pm.cmd.msec * 0.001
	pm.numtouch = 0

	fwd, right, up = mathlib.angleVectors(pm.angles)

	if pm.spectator then
		spectatorMove(pm, movevars)
		pm.onground = onground
		pm.waterlevel = waterlevel
		pm.watertype = watertype
		return
	end

	nudgePosition(pm)

	-- take angles directly from command
	pm.angles = pm.cmd.angles

	-- set onground, watertype, and waterlevel
	catagorizePosition(pm)

	if waterlevel == 2 then
		checkWaterJump(pm)
	end

	if pm.velocity.z < 0 then
		pm.waterjumptime = 0
	end

	if bit32.band(pm.cmd.buttons, BUTTON_JUMP) ~= 0 then
		jumpButton(pm)
	else
		pm.oldbuttons = bit32.band(pm.oldbuttons, bit32.bnot(BUTTON_JUMP))
	end

	friction(pm, movevars)

	if waterlevel >= 2 then
		waterMove(pm, movevars)
	else
		airMove(pm, movevars)
	end

	-- set onground, watertype, and waterlevel for final spot
	catagorizePosition(pm)

	pm.onground = onground
	pm.waterlevel = waterlevel
	pm.watertype = watertype
end

return pmove
