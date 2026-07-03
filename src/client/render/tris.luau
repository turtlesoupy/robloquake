--!strict
--!optimize 2
-- WedgePart triangle rendering — fallback for when the Mesh & Image APIs
-- are not enabled. Draws arbitrary 3D triangles as pairs of right-angle
-- wedges (the classic Roblox technique).

local tris = {}

local WEDGE_DEPTH = 0.05

local function wedge(): WedgePart
	local w = Instance.new("WedgePart")
	w.Anchored = true
	w.CanCollide = false
	w.CanQuery = false
	w.CanTouch = false
	w.CastShadow = false
	w.Material = Enum.Material.SmoothPlastic
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	return w
end

-- Draw triangle a-b-c; returns the two wedge parts.
function tris.draw(a: Vector3, b: Vector3, c: Vector3, color: Color3, parent: Instance): (WedgePart?, WedgePart?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)

	-- put the longest edge opposite vertex a
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b

	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit

	if right ~= right or up ~= up or back ~= back then
		return nil, nil -- degenerate triangle
	end

	local height = math.abs(ab:Dot(up))

	local w1 = wedge()
	w1.Color = color
	w1.Size = Vector3.new(WEDGE_DEPTH, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	w1.Parent = parent

	local w2 = wedge()
	w2.Color = color
	w2.Size = Vector3.new(WEDGE_DEPTH, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	w2.Parent = parent

	return w1, w2
end

return tris
