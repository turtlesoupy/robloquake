--!strict
--!optimize 2
-- Vector/angle math — port of the pieces of WinQuake mathlib.c the engine
-- uses. Angles follow Quake conventions: PITCH = x, YAW = y, ROLL = z,
-- degrees.

local mathlib = {}

local DEG2RAD = math.pi * 2 / 360

export type Plane = {
	normal: vector,
	dist: number,
	type: number,
	signbits: number,
}

-- AngleVectors: returns forward, right, up
function mathlib.angleVectors(angles: vector): (vector, vector, vector)
	local angle = angles.y * DEG2RAD -- YAW
	local sy, cy = math.sin(angle), math.cos(angle)
	angle = angles.x * DEG2RAD -- PITCH
	local sp, cp = math.sin(angle), math.cos(angle)
	angle = angles.z * DEG2RAD -- ROLL
	local sr, cr = math.sin(angle), math.cos(angle)

	local forward = vector.create(cp * cy, cp * sy, -sp)
	local right = vector.create(-1 * sr * sp * cy + -1 * cr * -sy, -1 * sr * sp * sy + -1 * cr * cy, -1 * sr * cp)
	local up = vector.create(cr * sp * cy + -sr * -sy, cr * sp * sy + -sr * cy, cr * cp)
	return forward, right, up
end

-- VectorNormalize: returns normalized vector and original length
function mathlib.normalize(v: vector): (vector, number)
	local length = math.sqrt(vector.dot(v, v))
	if length == 0 then
		return vector.zero, 0
	end
	local ilength = 1 / length
	return v * ilength, length
end

-- BOX_ON_PLANE_SIDE macro + BoxOnPlaneSide: returns 1, 2, or 1+2
function mathlib.boxOnPlaneSide(emins: vector, emaxs: vector, p: Plane): number
	-- fast axial cases (the macro handles these before calling the function)
	local ptype = p.type
	if ptype < 3 then
		local mn = if ptype == 0 then emins.x elseif ptype == 1 then emins.y else emins.z
		local mx = if ptype == 0 then emaxs.x elseif ptype == 1 then emaxs.y else emaxs.z
		if p.dist <= mn then
			return 1
		elseif p.dist >= mx then
			return 2
		end
		return 3
	end

	-- general case: pick box corners by normal sign bits
	local n = p.normal
	local signbits = p.signbits
	local dist1, dist2
	if signbits == 0 then
		dist1 = n.x * emaxs.x + n.y * emaxs.y + n.z * emaxs.z
		dist2 = n.x * emins.x + n.y * emins.y + n.z * emins.z
	elseif signbits == 1 then
		dist1 = n.x * emins.x + n.y * emaxs.y + n.z * emaxs.z
		dist2 = n.x * emaxs.x + n.y * emins.y + n.z * emins.z
	elseif signbits == 2 then
		dist1 = n.x * emaxs.x + n.y * emins.y + n.z * emaxs.z
		dist2 = n.x * emins.x + n.y * emaxs.y + n.z * emins.z
	elseif signbits == 3 then
		dist1 = n.x * emins.x + n.y * emins.y + n.z * emaxs.z
		dist2 = n.x * emaxs.x + n.y * emaxs.y + n.z * emins.z
	elseif signbits == 4 then
		dist1 = n.x * emaxs.x + n.y * emaxs.y + n.z * emins.z
		dist2 = n.x * emins.x + n.y * emins.y + n.z * emaxs.z
	elseif signbits == 5 then
		dist1 = n.x * emins.x + n.y * emaxs.y + n.z * emins.z
		dist2 = n.x * emaxs.x + n.y * emins.y + n.z * emaxs.z
	elseif signbits == 6 then
		dist1 = n.x * emaxs.x + n.y * emins.y + n.z * emins.z
		dist2 = n.x * emins.x + n.y * emaxs.y + n.z * emaxs.z
	elseif signbits == 7 then
		dist1 = n.x * emins.x + n.y * emins.y + n.z * emins.z
		dist2 = n.x * emaxs.x + n.y * emaxs.y + n.z * emaxs.z
	else
		error("BoxOnPlaneSide: bad signbits")
	end

	local sides = 0
	if dist1 >= p.dist then
		sides = 1
	end
	if dist2 < p.dist then
		sides += 2
	end
	return sides
end

-- vec3 component access by axis index (0/1/2), used where C indexes vec3_t
function mathlib.comp(v: vector, axis: number): number
	return if axis == 0 then v.x elseif axis == 1 then v.y else v.z
end

function mathlib.setComp(v: vector, axis: number, value: number): vector
	if axis == 0 then
		return vector.create(value, v.y, v.z)
	elseif axis == 1 then
		return vector.create(v.x, value, v.z)
	end
	return vector.create(v.x, v.y, value)
end

-- C (int) cast: truncation toward zero
function mathlib.trunc(x: number): number
	return if x >= 0 then math.floor(x) else math.ceil(x)
end

-- anglemod from mathlib.c (the engine version, used by SV_ChangeYaw):
-- 360.0/65536 quantization
function mathlib.anglemod(a: number): number
	return (360 / 65536) * bit32.band(mathlib.trunc(a * (65536 / 360)), 65535)
end

return mathlib
