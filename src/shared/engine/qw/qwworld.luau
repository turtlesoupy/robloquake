--!strict
--!optimize 2
-- QW world query functions — port of QW/server/world.c (box hulls, entity
-- area links, point contents, SV_Move). Identical algorithms to the NQ
-- world.c port, but the entvars/globals offsets come from qwdefs at
-- world.new time because the QW progs ABI differs.

local bsp = require("../bsp/bsp")
local mathlib = require("../common/mathlib")
local vmlib = require("../progs/vm")
local qd = require("../quakedef")
local qwdefslib = require("./qwdefs")

local world = {}

local DIST_EPSILON = 0.03125 -- 1/32 to keep floating point happy
local AREA_DEPTH = 4
local MAX_ENT_LEAFS = 16

-- injected from qwdefs.build at world.new
local ent: { [string]: number } = {}
local glob: { [string]: number } = {}

export type Trace = {
	allsolid: boolean,
	startsolid: boolean,
	inopen: boolean,
	inwater: boolean,
	fraction: number,
	endpos: vector,
	planeNormal: vector,
	planeDist: number,
	ent: vmlib.Edict?,
}

type Link = {
	prev: Link?,
	next: Link?,
	ed: vmlib.Edict?, -- nil for list sentinels
}

export type AreaNode = {
	axis: number, -- -1 = leaf node
	dist: number,
	children: { AreaNode },
	trigger_edicts: Link,
	solid_edicts: Link,
}

export type World = {
	vm: vmlib.VM,
	worldmodel: bsp.Model,
	-- brush models by modelindex (sparse; only SOLID_BSP entities need it)
	brushModels: { [number]: bsp.Model },
	areanodes: { AreaNode },
	-- box hull (SV_InitBoxHull)
	boxHull: bsp.Hull,
	boxPlanes: { bsp.Plane },
}

--------------------------------------------------------------------------
-- intrusive links (ClearLink / InsertLinkBefore / RemoveLink)

local function newSentinel(): Link
	local l: Link = { prev = nil, next = nil, ed = nil }
	l.prev = l
	l.next = l
	return l
end

local function removeLink(l: Link)
	local nxt = l.next :: Link
	local prv = l.prev :: Link
	nxt.prev = prv
	prv.next = nxt
end

local function insertLinkBefore(l: Link, before: Link)
	l.next = before
	l.prev = before.prev
	;(l.prev :: Link).next = l
	;(l.next :: Link).prev = l
end

local function edictLink(ed: vmlib.Edict): Link
	local l = ed.area :: Link?
	if not l then
		l = { prev = nil, next = nil, ed = ed }
		ed.area = l
	end
	return l :: Link
end

--------------------------------------------------------------------------
-- construction

-- SV_InitBoxHull: set up planes and clipnodes so the six floats of a
-- bounding box can be stored out into a proper hull
local function initBoxHull(): (bsp.Hull, { bsp.Plane })
	local planenum = table.create(6)
	local child0 = table.create(6)
	local child1 = table.create(6)
	local planes: { bsp.Plane } = table.create(6)

	for i = 0, 5 do
		planenum[i + 1] = i
		local side = i % 2
		local empty = qd.CONTENTS_EMPTY
		local other = if i ~= 5 then i + 1 else qd.CONTENTS_SOLID
		if side == 0 then
			child0[i + 1] = empty
			child1[i + 1] = other
		else
			child1[i + 1] = empty
			child0[i + 1] = other
		end
		local axis = bit32.rshift(i, 1)
		planes[i + 1] = {
			normal = mathlib.setComp(vector.zero, axis, 1),
			dist = 0,
			type = axis,
			signbits = 0,
		}
	end

	local hull: bsp.Hull = {
		clipnodes = { planenum = planenum, child0 = child0, child1 = child1 },
		planes = planes,
		firstclipnode = 0,
		lastclipnode = 5,
		clip_mins = vector.zero,
		clip_maxs = vector.zero,
	}
	return hull, planes
end

-- SV_CreateAreaNode
local function createAreaNode(w: World, depth: number, mins: vector, maxs: vector): AreaNode
	local anode: AreaNode = {
		axis = -1,
		dist = 0,
		children = {},
		trigger_edicts = newSentinel(),
		solid_edicts = newSentinel(),
	}
	table.insert(w.areanodes, anode)

	if depth == AREA_DEPTH then
		return anode
	end

	local size = maxs - mins
	local axis = if size.x > size.y then 0 else 1
	anode.axis = axis
	anode.dist = 0.5 * (mathlib.comp(maxs, axis) + mathlib.comp(mins, axis))

	local maxs1 = mathlib.setComp(maxs, axis, anode.dist)
	local mins2 = mathlib.setComp(mins, axis, anode.dist)

	anode.children[1] = createAreaNode(w, depth + 1, mins2, maxs)
	anode.children[2] = createAreaNode(w, depth + 1, mins, maxs1)

	return anode
end

-- SV_ClearWorld
function world.new(vm: vmlib.VM, worldmodel: bsp.Model, brushModels: { [number]: bsp.Model }, qdefs: qwdefslib.QwDefs): World
	ent = qdefs.ent
	glob = qdefs.glob
	local boxHull, boxPlanes = initBoxHull()
	local w: World = {
		vm = vm,
		worldmodel = worldmodel,
		brushModels = brushModels,
		areanodes = {},
		boxHull = boxHull,
		boxPlanes = boxPlanes,
	}
	createAreaNode(w, 0, worldmodel.mins, worldmodel.maxs)
	return w
end

--------------------------------------------------------------------------
-- hulls

-- SV_HullForBox
local function hullForBox(w: World, mins: vector, maxs: vector): bsp.Hull
	local p = w.boxPlanes
	p[1].dist = maxs.x
	p[2].dist = mins.x
	p[3].dist = maxs.y
	p[4].dist = mins.y
	p[5].dist = maxs.z
	p[6].dist = mins.z
	return w.boxHull
end

-- SV_HullForEntity: returns hull and the offset to add to the testing
-- object's origin to get a point in hull space
function world.hullForEntity(w: World, ed: vmlib.Edict, mins: vector, maxs: vector): (bsp.Hull, vector)
	if vmlib.edFloat(ed, ent.solid) == qd.SOLID_BSP then
		-- explicit hulls in the BSP model
		if vmlib.edFloat(ed, ent.movetype) ~= qd.MOVETYPE_PUSH then
			error("SOLID_BSP without MOVETYPE_PUSH")
		end
		local model = w.brushModels[vmlib.edFloat(ed, ent.modelindex)]
		if not model then
			error("MOVETYPE_PUSH with a non bsp model")
		end

		local size = maxs - mins
		local hull
		if size.x < 3 then
			hull = model.hulls[1]
		elseif size.x <= 32 then
			hull = model.hulls[2]
		else
			hull = model.hulls[3]
		end

		-- calculate an offset value to center the origin
		local offset = hull.clip_mins - mins + vmlib.edVector(ed, ent.origin)
		return hull, offset
	end

	-- create a temp hull from bounding box sizes
	local hullmins = vmlib.edVector(ed, ent.mins) - maxs
	local hullmaxs = vmlib.edVector(ed, ent.maxs) - mins
	return hullForBox(w, hullmins, hullmaxs), vmlib.edVector(ed, ent.origin)
end

--------------------------------------------------------------------------
-- point testing

-- SV_HullPointContents
function world.hullPointContents(hull: bsp.Hull, num: number, p: vector): number
	local cn = hull.clipnodes
	local planes = hull.planes
	while num >= 0 do
		if num < hull.firstclipnode or num > hull.lastclipnode then
			error("SV_HullPointContents: bad node number")
		end
		local plane = planes[cn.planenum[num + 1] + 1]
		local d
		if plane.type < 3 then
			d = mathlib.comp(p, plane.type) - plane.dist
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

-- SV_PointContents: QW does NOT collapse CONTENTS_CURRENT_* to WATER
-- (that collapse is WinQuake-only; QW world.c:489 returns raw contents)
function world.pointContents(w: World, p: vector): number
	return world.hullPointContents(w.worldmodel.hulls[1], 0, p)
end

function world.truePointContents(w: World, p: vector): number
	return world.hullPointContents(w.worldmodel.hulls[1], 0, p)
end

--------------------------------------------------------------------------
-- line testing

local function newTrace(): Trace
	return {
		allsolid = false,
		startsolid = false,
		inopen = false,
		inwater = false,
		fraction = 0,
		endpos = vector.zero,
		planeNormal = vector.zero,
		planeDist = 0,
		ent = nil,
	}
end

-- SV_RecursiveHullCheck
function world.recursiveHullCheck(
	hull: bsp.Hull,
	num: number,
	p1f: number,
	p2f: number,
	p1: vector,
	p2: vector,
	trace: Trace
): boolean
	-- check for empty
	if num < 0 then
		if num ~= qd.CONTENTS_SOLID then
			trace.allsolid = false
			if num == qd.CONTENTS_EMPTY then
				trace.inopen = true
			else
				trace.inwater = true
			end
		else
			trace.startsolid = true
		end
		return true -- empty
	end

	if num < hull.firstclipnode or num > hull.lastclipnode then
		error("SV_RecursiveHullCheck: bad node number")
	end

	-- find the point distances
	local cn = hull.clipnodes
	local plane = hull.planes[cn.planenum[num + 1] + 1]

	local t1, t2
	if plane.type < 3 then
		t1 = mathlib.comp(p1, plane.type) - plane.dist
		t2 = mathlib.comp(p2, plane.type) - plane.dist
	else
		t1 = vector.dot(plane.normal, p1) - plane.dist
		t2 = vector.dot(plane.normal, p2) - plane.dist
	end

	if t1 >= 0 and t2 >= 0 then
		return world.recursiveHullCheck(hull, cn.child0[num + 1], p1f, p2f, p1, p2, trace)
	end
	if t1 < 0 and t2 < 0 then
		return world.recursiveHullCheck(hull, cn.child1[num + 1], p1f, p2f, p1, p2, trace)
	end

	-- put the crosspoint DIST_EPSILON pixels on the near side
	local frac
	if t1 < 0 then
		frac = (t1 + DIST_EPSILON) / (t1 - t2)
	else
		frac = (t1 - DIST_EPSILON) / (t1 - t2)
	end
	frac = math.clamp(frac, 0, 1)

	local midf = p1f + (p2f - p1f) * frac
	local mid = p1 + (p2 - p1) * frac

	local side = if t1 < 0 then 1 else 0
	local nearChild = if side == 0 then cn.child0[num + 1] else cn.child1[num + 1]
	local farChild = if side == 0 then cn.child1[num + 1] else cn.child0[num + 1]

	-- move up to the node
	if not world.recursiveHullCheck(hull, nearChild, p1f, midf, p1, mid, trace) then
		return false
	end

	if world.hullPointContents(hull, farChild, mid) ~= qd.CONTENTS_SOLID then
		-- go past the node
		return world.recursiveHullCheck(hull, farChild, midf, p2f, mid, p2, trace)
	end

	if trace.allsolid then
		return false -- never got out of the solid area
	end

	-- the other side of the node is solid, this is the impact point
	if side == 0 then
		trace.planeNormal = plane.normal
		trace.planeDist = plane.dist
	else
		trace.planeNormal = -plane.normal
		trace.planeDist = -plane.dist
	end

	while world.hullPointContents(hull, hull.firstclipnode, mid) == qd.CONTENTS_SOLID do
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

-- SV_ClipMoveToEntity
function world.clipMoveToEntity(w: World, ed: vmlib.Edict, start: vector, mins: vector, maxs: vector, endp: vector): Trace
	local trace = newTrace()
	trace.fraction = 1
	trace.allsolid = true
	trace.endpos = endp

	-- get the clipping hull
	local hull, offset = world.hullForEntity(w, ed, mins, maxs)

	local start_l = start - offset
	local end_l = endp - offset

	-- trace a line through the appropriate clipping hull
	world.recursiveHullCheck(hull, hull.firstclipnode, 0, 1, start_l, end_l, trace)

	-- fix trace up by the offset
	if trace.fraction ~= 1 then
		trace.endpos += offset
	end

	-- did we clip the move?
	if trace.fraction < 1 or trace.startsolid then
		trace.ent = ed
	end

	return trace
end

--------------------------------------------------------------------------
-- entity area linkage

-- SV_UnlinkEdict
function world.unlinkEdict(ed: vmlib.Edict)
	local l = ed.area :: Link?
	if not l or not l.prev then
		return -- not linked in anywhere
	end
	removeLink(l)
	l.prev = nil
	l.next = nil
end

-- SV_TouchLinks
local function touchLinks(w: World, ed: vmlib.Edict, node: AreaNode)
	local vm = w.vm
	local g = vm.globals
	local absmin = vmlib.edVector(ed, ent.absmin)
	local absmax = vmlib.edVector(ed, ent.absmax)

	local sentinel = node.trigger_edicts
	local l = sentinel.next :: Link
	while l ~= sentinel do
		local nxt = l.next :: Link
		local touch = l.ed :: vmlib.Edict
		if touch ~= ed then
			local touchFn = vmlib.edInt(touch, ent.touch)
			if touchFn ~= 0 and vmlib.edFloat(touch, ent.solid) == qd.SOLID_TRIGGER then
				local tmin = vmlib.edVector(touch, ent.absmin)
				local tmax = vmlib.edVector(touch, ent.absmax)
				if
					not (
						absmin.x > tmax.x
						or absmin.y > tmax.y
						or absmin.z > tmax.z
						or absmax.x < tmin.x
						or absmax.y < tmin.y
						or absmax.z < tmin.z
					)
				then
					local old_self = buffer.readi32(g, glob.self * 4)
					local old_other = buffer.readi32(g, glob.other * 4)

					buffer.writei32(g, glob.self * 4, touch.num)
					buffer.writei32(g, glob.other * 4, ed.num)
					buffer.writef32(g, glob.time * 4, vm.time)
					vmlib.exec(vm, touchFn)

					buffer.writei32(g, glob.self * 4, old_self)
					buffer.writei32(g, glob.other * 4, old_other)
					-- re-read our bounds: the touch function may have moved us
					absmin = vmlib.edVector(ed, ent.absmin)
					absmax = vmlib.edVector(ed, ent.absmax)
				end
			end
		end
		l = nxt
	end

	-- recurse down both sides
	if node.axis == -1 then
		return
	end
	if mathlib.comp(absmax, node.axis) > node.dist then
		touchLinks(w, ed, node.children[1])
	end
	if mathlib.comp(absmin, node.axis) < node.dist then
		touchLinks(w, ed, node.children[2])
	end
end

-- SV_FindTouchedLeafs: walks the world node tree; child is the C-encoded
-- child value (>= 0 node index, < 0 is -(leafnum+1))
local function findTouchedLeafs(w: World, ed: vmlib.Edict, child: number, absmin: vector, absmax: vector)
	local data = w.worldmodel.brush
	if child < 0 then
		-- leaf (or solid)
		local leaf = data.leafs[-child]
		if leaf.contents == qd.CONTENTS_SOLID then
			return
		end
		if ed.num_leafs == MAX_ENT_LEAFS then
			return
		end
		ed.num_leafs += 1
		ed.leafnums[ed.num_leafs] = leaf.num - 1
		return
	end

	-- NODE_MIXED
	local node = data.nodes[child + 1]
	local splitplane = data.planes[node.planenum + 1]
	local sides = mathlib.boxOnPlaneSide(absmin, absmax, splitplane)

	-- recurse down the contacted sides
	if bit32.band(sides, 1) ~= 0 then
		findTouchedLeafs(w, ed, node.children[1], absmin, absmax)
	end
	if bit32.band(sides, 2) ~= 0 then
		findTouchedLeafs(w, ed, node.children[2], absmin, absmax)
	end
end

-- SV_LinkEdict
function world.linkEdict(w: World, ed: vmlib.Edict, touch_triggers: boolean)
	local link = edictLink(ed)
	if link.prev then
		world.unlinkEdict(ed) -- unlink from old position
	end

	if ed.num == 0 then
		return -- don't add the world
	end
	if ed.free then
		return
	end

	-- set the abs box
	local origin = vmlib.edVector(ed, ent.origin)
	local absmin = origin + vmlib.edVector(ed, ent.mins)
	local absmax = origin + vmlib.edVector(ed, ent.maxs)

	-- to make items easier to pick up and allow them to be grabbed off of
	-- shelves, the abs sizes are expanded
	if bit32.band(vmlib.edFloat(ed, ent.flags), qd.FL_ITEM) ~= 0 then
		absmin = vector.create(absmin.x - 15, absmin.y - 15, absmin.z)
		absmax = vector.create(absmax.x + 15, absmax.y + 15, absmax.z)
	else
		-- movement is clipped an epsilon away from actual edges, so we must
		-- fully check even when bounding boxes don't quite touch
		absmin -= vector.one
		absmax += vector.one
	end
	vmlib.edSetVector(ed, ent.absmin, absmin)
	vmlib.edSetVector(ed, ent.absmax, absmax)

	-- link to PVS leafs
	ed.num_leafs = 0
	if vmlib.edFloat(ed, ent.modelindex) ~= 0 then
		findTouchedLeafs(w, ed, 0, absmin, absmax)
	end

	if vmlib.edFloat(ed, ent.solid) == qd.SOLID_NOT then
		return
	end

	-- find the first node that the ent's box crosses
	local node = w.areanodes[1]
	while true do
		if node.axis == -1 then
			break
		end
		if mathlib.comp(absmin, node.axis) > node.dist then
			node = node.children[1]
		elseif mathlib.comp(absmax, node.axis) < node.dist then
			node = node.children[2]
		else
			break -- crosses the node
		end
	end

	-- link it in
	if vmlib.edFloat(ed, ent.solid) == qd.SOLID_TRIGGER then
		insertLinkBefore(link, node.trigger_edicts)
	else
		insertLinkBefore(link, node.solid_edicts)
	end

	-- if touch_triggers, touch all entities at this node and descend for more
	if touch_triggers then
		touchLinks(w, ed, w.areanodes[1])
	end
end

--------------------------------------------------------------------------
-- SV_Move

type MoveClip = {
	boxmins: vector,
	boxmaxs: vector,
	mins: vector,
	maxs: vector,
	mins2: vector,
	maxs2: vector,
	start: vector,
	endp: vector,
	trace: Trace,
	type: number,
	passedict: vmlib.Edict?,
}

-- SV_ClipToLinks: mins and maxs enclose the entire area swept by the move
local function clipToLinks(w: World, node: AreaNode, clip: MoveClip)
	local vm = w.vm

	local sentinel = node.solid_edicts
	local l = sentinel.next :: Link
	while l ~= sentinel do
		local nxt = l.next :: Link
		local touch = l.ed :: vmlib.Edict
		local solid = vmlib.edFloat(touch, ent.solid)
		local skip = false

		if solid == qd.SOLID_NOT then
			skip = true
		elseif touch == clip.passedict then
			skip = true
		elseif solid == qd.SOLID_TRIGGER then
			error("Trigger in clipping list")
		end

		if not skip and clip.type == qd.MOVE_NOMONSTERS and solid ~= qd.SOLID_BSP then
			skip = true
		end

		if not skip then
			local tmin = vmlib.edVector(touch, ent.absmin)
			local tmax = vmlib.edVector(touch, ent.absmax)
			if
				clip.boxmins.x > tmax.x
				or clip.boxmins.y > tmax.y
				or clip.boxmins.z > tmax.z
				or clip.boxmaxs.x < tmin.x
				or clip.boxmaxs.y < tmin.y
				or clip.boxmaxs.z < tmin.z
			then
				skip = true
			end
		end

		local passedict = clip.passedict
		if not skip and passedict then
			if vmlib.edVector(passedict, ent.size).x ~= 0 and vmlib.edVector(touch, ent.size).x == 0 then
				skip = true -- points never interact
			end
		end

		if not skip then
			-- might intersect, so do an exact clip
			if clip.trace.allsolid then
				return
			end
			if passedict then
				if vmlib.edInt(touch, ent.owner) == passedict.num then
					skip = true -- don't clip against own missiles
				elseif vmlib.edInt(passedict, ent.owner) == touch.num then
					skip = true -- don't clip against owner
				end
			end

			if not skip then
				local trace
				if bit32.band(vmlib.edFloat(touch, ent.flags), qd.FL_MONSTER) ~= 0 then
					trace = world.clipMoveToEntity(w, touch, clip.start, clip.mins2, clip.maxs2, clip.endp)
				else
					trace = world.clipMoveToEntity(w, touch, clip.start, clip.mins, clip.maxs, clip.endp)
				end
				if trace.allsolid or trace.startsolid or trace.fraction < clip.trace.fraction then
					trace.ent = touch
					if clip.trace.startsolid then
						clip.trace = trace
						clip.trace.startsolid = true
					else
						clip.trace = trace
					end
				elseif trace.startsolid then
					clip.trace.startsolid = true
				end
			end
		end
		l = nxt
	end

	-- recurse down both sides
	if node.axis == -1 then
		return
	end
	if mathlib.comp(clip.boxmaxs, node.axis) > node.dist then
		clipToLinks(w, node.children[1], clip)
	end
	if mathlib.comp(clip.boxmins, node.axis) < node.dist then
		clipToLinks(w, node.children[2], clip)
	end
end

-- SV_MoveBounds
local function moveBounds(start: vector, mins: vector, maxs: vector, endp: vector): (vector, vector)
	local bmin = vector.min(start, endp) + mins - vector.one
	local bmax = vector.max(start, endp) + maxs + vector.one
	return bmin, bmax
end

-- SV_Move
function world.move(
	w: World,
	start: vector,
	mins: vector,
	maxs: vector,
	endp: vector,
	movetype: number,
	passedict: vmlib.Edict?
): Trace
	-- clip to world
	local worldEd = vmlib.edictNum(w.vm, 0)
	local clip: MoveClip = {
		boxmins = vector.zero,
		boxmaxs = vector.zero,
		mins = mins,
		maxs = maxs,
		mins2 = mins,
		maxs2 = maxs,
		start = start,
		endp = endp,
		trace = world.clipMoveToEntity(w, worldEd, start, mins, maxs, endp),
		type = movetype,
		passedict = passedict,
	}

	if movetype == qd.MOVE_MISSILE then
		clip.mins2 = vector.create(-15, -15, -15)
		clip.maxs2 = vector.create(15, 15, 15)
	end

	-- create the bounding box of the entire move
	clip.boxmins, clip.boxmaxs = moveBounds(start, clip.mins2, clip.maxs2, endp)

	-- clip to entities
	clipToLinks(w, w.areanodes[1], clip)

	return clip.trace
end

-- SV_TestEntityPosition: returns the world edict if stuck, nil otherwise
function world.testEntityPosition(w: World, ed: vmlib.Edict): vmlib.Edict?
	local origin = vmlib.edVector(ed, ent.origin)
	local trace =
		world.move(w, origin, vmlib.edVector(ed, ent.mins), vmlib.edVector(ed, ent.maxs), origin, qd.MOVE_NORMAL, ed)
	if trace.startsolid then
		return vmlib.edictNum(w.vm, 0)
	end
	return nil
end

return world
