--!strict
--!optimize 2
-- Quake <-> Roblox coordinate conversion.
--
-- Quake: +X east, +Y north, +Z up (right-handed), units are ~inches.
-- Roblox: +X east, +Y up, -Z north (right-handed), units are studs.
-- Mapping: roblox = (qx, qz, -qy) * SCALE.

local qcoords = {}

qcoords.SCALE = 1 / 8 -- studs per quake unit

function qcoords.toRoblox(v: vector): Vector3
	return Vector3.new(v.x * qcoords.SCALE, v.z * qcoords.SCALE, -v.y * qcoords.SCALE)
end

-- direction (no scale)
function qcoords.dirToRoblox(v: vector): Vector3
	return Vector3.new(v.x, v.z, -v.y)
end

function qcoords.fromRoblox(v: Vector3): vector
	return vector.create(v.X / qcoords.SCALE, -v.Z / qcoords.SCALE, v.Y / qcoords.SCALE)
end

-- Build a Roblox CFrame from a Quake position and quake-space
-- forward/right/up basis vectors (from mathlib.angleVectors).
function qcoords.cframe(origin: vector, forward: vector, right: vector, up: vector): CFrame
	local pos = qcoords.toRoblox(origin)
	local f = qcoords.dirToRoblox(forward)
	local r = qcoords.dirToRoblox(right)
	local u = qcoords.dirToRoblox(up)
	return CFrame.fromMatrix(pos, r, u, -f)
end

return qcoords
