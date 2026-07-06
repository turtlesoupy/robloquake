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

local qcoords = require(ReplicatedStorage:WaitForChild("Shared").engine.client.qcoords)

-- rigs are normalized to the 56qu player height: the hitbox is the same
-- for everyone, so short/tall avatar body scales must not misrepresent it
local QUAKE_PLAYER_HEIGHT = 56 * qcoords.SCALE

-- returns the per-player rig publisher; call it on connect
return function(assets: Instance, clientFS: Instance): (Player) -> ()
	-- avatars are a product-layer default: absent = ON; a place/preset
	-- opts out with an explicit roblox_avatars = false
	local avatarsAttr = "roblox_avatars"
	clientFS:SetAttribute(avatarsAttr, assets:GetAttribute(avatarsAttr) ~= false)
	assets:GetAttributeChangedSignal(avatarsAttr):Connect(function()
		clientFS:SetAttribute(avatarsAttr, assets:GetAttribute(avatarsAttr) ~= false)
	end)

	local avatarFolder = Instance.new("Folder")
	avatarFolder.Name = "QuakeAvatars"
	avatarFolder.Parent = ReplicatedStorage

	local function publishAvatarRig(player: Player)
		if
			avatarFolder:FindFirstChild(tostring(player.UserId))
			or avatarFolder:FindFirstChild(`pending_{player.UserId}`)
		then
			return
		end
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
			if not ok or not rig then
				warn(`[robloquake] avatar rig fetch failed for {player.Name}`)
				return
			end
			-- neutralize interactions but keep JOINTS LIVE for now: only the
			-- root is anchored, so the assembly hangs from it and welded
			-- accessories track their body parts while the rig is scaled
			-- (scaling a fully anchored rig strands hats/hair in place)
			for _, d in rig:GetDescendants() do
				if d:IsA("BasePart") then
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
				elseif d:IsA("BaseScript") then
					d:Destroy() -- rigs are client-driven visuals only
				end
			end
			local rootPart = rig:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				rootPart.Anchored = true
			end
			-- normalize to the Quake player height (foot sole to head top).
			-- Park the rig under a temp name while it settles — clients
			-- wait on the userId name.
			rig.Name = `pending_{player.UserId}`
			rig:PivotTo(CFrame.new(0, -100000, 0))
			rig.Parent = avatarFolder
			local humanoid = rig:FindFirstChildOfClass("Humanoid")
			local head = rig:FindFirstChild("Head")
			local foot = rig:FindFirstChild("LeftFoot") or rig:FindFirstChild("RightFoot")
			if head and head:IsA("BasePart") and foot and foot:IsA("BasePart") then
				local function height(): number
					return (head.Position.Y + head.Size.Y / 2) - (foot.Position.Y - foot.Size.Y / 2)
				end
				-- the humanoid re-applies description scaling whenever the
				-- avatar's async content (accessories/meshes) finishes
				-- loading, multiplying onto current part sizes — a single
				-- ScaleTo gets silently distorted afterward, on a timetable
				-- that depends on cache warmth. Chase the target until the
				-- measured height HOLDS through a settle window.
				local deadline = os.clock() + 6
				while os.clock() < deadline do
					local h = height()
					if h > 1 and math.abs(h - QUAKE_PLAYER_HEIGHT) < 0.02 then
						task.wait(0.4)
						if math.abs(height() - QUAKE_PLAYER_HEIGHT) < 0.02 then
							break -- held through the window: settled
						end
					elseif h > 1 then
						rig:ScaleTo(rig:GetScale() * QUAKE_PLAYER_HEIGHT / h)
						task.wait(0.1)
					else
						task.wait(0.1)
					end
				end
				if humanoid then
					humanoid.AutomaticScalingEnabled = false
				end
			end
			-- re-seat accessories from their weld math: scaling repositions
			-- body parts kinematically (no physics step runs on this parked
			-- assembly), which strands welded hats/hair where they were
			for _, a in rig:GetChildren() do
				if a:IsA("Accessory") then
					local handle = a:FindFirstChild("Handle")
					local weld = if handle then handle:FindFirstChildOfClass("Weld") else nil
					if handle and handle:IsA("BasePart") and weld and weld.Part0 and weld.Part1 then
						if weld.Part0 == handle then
							handle.CFrame = (weld.Part1 :: BasePart).CFrame * weld.C1 * weld.C0:Inverse()
						elseif weld.Part1 == handle then
							handle.CFrame = (weld.Part0 :: BasePart).CFrame * weld.C0 * weld.C1:Inverse()
						end
					end
				end
			end
			-- Anchor ONLY the root. The limbs must stay UNANCHORED so the
			-- Animator can pose them via their Motor6D joints (an anchored
			-- part is pinned and ignores joint-driven motion — that is why
			-- animations played but nothing moved). The anchored root pins
			-- the whole assembly, so unanchored limbs neither fall nor drift;
			-- clients position the rig by PivotTo-ing the model each frame.
			for _, d in rig:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = d == rootPart
				end
			end
			rig.Name = tostring(player.UserId)
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
