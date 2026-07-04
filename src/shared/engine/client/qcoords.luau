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

-- Build a CAMERA CFrame from a Quake position and quake-space
-- forward/right/up basis vectors (roblox cameras look along -Z).
function qcoords.cframe(origin: vector, forward: vector, right: vector, up: vector): CFrame
	local pos = qcoords.toRoblox(origin)
	local f = qcoords.dirToRoblox(forward)
	local r = qcoords.dirToRoblox(right)
	local u = qcoords.dirToRoblox(up)
	return CFrame.fromMatrix(pos, r, u, -f)
end

-- Build a MODEL CFrame: mesh vertices are quake model space converted with
-- toRoblox, so model-forward lies along mesh +X (and model-right along
-- mesh +Z). The part basis must map those axes to the world directions.
function qcoords.modelCFrame(origin: vector, forward: vector, right: vector, up: vector): CFrame
	local pos = qcoords.toRoblox(origin)
	local f = qcoords.dirToRoblox(forward)
	local r = qcoords.dirToRoblox(right)
	local u = qcoords.dirToRoblox(up)
	return CFrame.fromMatrix(pos, f, u, r)
end

-- CalcFov (screen.c): the fov cvar is the HORIZONTAL field of view at
-- the actual viewport aspect; Roblox FieldOfView is vertical. At 16:9,
-- fov 90 comes out ~58.7 vertical — hardcoding a 4:3 conversion makes
-- everything (especially the view weapon) render ~35% too small.
function qcoords.calcFovY(fovX: number, width: number, height: number): number
	if width <= 0 or height <= 0 then
		return 70
	end
	fovX = math.clamp(fovX, 1, 179)
	local x = width / math.tan(math.rad(fovX) / 2)
	return math.deg(2 * math.atan(height / x))
end

return qcoords
