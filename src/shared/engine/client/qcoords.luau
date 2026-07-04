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

-- SCR_CalcRefdef/R_SetVrect: at viewsize 100 the 3D view occupies the
-- window minus sb_lines (48 virtual px of status bar + inventory), so
-- fov_y derives from the REDUCED height and the projection center sits
-- sb/2 above the window center. Roblox cameras cannot shift the
-- projection center, so the world image stays window-centered (delta:
-- the vertical crop differs by sb/2) — but the VIEW MODEL, which in C
-- hugs the vrect bottom just above the sbar, is rotated up about the
-- camera by the center offset so its on-screen placement matches.
function qcoords.vrect(fovX: number, vpW: number, vpH: number, sbPx: number): (number, number)
	local vrectH = math.max(vpH - sbPx, 1)
	local fovY = qcoords.calcFovY(fovX, vpW, vrectH)
	-- rotation anchored so the vrect's bottom edge (where the C gun
	-- rests) lands at the sbar top in our window-centered projection:
	-- C row for the edge = vpH - sb; ours for depression phi' is
	-- vpH/2 * (1 + tan(phi')/tan(F)). Solving phi' and taking
	-- theta = F - phi' (F = fovY/2):
	local F = math.rad(fovY) / 2
	local phi = math.atan(math.tan(F) * (vpH - 2 * sbPx) / vpH)
	local gunPitch = math.deg(F - phi)
	return fovY, gunPitch
end

return qcoords
