--!strict
-- Roblox avatars mode, server side (product layer, SHARED by the NQ and
-- QW boots): the roblox_avatars attribute on QuakeAssets toggles clients
-- rendering player entities as avatar rigs (mirrored onto the client FS
-- so it is live-flippable). The server publishes one neutralized R15 rig
-- per connected player under ReplicatedStorage.QuakeAvatars; clients
-- clone it locally. Each boot additionally sets RQSlot on connect (maps
-- entity/player number -> Player) and mirrors RQWeaponModel so clients
-- can attach the matching world model to the rig's hand.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- returns the per-player rig publisher; call it on connect
return function(assets: Instance, clientFS: Instance): (Player) -> ()
	-- avatars are a product-layer default: absent = ON; a place/preset
	-- opts out with an explicit roblox_avatars = false
	local avatarsAttr = "roblox_avatars"
	clientFS:SetAttribute(avatarsAttr, assets:GetAttribute(avatarsAttr) ~= false)
	assets:GetAttributeChangedSignal(avatarsAttr):Connect(function()
		clientFS:SetAttribute(avatarsAttr, assets:GetAttribute(avatarsAttr) ~= false)
	end)

	-- avatar HUD face: same product-layer default as the rigs — absent =
	-- ON; a place/preset opts out with an explicit avatar_face = false
	local faceAttr = "avatar_face"
	clientFS:SetAttribute(faceAttr, assets:GetAttribute(faceAttr) ~= false)
	assets:GetAttributeChangedSignal(faceAttr):Connect(function()
		clientFS:SetAttribute(faceAttr, assets:GetAttribute(faceAttr) ~= false)
	end)

	local avatarFolder = Instance.new("Folder")
	avatarFolder.Name = "QuakeAvatars"
	avatarFolder.Parent = ReplicatedStorage

	local inFlight: { [number]: boolean } = {}
	local function publishAvatarRig(player: Player)
		if avatarFolder:FindFirstChild(tostring(player.UserId)) or inFlight[player.UserId] then
			return
		end
		inFlight[player.UserId] = true
		task.spawn(function()
			local ok, rig = pcall(function()
				-- Studio multi-client test players are guests with NEGATIVE
				-- UserIds; description fetch rejects those (and can fail on
				-- network hiccups). Test guests borrow the place creator's
				-- avatar (override with a test_avatar_userid attribute) so
				-- tests exercise a REAL look — hats, layered clothing, anim
				-- pack — instead of the blank default.
				local fetchId = player.UserId
				if fetchId <= 0 then
					fetchId = if game.CreatorType == Enum.CreatorType.User then game.CreatorId else 0
					local override = assets:GetAttribute("test_avatar_userid")
					if typeof(override) == "number" and override > 0 then
						fetchId = override
					end
				end
				local desc: HumanoidDescription? = nil
				if fetchId > 0 then
					local okDesc, d = pcall(function()
						return Players:GetHumanoidDescriptionFromUserId(fetchId)
					end)
					if okDesc then
						desc = d
					end
				end
				if not desc then
					-- blank descriptions default EVERY body color to black
					-- (playtest: "all black mesh") — paint the guest rig
					local d = Instance.new("HumanoidDescription")
					local gray = Color3.fromRGB(163, 162, 165)
					d.HeadColor = gray
					d.TorsoColor = Color3.fromRGB(121, 128, 141)
					d.LeftArmColor = gray
					d.RightArmColor = gray
					d.LeftLegColor = Color3.fromRGB(87, 91, 101)
					d.RightLegColor = Color3.fromRGB(87, 91, 101)
					desc = d
				end
				local model = Players:CreateHumanoidModelFromDescription(desc :: HumanoidDescription, Enum.HumanoidRigType.R15)
				local descT = desc :: HumanoidDescription
				model:SetAttribute("IdleAnim", tonumber(descT.IdleAnimation) or 0)
				model:SetAttribute("RunAnim", tonumber(descT.RunAnimation) or 0)
				model:SetAttribute("JumpAnim", tonumber(descT.JumpAnimation) or 0)
				model:SetAttribute("FallAnim", tonumber(descT.FallAnimation) or 0)
				model:SetAttribute("SwimAnim", tonumber(descT.SwimAnimation) or 0)
				return model
			end)
			inFlight[player.UserId] = nil
			if not ok or not rig then
				warn(`[fragparty] avatar rig fetch failed for {player.Name}`)
				return
			end
			-- Neutralize interactions. Anchor ONLY the root: limbs must stay
			-- UNANCHORED so the client Animator can pose them via their
			-- Motor6D joints (an anchored part is pinned and ignores
			-- joint-driven motion). The anchored root pins the assembly, so
			-- unanchored limbs neither fall nor drift; clients position the
			-- rig by PivotTo-ing the model each frame.
			local rootPart = rig:FindFirstChild("HumanoidRootPart")
			for _, d in rig:GetDescendants() do
				if d:IsA("BasePart") then
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
					d.Anchored = d == rootPart
				elseif d:IsA("BaseScript") then
					d:Destroy() -- rigs are client-driven visuals only
				end
			end
			-- Publish at NATIVE avatar scale; clients normalize to the Quake
			-- player height after cloning (avatarrender). Never ScaleTo here:
			-- the humanoid re-applies description scaling asynchronously as
			-- avatar content loads (and re-attaches accessories, sometimes
			-- flipping their Weld to a RigidConstraint), and in
			-- ReplicatedStorage no solver ever reconciles part positions with
			-- joint data — an external ScaleTo racing that re-application
			-- published rigs whose accessory joints sat at a different scale
			-- than the body, which clients faithfully rendered as floating
			-- hair/hats. With the humanoid as the only writer every state it
			-- publishes is self-coherent, and the client clone lives in
			-- workspace where the solver keeps its single ScaleTo coherent.
			rig:PivotTo(CFrame.new(0, -100000, 0))
			rig.Name = tostring(player.UserId)
			rig.Parent = avatarFolder
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		local rig = avatarFolder:FindFirstChild(tostring(player.UserId))
		if rig then
			rig:Destroy()
		end
	end)

	return publishAvatarRig
end
