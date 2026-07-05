--!strict
--!optimize 2
-- Closed-loop texture verification for the stochastic zombie-object
-- platform defect: EditableImages created during hot build stretches can
-- silently lose their GPU upload and render BLACK forever, while every
-- CPU-side read stays healthy (characterization: tools/
-- verify_editablepool.luau; bisect proved the defect predates all recent
-- code). Nothing repairs a zombie in place; recreation always heals.
-- Detection IS possible via a render round-trip: bind each image to a
-- quad in front of the camera, CaptureService:CaptureScreenshot, load
-- the capture into an EditableImage, and read the tile pixels back. A
-- solid-green control tile guards against systematic capture failure
-- (occlusion, API unavailable): if the control reads black, the pass
-- aborts without touching anything.

-- lune runs the pure helper (sourceHasArt) offline; resolve services
-- defensively like textures.luau does
local function svc(name: string): any
	local ok, service = pcall(function()
		return game:GetService(name)
	end)
	return if ok then service else nil
end
local AssetService = svc("AssetService") :: AssetService
local CaptureService = svc("CaptureService") :: CaptureService
local RunService = svc("RunService") :: RunService

local textures = require(script.Parent.textures)

local texverify = {}

local COLS = 8
local TILE = 1.0 -- studs
local GAP = 1.15
local MAX_PER_PAGE = 32
local ROUNDS = 3

-- one hygienic template quad, built lazily (dynamic -> fixed -> destroy)
local template: MeshPart? = nil
local templateFailed = false
local function getTemplate(): MeshPart?
	if template or templateFailed then
		return template
	end
	local ok, part = pcall(function(): MeshPart
		local em = AssetService:CreateEditableMesh()
		assert(em, "editable budget")
		local v1, v2 = em:AddVertex(Vector3.new(-0.5, -0.5, 0)), em:AddVertex(Vector3.new(0.5, -0.5, 0))
		local v3, v4 = em:AddVertex(Vector3.new(0.5, 0.5, 0)), em:AddVertex(Vector3.new(-0.5, 0.5, 0))
		local u1, u2 = em:AddUV(Vector2.new(0, 1)), em:AddUV(Vector2.new(1, 1))
		local u3, u4 = em:AddUV(Vector2.new(1, 0)), em:AddUV(Vector2.new(0, 0))
		local f1 = em:AddTriangle(v1, v2, v3)
		em:SetFaceUVs(f1, { u1, u2, u3 })
		local f2 = em:AddTriangle(v1, v3, v4)
		em:SetFaceUVs(f2, { u1, u3, u4 })
		local fixed = AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
		em:Destroy()
		local p = AssetService:CreateMeshPartAsync(Content.fromObject(fixed))
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.new(1, 1, 1)
		p.Size = Vector3.new(TILE, TILE, 0.05)
		return p
	end)
	if ok then
		template = part
	else
		templateFailed = true
		warn("[robloquake] texverify: template quad failed; verification disabled")
	end
	return template
end

local function captureToImage(): EditableImage?
	local contentId: string? = nil
	local ok = pcall(function()
		CaptureService:CaptureScreenshot(function(id: string)
			contentId = id
		end)
	end)
	if not ok then
		return nil
	end
	local t0 = os.clock()
	repeat
		task.wait(0.05)
	until contentId or os.clock() - t0 > 3
	if not contentId then
		return nil
	end
	local ok2, img = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(contentId :: string))
	end)
	return if ok2 then img else nil
end

-- render a batch of images as tiles, capture, read back; returns per-image
-- "renders bright" verdicts, or nil when the machinery itself failed
-- (control tile black / capture unavailable) — callers must not treat
-- nil as "all zombies".
local function renderCheck(imgs: { EditableImage }): { boolean }?
	local tpl = getTemplate()
	local cam = workspace.CurrentCamera
	if not tpl or not cam then
		return nil
	end

	local rig = Instance.new("Folder")
	rig.Name = "RQVerifyRig"
	rig.Parent = workspace

	-- neon backdrop: alpha texels show bright magenta, not the dark scene
	local backdrop = Instance.new("Part")
	backdrop.Anchored = true
	backdrop.CanCollide = false
	backdrop.CanQuery = false
	backdrop.Material = Enum.Material.Neon
	backdrop.Color = Color3.fromRGB(255, 0, 255)
	local rows = math.ceil((#imgs + 1) / COLS)
	backdrop.Size = Vector3.new(COLS * GAP + 1, rows * GAP + 1, 0.05)
	backdrop.Parent = rig

	local base = cam.CFrame * CFrame.new(0, 1.5, -8)
	backdrop.CFrame = base * CFrame.new(0, 0, 0.1)

	-- control tile (index 0): solid green, freshly created each pass
	local controlImg = AssetService:CreateEditableImage({ Size = Vector2.new(8, 8) })
	local tiles: { MeshPart } = {}
	local function place(i: number, img: EditableImage?)
		local q = (tpl :: MeshPart):Clone()
		if img then
			q.TextureContent = Content.fromObject(img)
		else
			q.Color = Color3.fromRGB(0, 255, 0) -- control fallback: plain part colour
		end
		q.CFrame = base * CFrame.new((i % COLS - (COLS - 1) / 2) * GAP, (math.floor(i / COLS) - (rows - 1) / 2) * GAP, 0)
		q.Parent = rig
		tiles[i + 1] = q
	end
	if controlImg then
		local px = buffer.create(8 * 8 * 4)
		for k = 0, 63 do
			buffer.writeu32(px, k * 4, 0xFF00FF00)
		end
		controlImg:WritePixelsBuffer(Vector2.zero, Vector2.new(8, 8), px)
	end
	place(0, controlImg)
	for i, img in imgs do
		place(i, img)
	end

	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()

	local cap = captureToImage()
	local verdicts: { boolean }? = nil
	if cap then
		local vp = cam.ViewportSize
		local sx = cap.Size.X / vp.X
		local sy = cap.Size.Y / vp.Y
		local function tileBright(i: number): number
			local q = tiles[i + 1]
			local best = 0
			for _, off in { Vector3.new(0, 0, 0), Vector3.new(-0.3, 0, 0), Vector3.new(0.3, 0, 0), Vector3.new(0, 0.3, 0), Vector3.new(0, -0.3, 0) } do
				local world = (q.CFrame * CFrame.new(off * TILE)).Position
				local sp, vis = cam:WorldToViewportPoint(world)
				if vis then
					local px = math.clamp(math.floor(sp.X * sx), 0, cap.Size.X - 1)
					local py = math.clamp(math.floor(sp.Y * sy), 0, cap.Size.Y - 1)
					local ok3, b = pcall(function()
						return cap:ReadPixelsBuffer(Vector2.new(px, py), Vector2.new(1, 1))
					end)
					if ok3 then
						best = math.max(best, buffer.readu8(b, 0) + buffer.readu8(b, 1) + buffer.readu8(b, 2))
					end
				end
			end
			return best
		end
		if tileBright(0) > 90 then -- control renders: machinery works
			verdicts = table.create(#imgs)
			for i = 1, #imgs do
				(verdicts :: { boolean })[i] = tileBright(i) > 36
			end
		else
			warn("[robloquake] texverify: control tile dark; skipping pass")
		end
		cap:Destroy()
	else
		warn("[robloquake] texverify: capture unavailable; skipping pass")
	end

	rig:Destroy()
	if controlImg then
		controlImg:Destroy()
	end
	return verdicts
end

export type Slot = {
	tbl: { [any]: EditableImage },
	key: any,
	pixels: buffer, -- source indexed pixels (for art check + recreation)
	w: number,
	h: number,
	alphaIndex: boolean,
	pal: textures.Palette,
}

-- verify a set of image slots; zombies are recreated from their source
-- pixels and swapped into their tables (old objects destroyed after the
-- handoff window). Returns checked, healed, unhealed.
function texverify.verifySlots(slots: { Slot }): (number, number, number)
	-- only slots whose source actually has bright art are decidable
	local decidable: { Slot } = {}
	for _, s in slots do
		if s.tbl[s.key] and textures.sourceHasArt(s.pixels, s.w, s.h, s.pal) then
			table.insert(decidable, s)
		end
	end
	local healed = 0
	for round = 1, ROUNDS do
		if #decidable == 0 then
			break
		end
		local stillBad: { Slot } = {}
		for page = 1, #decidable, MAX_PER_PAGE do
			local chunk: { Slot } = {}
			for i = page, math.min(page + MAX_PER_PAGE - 1, #decidable) do
				table.insert(chunk, decidable[i])
			end
			local imgs = table.create(#chunk)
			for i, s in chunk do
				imgs[i] = s.tbl[s.key]
			end
			local verdicts = renderCheck(imgs)
			if not verdicts then
				return #slots, healed, 0 -- machinery unavailable; not zombie counts
			end
			for i, s in chunk do
				if not verdicts[i] then
					table.insert(stillBad, s)
				end
			end
		end
		if #stillBad == 0 then
			return #slots, healed, 0
		end
		if round == ROUNDS then
			warn(`[robloquake] texverify: {#stillBad} images still dark after {ROUNDS} rounds`)
			return #slots, healed, #stillBad
		end
		for _, s in stillBad do
			local old = s.tbl[s.key]
			local fresh = textures.createImage(s.pixels, s.w, s.h, s.pal, s.alphaIndex)
			if fresh then
				s.tbl[s.key] = fresh
				healed += 1
				task.delay(1, function()
					old:Destroy()
				end)
			end
		end
		decidable = stillBad
		task.wait(0.1)
	end
	return #slots, healed, 0
end

return texverify
