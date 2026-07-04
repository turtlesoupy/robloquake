--!strict
--!optimize 2
-- R_LightPoint — port of r_light.c's RecursiveLightPoint: trace straight
-- down through the world nodes, find the surface under the point, and read
-- its lightmap (all style layers scaled by the current style values).

local bsp = require("../bsp/bsp")

local lightpoint = {}

local function recursiveLightPoint(
	data: bsp.BspData,
	child: number,
	startp: vector,
	endp: vector,
	styleValue: (style: number) -> number
): number
	if child < 0 then
		return -1 -- solid or empty leaf: didn't hit anything
	end

	local node = data.nodes[child + 1]
	local plane = data.planes[node.planenum + 1]
	local front = vector.dot(startp, plane.normal) - plane.dist
	local back = vector.dot(endp, plane.normal) - plane.dist
	local side = front < 0

	local frontChild = if side then node.children[2] else node.children[1]
	local backChild = if side then node.children[1] else node.children[2]

	if (back < 0) == side then
		return recursiveLightPoint(data, frontChild, startp, endp, styleValue)
	end

	local frac = front / (front - back)
	local mid = startp + (endp - startp) * frac

	-- go down front side
	local r = recursiveLightPoint(data, frontChild, startp, mid, styleValue)
	if r >= 0 then
		return r -- hit something
	end

	if (back < 0) == side then
		return -1 -- didn't hit anything
	end

	-- check for impact on this node's surfaces
	for i = 0, node.numsurfaces - 1 do
		local surf = data.surfaces[node.firstsurface + i + 1]
		if bit32.band(surf.flags, bsp.SURF_DRAWTILED) ~= 0 then
			continue -- no lightmaps
		end
		local tex = data.texinfo[surf.texinfonum + 1]
		local vecs = tex.vecs

		local s = mid.x * vecs[1] + mid.y * vecs[2] + mid.z * vecs[3] + vecs[4]
		local t = mid.x * vecs[5] + mid.y * vecs[6] + mid.z * vecs[7] + vecs[8]

		if s < surf.texturemins[1] or t < surf.texturemins[2] then
			continue
		end
		local ds = s - surf.texturemins[1]
		local dt = t - surf.texturemins[2]
		if ds > surf.extents[1] or dt > surf.extents[2] then
			continue
		end

		local lightdata = data.lightdata
		if not lightdata or surf.lightofs < 0 then
			return 0
		end

		ds = bit32.rshift(math.floor(ds), 4)
		dt = bit32.rshift(math.floor(dt), 4)

		local smax = bit32.rshift(surf.extents[1], 4) + 1
		local tmax = bit32.rshift(surf.extents[2], 4) + 1
		local ofs = surf.lightofs + dt * smax + ds

		local total = 0
		for layer = 1, 4 do
			local style = surf.styles[layer]
			if style == 255 then
				break
			end
			if ofs < buffer.len(lightdata) then
				total += buffer.readu8(lightdata, ofs) * styleValue(style)
			end
			ofs += smax * tmax
		end
		return bit32.rshift(math.floor(total), 8)
	end

	-- go down back side
	return recursiveLightPoint(data, backChild, mid, endp, styleValue)
end

-- R_LightPoint: light level (0..255-ish) under quake-space point p
function lightpoint.at(model: bsp.Model, p: vector, styleValue: (style: number) -> number): number
	local data = model.brush
	if not data.lightdata then
		return 255
	end
	local endp = vector.create(p.x, p.y, p.z - 2048)
	local r = recursiveLightPoint(data, 0, p, endp, styleValue)
	if r == -1 then
		r = 0
	end
	return r
end

return lightpoint
