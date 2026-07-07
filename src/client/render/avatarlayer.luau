--!strict
--!optimize 2
-- Roblox avatars mode: the engine-agnostic glue between a client's
-- per-frame player/entity data and avatarrender. Both boots drive this
-- one module (NQ init.client and QW qwclient) through a small Deps
-- adapter, so rig lifecycle, weapon-in-hand, pain/death/team-tint
-- rules, water checks, and the projectile muzzle blend have a single
-- source of truth. Everything here is client-local visuals — engines
-- and the wire protocol are untouched, and the alias renderer remains
-- the fallback (rig loading, roblox_avatars off).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local mathlib = require(engine.common.mathlib)
local qcoords = require(engine.client.qcoords)

local avatarrender = require(script.Parent.avatarrender)
local entrender = require(script.Parent.entrender)
local textures = require(script.Parent.textures)

local avatarlayer = {}

-- player.mdl frame bands (player.qc): pain is 29..40, the six death
-- sequences + corpse poses are exactly 41..102, attacks sit above
local PAIN_FIRST, PAIN_LAST = 29, 40
local DEATH_FIRST, DEATH_LAST = 41, 102

-- held-weapon world models by viewmodel name (id1 has no world model
-- for the axe or starting shotgun beyond g_shot, which doubles up)
local V_TO_WORLD: { [string]: string } = {
	["progs/v_shot.mdl"] = "progs/g_shot.mdl",
	["progs/v_shot2.mdl"] = "progs/g_shot.mdl",
	["progs/v_nail.mdl"] = "progs/g_nail.mdl",
	["progs/v_nail2.mdl"] = "progs/g_nail2.mdl",
	["progs/v_rock.mdl"] = "progs/g_rock.mdl",
	["progs/v_rock2.mdl"] = "progs/g_rock2.mdl",
	["progs/v_light.mdl"] = "progs/g_light.mdl",
}
-- grip: quake models point +X forward; hand forward is -Z. The g_*
-- pickup meshes are PICKUP-sized (~55qu long, as long as the player is
-- tall), so the held copy is capped to a carriable length and gripped
-- with its rear tucked just behind the palm (per-gun, from the scaled
-- mesh length). RQDBG_GripPos (Vector3) / RQDBG_GripYPR (Vector3,
-- degrees yaw/pitch/roll) workspace attributes override for live tuning.
local MAX_HELD_GUN_LEN = 2.8 -- studs
local GRIP_FROM_REAR = 0.35 -- palm holds this far ahead of the gun's rear
local WEAPON_GRIP_YPR = Vector3.new(90, 0, 0)
local function currentGrip(part: BasePart): CFrame
	local p = workspace:GetAttribute("RQDBG_GripPos")
	local y = workspace:GetAttribute("RQDBG_GripYPR")
	local pos = if typeof(p) == "Vector3"
		then p
		else Vector3.new(0, -0.1, -(part.Size.X / 2 - GRIP_FROM_REAR))
	local ypr = if typeof(y) == "Vector3" then y else WEAPON_GRIP_YPR
	return CFrame.new(pos) * CFrame.Angles(math.rad(ypr.Y), math.rad(ypr.X), math.rad(ypr.Z))
end

-- Muzzle-origin blend for projectiles (render-only; the SIMULATION is
-- untouched — W_FireRocket really does spawn at the player's center+16,
-- which looks right in first person but reads as chest-launched from a
-- third-person avatar). A projectile born near an avatar-rendered
-- player renders from that avatar's gun muzzle and converges onto its
-- true position over MUZZLE_BLEND seconds.
local MUZZLE_BLEND = 0.15
local PROJECTILE_MODELS: { [string]: boolean } = {
	["progs/missile.mdl"] = true,
	["progs/grenade.mdl"] = true,
	["progs/spike.mdl"] = true,
	["progs/s_spike.mdl"] = true,
}

export type Deps = {
	rigFolder: Instance, -- cloned rigs parent
	entFolder: Instance, -- weapon render parts parent
	getModelDef: (modelindex: number) -> entrender.ModelDef?,
	modelIndexByName: (name: string) -> number?,
	entityLight: (origin: vector) -> number, -- lightmap sample + dlights
	worldHull: () -> any?, -- bsp hull 0 for water checks; nil before load
	time: () -> number,
	palette: textures.Palette,
	-- optional: the local player's tweaks/pause-menu weapon skin, forged
	-- from the held world model's own skin sheet (nil = authentic). Called
	-- per frame, so the boot caches forges (and failures) by (model, spec).
	localWeaponSkin: ((vmName: string, worldModel: string, def: entrender.ModelDef) -> EditableImage?)?,
}

type AvatarWeapon = {
	re: entrender.RenderEnt?,
	model: string?,
	def: entrender.ModelDef?, -- kept for forging procedural skins
	appliedSkin: EditableImage?, -- last texture set on the part
	light: PointLight?,
	emitter: ParticleEmitter?,
	flashUntil: number?,
	wasFlashing: boolean?,
}

export type Layer = {
	playerForSlot: (slot: number) -> Player?,
	ensure: (slot: number, player: Player) -> avatarrender.AvatarEnt,
	updatePlayer: (
		slot: number,
		player: Player,
		origin: vector,
		angles: vector,
		frame: number,
		effects: number,
		colors: number?,
		forceDead: boolean?,
		forceSwim: boolean?,
		velocity: vector?
	) -> boolean,
	updateWeapon: (slot: number, player: Player, ae: avatarrender.AvatarEnt, effects: number) -> (),
	hideWeapon: (slot: number) -> (),
	hide: (slot: number) -> (),
	hideExcept: (seen: { [number]: boolean }) -> (),
	hideAll: () -> (),
	destroyWeapons: () -> (),
	destroySlot: (slot: number) -> (),
	isDeathFrame: (frame: number) -> boolean,
	setFade: (slot: number, alpha: number) -> (),
	pantsColor: (colors: number) -> Color3,
	shirtColor: (colors: number) -> Color3,
	tagMuzzle: (re: entrender.RenderEnt, modelName: string?, origin: vector) -> (),
	blendOrigin: (re: entrender.RenderEnt, origin: vector) -> vector,
	pointInWater: (p: vector) -> boolean,
}

function avatarlayer.new(deps: Deps): Layer
	local ents: { [number]: avatarrender.AvatarEnt } = {}
	local weapons: { [number]: AvatarWeapon } = {}
	local prevFrame: { [number]: number } = {} -- pain-band edge detection
	local pantsCache: { [number]: Color3 } = {}
	local shirtCache: { [number]: Color3 } = {}

	local layer = {} :: Layer

	-- slot -> Player map maintained event-driven (PlayerAdded/Removing +
	-- RQSlot attribute changes) so the per-avatar-per-frame lookup doesn't
	-- scan GetPlayers()×GetAttribute (O(players²) reflected calls at 60Hz)
	local playerBySlot: { [number]: Player } = {}
	local weaponAttr: { [Player]: string } = {} -- RQWeaponModel cache, same discipline
	local slotConns: { [Player]: { RBXScriptConnection } } = {}
	local function reindexPlayer(p: Player)
		for slot, q in playerBySlot do
			if q == p then
				playerBySlot[slot] = nil
			end
		end
		local slot = p:GetAttribute("RQSlot")
		if typeof(slot) == "number" then
			playerBySlot[slot] = p
		end
	end
	local function refreshWeaponAttr(p: Player)
		local v = p:GetAttribute("RQWeaponModel")
		weaponAttr[p] = if typeof(v) == "string" then v else nil
	end
	local function watchPlayer(p: Player)
		slotConns[p] = {
			p:GetAttributeChangedSignal("RQSlot"):Connect(function()
				reindexPlayer(p)
			end),
			p:GetAttributeChangedSignal("RQWeaponModel"):Connect(function()
				refreshWeaponAttr(p)
			end),
		}
		reindexPlayer(p)
		refreshWeaponAttr(p)
	end
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(p)
		for _, conn in slotConns[p] or {} do
			conn:Disconnect()
		end
		slotConns[p] = nil
		weaponAttr[p] = nil
		for slot, q in playerBySlot do
			if q == p then
				playerBySlot[slot] = nil
			end
		end
	end)

	function layer.playerForSlot(slot: number): Player?
		return playerBySlot[slot]
	end

	function layer.isDeathFrame(frame: number): boolean
		return frame >= DEATH_FIRST and frame <= DEATH_LAST
	end

	-- mild mode corpse fade (call right after updatePlayer; 0 restores)
	function layer.setFade(slot: number, alpha: number)
		local ae = ents[slot]
		if ae then
			avatarrender.setFade(ae, alpha)
		end
	end

	-- representative palette color for a translation row start
	-- (CL_NewTranslation ranges: forward rows ascend, rows >= 128 reversed)
	local function rowColor(row: number): Color3
		local pal = deps.palette
		local idx = row + (if row < 128 then 11 else 4)
		return Color3.fromRGB(pal.r[idx + 1], pal.g[idx + 1], pal.b[idx + 1])
	end

	function layer.pantsColor(colors: number): Color3
		local cached = pantsCache[colors]
		if cached then
			return cached
		end
		local c3 = rowColor(bit32.lshift(bit32.band(colors, 15), 4))
		pantsCache[colors] = c3
		return c3
	end

	function layer.shirtColor(colors: number): Color3
		local cached = shirtCache[colors]
		if cached then
			return cached
		end
		local c3 = rowColor(bit32.band(colors, 0xf0))
		shirtCache[colors] = c3
		return c3
	end

	-- SV_HullPointContents against world hull 0, client-side (render-only:
	-- picks swim animations; the simulation's own water checks stay
	-- server-side). Water includes slime/lava/currents, not sky.
	function layer.pointInWater(p: vector): boolean
		local hull = deps.worldHull()
		if not hull then
			return false
		end
		local cn, planes = hull.clipnodes, hull.planes
		local n = 0
		while n >= 0 do
			local plane = planes[cn.planenum[n + 1] + 1]
			local d = if plane.type < 3
				then mathlib.comp(p, plane.type) - plane.dist
				else vector.dot(plane.normal, p) - plane.dist
			n = if d < 0 then cn.child1[n + 1] else cn.child0[n + 1]
		end
		return n <= -3 and n ~= -6 -- CONTENTS_WATER.. but not CONTENTS_SKY
	end

	local function setWeaponVisible(re: entrender.RenderEnt, visible: boolean)
		local root: Instance? = re.part or re.billboardPart or re.model
		if root then
			(root :: any).Parent = if visible then deps.entFolder else nil
		end
	end

	function layer.hideWeapon(slot: number)
		local aw = weapons[slot]
		if aw and aw.re then
			setWeaponVisible(aw.re :: entrender.RenderEnt, false)
		end
	end

	function layer.hide(slot: number)
		local ae = ents[slot]
		if ae then
			avatarrender.setVisible(ae, false)
		end
		prevFrame[slot] = nil
		layer.hideWeapon(slot)
	end

	function layer.hideExcept(seen: { [number]: boolean })
		for slot in ents do
			if not seen[slot] then
				layer.hide(slot)
			end
		end
	end

	function layer.hideAll()
		layer.hideExcept({})
	end

	-- level teardown: weapon render ents die with the level's model defs;
	-- rigs persist across levels
	function layer.destroyWeapons()
		for _, aw in weapons do
			if aw.re then
				entrender.destroy(aw.re :: entrender.RenderEnt)
			end
		end
		table.clear(weapons)
	end

	function layer.destroySlot(slot: number)
		local ae = ents[slot]
		if ae then
			avatarrender.destroy(ae)
			ents[slot] = nil
		end
		local aw = weapons[slot]
		if aw and aw.re then
			entrender.destroy(aw.re :: entrender.RenderEnt)
		end
		weapons[slot] = nil
		prevFrame[slot] = nil
	end

	function layer.ensure(slot: number, player: Player): avatarrender.AvatarEnt
		local ae = ents[slot]
		if not ae or ae.userId ~= player.UserId then
			if ae then
				avatarrender.destroy(ae)
			end
			ae = avatarrender.create(player.UserId, deps.rigFolder)
			ents[slot] = ae
		end
		return ae :: avatarrender.AvatarEnt
	end

	function layer.updateWeapon(slot: number, player: Player, ae: avatarrender.AvatarEnt, effects: number)
		local aw = weapons[slot]
		if not aw then
			aw = {}
			weapons[slot] = aw
		end
		local vmName = weaponAttr[player]
		local want = if vmName then V_TO_WORLD[vmName] else nil
		if aw.model ~= want then
			if aw.re then
				entrender.destroy(aw.re :: entrender.RenderEnt)
				aw.re = nil
				aw.light = nil -- died with the part
				aw.emitter = nil
			end
			aw.model = want
			aw.def = nil
			aw.appliedSkin = nil
			if want then
				local mi = deps.modelIndexByName(want)
				local def = if mi then deps.getModelDef(mi) else nil
				if def and def.kind == "alias" then
					aw.re = entrender.create(def, deps.entFolder)
					aw.def = def
					-- pickup meshes are player-sized: shrink the held copy
					local newPart = if aw.re then aw.re.part else nil
					if newPart then
						local scale = math.min(1, MAX_HELD_GUN_LEN / math.max(newPart.Size.X, 0.001))
						if scale < 1 then
							newPart.Size = newPart.Size * scale
						end
					end
				end
			end
		end
		local re = aw.re
		local hand = avatarrender.rightHandCFrame(ae)
		if re and re.part and hand then
			-- mesh CENTER at the hand (no centerOffset: that re-centers to the
			-- pickup's floor-level model origin and floats the gun overhead)
			local part = re.part :: MeshPart
			setWeaponVisible(re :: entrender.RenderEnt, true)
			-- the local player's menu-picked skin carries onto their held
			-- gun (chase cam / other viewers of this client only — skins
			-- are client-side). The texture is set directly: hand-posed
			-- weapons never pass through updateAlias, where setSkinOverride
			-- applies.
			local def = aw.def
			if player == Players.LocalPlayer and deps.localWeaponSkin and vmName and want and def then
				local img = deps.localWeaponSkin(vmName, want, def)
				local skinImages = def.skinImages
				local desired = img or (if skinImages then skinImages[1] else nil) -- nil forge = authentic
				if desired and aw.appliedSkin ~= desired then
					aw.appliedSkin = desired
					part.TextureContent = Content.fromObject(desired)
				end
			end
			-- muzzle flash: the world dlight comes from the caller's entity
			-- effects; the PointLight lights the RIG (rigs use Roblox
			-- lighting, not the Quake lightmap), the emitter burst + recoil
			-- make the shot readable at a glance
			if bit32.band(effects, 2) ~= 0 then -- EF_MUZZLEFLASH
				aw.flashUntil = deps.time() + 0.15
			end
			local flashing = (aw.flashUntil or 0) > deps.time()
			local grip = currentGrip(part)
			if flashing then
				grip = grip * CFrame.new(-0.15, 0, 0) -- recoil along the barrel
			end
			part.CFrame = hand * grip
			-- match the rig's lightmap shading (flash overrides to bright)
			entrender.setLight(
				re :: entrender.RenderEnt,
				if flashing then 255 else deps.entityLight(qcoords.fromRoblox(hand.Position))
			)
			local light = aw.light
			if not light or light.Parent ~= part then
				light = Instance.new("PointLight")
				light.Enabled = false
				light.Brightness = 6
				light.Range = 14
				light.Color = Color3.fromRGB(255, 190, 90)
				light.Parent = part
				aw.light = light
				local muzzle = Instance.new("Attachment")
				muzzle.Name = "Muzzle"
				muzzle.Position = Vector3.new(part.Size.X / 2 + 0.1, 0, 0)
				muzzle.Parent = part
				local emitter = Instance.new("ParticleEmitter")
				emitter.Rate = 0 -- burst-only via Emit()
				emitter.Lifetime = NumberRange.new(0.06, 0.14)
				emitter.Speed = NumberRange.new(4, 9)
				emitter.SpreadAngle = Vector2.new(20, 20)
				emitter.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 120, 30))
				emitter.LightEmission = 1
				emitter.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.55),
					NumberSequenceKeypoint.new(1, 0.05),
				})
				emitter.EmissionDirection = Enum.NormalId.Right -- +X = barrel
				emitter.Parent = muzzle
				aw.emitter = emitter
			end
			if flashing and not aw.wasFlashing and aw.emitter then
				(aw.emitter :: ParticleEmitter):Emit(6)
			end
			aw.wasFlashing = flashing
			if light.Enabled ~= flashing then
				light.Enabled = flashing
			end
		elseif re then
			setWeaponVisible(re :: entrender.RenderEnt, false)
		end
	end

	-- drive one player entity's rig for this frame. Returns true when the
	-- avatar rendered (caller hides its alias ent); false = rig not ready,
	-- fall back to the alias renderer.
	function layer.updatePlayer(
		slot: number,
		player: Player,
		origin: vector,
		angles: vector,
		frame: number,
		effects: number,
		colors: number?,
		forceDead: boolean?,
		forceSwim: boolean?,
		velocity: vector?
	): boolean
		local ae = layer.ensure(slot, player)
		if not avatarrender.ready(ae) then
			return false
		end
		avatarrender.setVisible(ae, true)
		local dead = forceDead == true or layer.isDeathFrame(frame)
		-- pain flinch on entering the pain band (or restarting it)
		local pf = prevFrame[slot]
		if not dead and frame >= PAIN_FIRST and frame <= PAIN_LAST then
			if pf == nil or pf < PAIN_FIRST or pf > PAIN_LAST or frame < pf then
				avatarrender.flashPain(ae, deps.time())
			end
		end
		prevFrame[slot] = frame
		-- quake shirt/pants: re-skin the rig's body regions in the
		-- translation colors (the identity/teamplay signal); default
		-- colors (0) keep the avatar's real look
		if colors and colors ~= 0 then
			avatarrender.setTeamColors(ae, layer.shirtColor(colors), layer.pantsColor(colors))
		else
			avatarrender.setTeamColors(ae, nil, nil)
		end
		avatarrender.setLight(ae, deps.entityLight(origin))
		local swim = forceSwim == true or layer.pointInWater(origin)
		avatarrender.update(ae, origin, angles, deps.time(), dead, swim, velocity)
		if dead then
			layer.hideWeapon(slot) -- corpses don't hold the gun
		else
			layer.updateWeapon(slot, player, ae, effects)
		end
		return true
	end

	function layer.tagMuzzle(re: entrender.RenderEnt, modelName: string?, origin: vector)
		if not modelName or not PROJECTILE_MODELS[modelName] then
			return
		end
		local bestPart: MeshPart? = nil
		local bestDist = 60 -- quake units: projectiles spawn ~8-16 from the owner
		for slot, ae in ents do
			local aw = weapons[slot]
			local porigin = ae.lastOrigin
			if ae.visible and porigin and aw and aw.re and aw.re.part then
				local d = vector.magnitude(origin - porigin)
				if d < bestDist then
					bestDist = d
					bestPart = aw.re.part :: MeshPart
				end
			end
		end
		if bestPart then
			local tip = bestPart.CFrame * Vector3.new(bestPart.Size.X / 2 + 0.1, 0, 0)
			local r = re :: any
			r.muzzleFrom = qcoords.fromRoblox(tip)
			r.muzzleT0 = deps.time()
			workspace:SetAttribute("RQDBG_MuzzleBlends", (workspace:GetAttribute("RQDBG_MuzzleBlends") :: number? or 0) + 1)
		end
	end

	function layer.blendOrigin(re: entrender.RenderEnt, origin: vector): vector
		local r = re :: any
		local from = r.muzzleFrom
		if not from then
			return origin
		end
		local k = 1 - (deps.time() - (r.muzzleT0 or 0)) / MUZZLE_BLEND
		if k <= 0 then
			r.muzzleFrom = nil
			return origin
		end
		return origin + (from - origin) * k
	end

	return layer
end

return avatarlayer
