--!strict
-- QuakeWorld client boot: selected when QuakeClientFS has attribute
-- engine="qw". Drives the qwcl core (connection, delta frames,
-- prediction) and renders through the shared render/* modules. Covers
-- world + entities + players + sounds + input/camera, the console +
-- messagemode chat (console.c/keys.c) and the spectator autocam
-- (cl_cam.c).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local mathlib = require(engine.common.mathlib)
local msg = require(engine.common.msg)
local vfslib = require(engine.common.vfs)
local qcoords = require(engine.client.qcoords)
local qwcl = require(engine.qw.qwcl)
local qwp = require(engine.qw.qwprotocol)

local bsplib = require(engine.bsp.bsp)
local mdllib = require(engine.models.mdl)

local confontlib = require(script.Parent.render.confont)
local entrender = require(script.Parent.render.entrender)
local lightatlaslib = require(script.Parent.render.lightatlas)
local lightpoint = require(script.Parent.render.lightpoint)
local particleslib = require(script.Parent.render.particles)
local textures = require(script.Parent.render.textures)
local worldmesh = require(script.Parent.render.worldmesh)
local consolelib = require(script.Parent.console)
local hudlib = require(script.Parent.hud)
local input = require(script.Parent.input)
local soundlib = require(script.Parent.sound)
local viewmodellib = require(script.Parent.render.viewmodel)

return function()
	----------------------------------------------------------------------
	-- filesystem from the server-published bundle
	local clientAssets = ReplicatedStorage:WaitForChild("QuakeClientFS")
	while clientAssets:GetAttribute("ready") ~= true do
		clientAssets.AttributeChanged:Wait()
	end
	local fs = vfslib.new()
	vfslib.addFolderSource(fs, clientAssets)

	local palbuf = vfslib.loadFile(fs, "gfx/palette.lmp")
	assert(palbuf, "gfx/palette.lmp missing")
	local pal = textures.parsePalette(palbuf)

	local player = Players.LocalPlayer
	local cl = qwcl.new(fs)
	cl.dprint = function(s: string)
		print("[qwcl] " .. s)
	end

	----------------------------------------------------------------------
	-- transport
	local net = ReplicatedStorage:WaitForChild("QuakeNet")
	local reliable = net:WaitForChild("Reliable") :: RemoteEvent
	local unreliable = net:WaitForChild("Unreliable") :: UnreliableRemoteEvent

	local inbound: { buffer } = {}
	local function onPacket(data: unknown)
		if typeof(data) == "buffer" then
			table.insert(inbound, data :: buffer)
		end
	end
	reliable.OnClientEvent:Connect(onPacket)
	unreliable.OnClientEvent:Connect(onPacket)

	----------------------------------------------------------------------
	-- rendering state
	local worldFolder = Instance.new("Folder")
	worldFolder.Name = "QuakeWorld"
	worldFolder.Parent = Workspace
	local entFolder = Instance.new("Folder")
	entFolder.Name = "QuakeEnts"
	entFolder.Parent = Workspace

	local sndsys = soundlib.new(Workspace)
	local psys = particleslib.new(pal, Workspace)

	-- Sbar: the QW status bar reuses the NQ sbar.c port (hudlib) — the
	-- main bar is identical in both sbar.c files; hudlib reads an NQ
	-- cllib.Client shape, so a thin adapter view of qwcl state feeds it.
	-- (QW's ping-column deathmatch overlay is a journaled refinement.)
	local hud = hudlib.create(fs, pal, player:WaitForChild("PlayerGui"))
	local vmgun = viewmodellib.new(player:WaitForChild("PlayerGui"))
	hudlib.setLoading(hud, true)
	local hudC: any = {
		stats = cl.stats,
		items = 0,
		item_gettime = {},
		faceanimtime = 0,
		time = 0,
		intermission = 0,
		completed_time = 0,
		gametype = 1, -- QW is deathmatch-only
		scores = {},
		viewentity = 1,
		levelname = "",
		paused = false,
	}
	local lastDamageCount = 0

	-- view blends (view.c): CSHIFT_CONTENTS/DAMAGE/BONUS/POWERUP
	local cshifts = {
		{ r = 130, g = 80, b = 50, percent = 0 }, -- contents
		{ r = 255, g = 0, b = 0, percent = 0 }, -- damage
		{ r = 215, g = 186, b = 69, percent = 0 }, -- bonus
		{ r = 0, g = 0, b = 255, percent = 0 }, -- powerup
	}
	local v_dmg_time, v_dmg_roll, v_dmg_pitch = 0, 0, 0
	local V_KICKTIME, V_KICKROLL, V_KICKPITCH = 0.5, 0.6, 0.6
	local v_oldz = 0 -- V_CalcRefdef stair-step smoothing state

	local cshiftGui = Instance.new("ScreenGui")
	cshiftGui.Name = "QuakeCshift"
	cshiftGui.IgnoreGuiInset = true
	cshiftGui.DisplayOrder = 5
	local cshiftFrame = Instance.new("Frame")
	cshiftFrame.BorderSizePixel = 0
	cshiftFrame.Size = UDim2.fromScale(1, 1)
	cshiftFrame.BackgroundTransparency = 1
	cshiftFrame.Parent = cshiftGui
	cshiftGui.Parent = player:WaitForChild("PlayerGui")

	-- console + chat line live on their own gui above the hud (console.c;
	-- the same consolelib the NQ boot uses, wired below to the QW command
	-- handling: unknown commands forward to the server per Cmd_ForwardToServer)
	local overlayGui = Instance.new("ScreenGui")
	overlayGui.Name = "QuakeOverlay"
	overlayGui.IgnoreGuiInset = true
	overlayGui.DisplayOrder = 20
	overlayGui.ResetOnSpawn = false
	overlayGui.Parent = player:WaitForChild("PlayerGui")
	local con = consolelib.create(fs, pal, overlayGui)

	-- Con_DrawNotify's "say:" input line while messagemode is up
	local chatHolder = Instance.new("Frame")
	chatHolder.Name = "chatline"
	chatHolder.BackgroundTransparency = 1
	chatHolder.Position = UDim2.fromOffset(8, 8)
	chatHolder.Size = UDim2.fromOffset(64 * 8 * 2, 8 * 2)
	chatHolder.Visible = false
	chatHolder.Parent = overlayGui
	local chatRow = confontlib.newRow(chatHolder, 64, 2)
	local chatOpen = false -- key_dest == key_message
	local chatTeam = false -- chat_team
	local chatBuffer = "" -- chat_buffer

	-- CL_AllocExplosion ring: s_explod.spr animated at 10 Hz
	local explosions: { { origin: vector, start: number } } = {}
	local explosionIndex: number? = nil

	local function updateHudAdapter()
		hudC.time = cl.time
		hudC.intermission = cl.intermission
		hudC.completed_time = cl.completed_time or cl.time
		hudC.viewentity = cl.playernum + 1
		hudC.levelname = cl.levelname
		hudC.paused = cl.paused

		-- CL_SetStat: item pickup flash timestamps on rising bits
		local newItems = cl.stats[qwp.STAT_ITEMS] or 0
		if newItems ~= hudC.items then
			for bitn = 0, 31 do
				local mask = if bitn < 31 then bit32.lshift(1, bitn) else 0x80000000
				if bit32.band(newItems, mask) ~= 0 and bit32.band(hudC.items, mask) == 0 then
					hudC.item_gettime[bitn] = cl.time
				end
			end
			hudC.items = newItems
		end

		-- V_ParseDamage: pain face, damage cshift, view-angle kick
		if (cl.damageCount or 0) ~= lastDamageCount then
			lastDamageCount = cl.damageCount or 0
			hudC.faceanimtime = cl.time + 0.2
			local dmg = cl.damage
			if dmg then
				local count = dmg.take * 0.5 + dmg.save * 0.5
				if count < 10 then
					count = 10
				end
				cshifts[2].percent = math.clamp(cshifts[2].percent + 3 * count, 0, 150)
				if dmg.save > dmg.take then
					cshifts[2].r, cshifts[2].g, cshifts[2].b = 200, 100, 100
				elseif dmg.save > 0 then
					cshifts[2].r, cshifts[2].g, cshifts[2].b = 220, 50, 50
				else
					cshifts[2].r, cshifts[2].g, cshifts[2].b = 255, 0, 0
				end
				local from = dmg.from - cl.simorg
				local flen = vector.magnitude(from)
				if flen > 0 then
					from = from / flen
				end
				local fwd, right, _up = mathlib.angleVectors(cl.simangles)
				v_dmg_roll = count * vector.dot(from, right) * V_KICKROLL
				v_dmg_pitch = count * vector.dot(from, fwd) * V_KICKPITCH
				v_dmg_time = V_KICKTIME
			end
		end

		-- V_BonusFlash_f: the server stuffs "bf" on item pickup
		local raw = cl.rawStufftext
		if raw and raw ~= "" then
			cl.rawStufftext = ""
			for line in raw:gmatch("[^\n]+") do
				if line == "bf" then
					cshifts[3].r, cshifts[3].g, cshifts[3].b = 215, 186, 69
					cshifts[3].percent = 50
				end
			end
		end

		-- Sbar_SortFrags source: scoreboard slots from player infos
		for i = 0, qwp.MAX_CLIENTS - 1 do
			local info = cl.players[i]
			local slot = hudC.scores[i + 1]
			if not slot then
				slot = { name = "", frags = 0, colors = 0 }
				hudC.scores[i + 1] = slot
			end
			if info then
				slot.name = info.name
				slot.frags = info.frags
				slot.ping = info.ping
				slot.pl = info.pl
				slot.entertime = info.entertime
				slot.spectator = info.spectator
				local top = tonumber(info.userinfo.topcolor) or 0
				local bottom = tonumber(info.userinfo.bottomcolor) or 0
				slot.colors = top * 16 + bottom
			else
				slot.name = ""
			end
		end
	end

	-- CL_AllocDlight pool
	local dlights: { lightatlaslib.Dlight } = {}
	local MAX_DLIGHTS = 32
	local function allocDlight(key: number, time: number): lightatlaslib.Dlight
		if key ~= 0 then
			for _, dl in dlights do
				if dl.key == key then
					dl.radius = 0
					dl.decay = 0
					dl.minlight = 0
					return dl
				end
			end
		end
		for _, dl in dlights do
			if dl.die < time then
				dl.key = key
				dl.radius = 0
				dl.decay = 0
				dl.minlight = 0
				return dl
			end
		end
		local dl: lightatlaslib.Dlight = { key = key, origin = vector.zero, radius = 0, die = 0, decay = 0, minlight = 0 }
		if #dlights < MAX_DLIGHTS then
			table.insert(dlights, dl)
		else
			dlights[1] = dl
		end
		return dl
	end

	-- CL_ParseBeam state (bolt models, 0.2s lifetime, 30-unit segments)
	local MAX_BEAMS = 8
	local beams: { any } = {}
	local beamDefs: { [string]: any } = {}
	local beamPool: { [string]: { entrender.RenderEnt } } = {}
	local updateBeams: () -> ()
	local handleTempEntity: (te: any) -> ()

	local styleValues: { [number]: number } = {}
	local function styleValueFor(style: number): number
		return styleValues[style] or worldmesh.BASE_STYLE_VALUE
	end

	local lightAnim: { worldmesh.AnimEntry } = {}
	local textureAnims: { worldmesh.TextureAnim } = {}
	local lastStyleFrame = -1
	local modelDefs: { [number]: entrender.ModelDef } = {}
	local brushTemplates: { [string]: Model } = {}
	local worldBuilt = false
	local seenLevelResets = 0
	local staticsSpawned = 0
	local staticSoundsSpawned = 0
	local staticRes: { entrender.RenderEnt } = {} -- destroyed on level change

	-- model defs come straight from qwcl's loaded models (modellist)
	local function getModelDef(modelindex: number): entrender.ModelDef?
		local def = modelDefs[modelindex]
		if def then
			return def
		end
		-- wire model indices are 1-based precache slots, like C
		local m = cl.models[modelindex]
		local name = cl.model_name[modelindex]
		if not m or not name then
			return nil
		end
		if m.kind == "alias" then
			def = { kind = "alias" :: "alias", alias = m.alias, flags = m.alias.flags }
			entrender.prepareImages(def, pal)
		elseif m.kind == "sprite" then
			def = { kind = "sprite" :: "sprite", sprite = m.sprite, flags = 0 }
			entrender.prepareImages(def, pal)
		elseif m.kind == "brush" and modelindex ~= 1 then
			-- submodels ("*n") AND standalone brush models (ammo/health
			-- boxes, b_*.bsp) — everything but the world itself
			local template = brushTemplates[name]
			if not template then
				local anim
				template, anim = worldmesh.build(m.brush, pal, nil :: any, name)
				for _, e in anim do
					table.insert(lightAnim, e)
				end
				for _, ta in worldmesh.takeTextureAnims() do
					table.insert(textureAnims, ta)
				end
				brushTemplates[name] = template
			end
			def = { kind = "brush" :: "brush", flags = 0, brushModel = template }
		else
			def = { kind = "none" :: "none", flags = 0 }
		end
		modelDefs[modelindex] = def
		return def
	end

	local function buildWorld()
		if worldBuilt or not cl.worldmodel then
			return
		end
		worldBuilt = true
		worldmesh.resetLighting(styleValueFor)
		local _world, anim = worldmesh.build(cl.models[1].brush, pal, worldFolder, "world")
		for _, e in anim do
			table.insert(lightAnim, e)
		end
		-- sky scroll / water warp / +wall frame writers (the NQ boot's
		-- 10Hz pump; without it the raw sky texture shows its masked
		-- front half as black holes)
		for _, ta in worldmesh.takeTextureAnims() do
			table.insert(textureAnims, ta)
		end
		print(`[robloquake] qw world built: {cl.levelname}`)
	end

	-- statics arrive in the prespawn signon, after the world builds:
	-- spawn whatever is new each frame
	local function spawnPendingStatics()
		while staticsSpawned < #cl.static_entities do
			staticsSpawned += 1
			local es = cl.static_entities[staticsSpawned]
			local def = getModelDef(es.modelindex)
			if def and def.kind ~= "none" then
				local re = entrender.create(def, entFolder)
				if re then
					table.insert(staticRes, re)
					if def.kind == "alias" then
						entrender.updateAlias(re, def, es.origin, es.angles, es.frame, es.skinnum, 0, 0)
					elseif def.kind == "sprite" then
						entrender.updateSprite(re, def, es.origin, es.frame)
					elseif def.kind == "brush" then
						entrender.updateBrush(re, es.origin, es.angles)
					end
				end
			end
		end
		while staticSoundsSpawned < #cl.static_sounds do
			staticSoundsSpawned += 1
			local ss = cl.static_sounds[staticSoundsSpawned]
			local name = cl.sound_name[ss.num]
			if name then
				-- volume byte passes through raw; soundlib scales by 255
				soundlib.static(sndsys, ss.pos, name, ss.vol, ss.atten)
			end
		end
	end

	----------------------------------------------------------------------
	-- temp entities (cl_tent.c): particles, impact sounds, dlights, beams

	local function teSound(sample: string, pos: vector)
		soundlib.start(sndsys, -1, 0, sample, pos, 1, 1)
	end

	local function spikeSound(pos: vector)
		if math.random(0, 4) ~= 0 then
			teSound("weapons/tink1.wav", pos)
		else
			local rnd = math.random(0, 3)
			if rnd == 1 then
				teSound("weapons/ric1.wav", pos)
			elseif rnd == 2 then
				teSound("weapons/ric2.wav", pos)
			else
				teSound("weapons/ric3.wav", pos)
			end
		end
	end

	local function beamModelDef(name: string): any
		local def = beamDefs[name]
		if def == nil then
			local buf = vfslib.loadFile(fs, name, true)
			if buf then
				local am = mdllib.load(name, buf)
				def = { kind = "alias", alias = am, flags = am.flags }
				entrender.prepareImages(def, pal)
			else
				def = false
			end
			beamDefs[name] = def
		end
		return if def then def else nil
	end

	local function parseBeam(modelName: string, te: any)
		local entity = te.entity or 0
		local endPos = te.pos2 :: vector
		if entity ~= 0 then
			for i = 1, MAX_BEAMS do
				local b = beams[i]
				if b and b.entity == entity then
					b.modelName = modelName
					b.startPos = te.pos
					b.endPos = endPos
					b.endtime = cl.time + 0.2
					return
				end
			end
		end
		for i = 1, MAX_BEAMS do
			local b = beams[i]
			if not b or b.endtime < cl.time then
				beams[i] = { modelName = modelName, entity = entity, startPos = te.pos, endPos = endPos, endtime = cl.time + 0.2 }
				return
			end
		end
	end

	function updateBeams()
		local used: { [string]: number } = {}
		for i = 1, MAX_BEAMS do
			local b = beams[i]
			if b and b.endtime >= cl.time then
				-- if coming from the player, pin the start to the view
				if b.entity == cl.playernum + 1 then
					b.startPos = cl.simorg
				end
				local def = beamModelDef(b.modelName)
				if def then
					local dist = b.endPos - b.startPos
					local yaw, pitch
					if dist.x == 0 and dist.y == 0 then
						yaw = 0
						pitch = if dist.z > 0 then 90 else 270
					else
						yaw = math.deg(math.atan2(dist.y, dist.x))
						if yaw < 0 then
							yaw += 360
						end
						pitch = math.deg(math.atan2(dist.z, math.sqrt(dist.x * dist.x + dist.y * dist.y)))
						if pitch < 0 then
							pitch += 360
						end
					end
					local d = vector.magnitude(dist)
					local dir = if d > 0 then dist / d else vector.zero
					local org = b.startPos
					while d > 0 do
						local n = (used[b.modelName] or 0) + 1
						used[b.modelName] = n
						local pool = beamPool[b.modelName]
						if not pool then
							pool = {}
							beamPool[b.modelName] = pool
						end
						local re = pool[n]
						if not re then
							re = entrender.create(def, entFolder)
							if not re then
								break
							end
							pool[n] = re
						end
						entrender.updateAlias(re, def, org, vector.create(pitch, yaw, math.random(0, 359)), 0, 0, 0, cl.time)
						entrender.setLight(re, 255)
						org += dir * 30
						d -= 30
					end
				end
			end
		end
		-- hide unused pooled segments
		for name, pool in beamPool do
			for i = (used[name] or 0) + 1, #pool do
				local re = pool[i]
				local root: Instance? = (re :: any).part or (re :: any).billboardPart or (re :: any).model
				if root and (root :: any).Parent ~= nil then
					entrender.updateAlias(re, beamModelDef(name), vector.create(0, 0, -10000), vector.zero, 0, 0, 0, cl.time)
				end
			end
		end
	end

	function handleTempEntity(te: any)
		local t = te.type
		if t == -1 then
			-- svc_muzzleflash: dlight 18 units forward of the shooter
			local entnum = te.entity or 0
			local org, ang
			if entnum == cl.playernum + 1 then
				org, ang = cl.simorg, cl.viewangles
			else
				local ps = cl.frames[bit32.band(cl.parsecount, qwp.UPDATE_MASK)].playerstate[entnum - 1]
				if not ps or ps.messagenum ~= cl.parsecount then
					return
				end
				org, ang = ps.origin, ps.viewangles
			end
			local fwd = mathlib.angleVectors(ang)
			local dl = allocDlight(-entnum, cl.time)
			dl.origin = org + fwd * 18
			dl.radius = 200 + math.random(0, 31)
			dl.die = cl.time + 0.1
			dl.minlight = 32
		elseif t == qwp.TE_SPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 10, cl.time, true)
			spikeSound(te.pos)
		elseif t == qwp.TE_SUPERSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 20, cl.time, true)
			spikeSound(te.pos)
		elseif t == qwp.TE_GUNSHOT then
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 20 * (te.count or 1), cl.time, true)
		elseif t == qwp.TE_BLOOD then
			particleslib.runEffect(psys, te.pos, vector.zero, 73, 20 * (te.count or 1), cl.time, true)
		elseif t == qwp.TE_LIGHTNINGBLOOD then
			particleslib.runEffect(psys, te.pos, vector.zero, 225, 50, cl.time, true)
		elseif t == qwp.TE_EXPLOSION or t == qwp.TE_TAREXPLOSION then
			particleslib.explosion(psys, te.pos, cl.time)
			if t == qwp.TE_EXPLOSION then
				-- CL_AllocExplosion: reuse a free slot, else the oldest
				local slot = nil
				for i = 1, 8 do
					if not explosions[i] then
						slot = i
						break
					end
				end
				if not slot then
					local oldest = math.huge
					for i = 1, 8 do
						if explosions[i].start < oldest then
							oldest = explosions[i].start
							slot = i
						end
					end
				end
				explosions[slot :: number] = { origin = te.pos, start = cl.time }
			end
			if t == qwp.TE_EXPLOSION then
				local dl = allocDlight(0, cl.time)
				dl.origin = te.pos
				dl.radius = 350
				dl.die = cl.time + 0.5
				dl.decay = 300
			end
			teSound("weapons/r_exp3.wav", te.pos)
		elseif t == qwp.TE_WIZSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 20, 30, cl.time, true)
			teSound("wizard/hit.wav", te.pos)
		elseif t == qwp.TE_KNIGHTSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 226, 20, cl.time, true)
			teSound("hknight/hit.wav", te.pos)
		elseif t == qwp.TE_LAVASPLASH then
			particleslib.lavaSplash(psys, te.pos, cl.time)
		elseif t == qwp.TE_TELEPORT then
			particleslib.teleportSplash(psys, te.pos, cl.time)
		elseif t == qwp.TE_LIGHTNING1 then
			parseBeam("progs/bolt.mdl", te)
		elseif t == qwp.TE_LIGHTNING2 then
			parseBeam("progs/bolt2.mdl", te)
		elseif t == qwp.TE_LIGHTNING3 then
			parseBeam("progs/bolt3.mdl", te)
		end
	end

	----------------------------------------------------------------------
	-- spectator autocam (cl_cam.c): always-on cl_hightrack target pick,
	-- Cam_Lock chase view through the tracked player, BUTTON_JUMP cycling
	local BUTTON_JUMP = 2
	local CAM_NONE, CAM_TRACK = 0, 1
	local autocam = CAM_NONE
	local spec_track = 0 -- player# of who we are tracking
	local camLocked = false
	local camOldbuttons = 0

	-- Cam_Unlock
	local function camUnlock()
		if autocam ~= CAM_NONE then
			qwcl.sendStringCmd(cl, "ptrack")
			autocam = CAM_NONE
			camLocked = false
		end
	end

	-- Cam_Lock (the port's view is the cl_chasecam-style lock straight on
	-- the player, so no InitFlyby search: lock immediately)
	local function camLock(playernum: number)
		qwcl.sendStringCmd(cl, `ptrack {playernum}`)
		spec_track = playernum
		autocam = CAM_TRACK
		camLocked = true
	end

	-- Cam_CheckHighTarget: track whoever has the most frags
	local function camCheckHighTarget()
		local j, max = -1, -9999
		for i = 0, qwp.MAX_CLIENTS - 1 do
			local s = cl.players[i]
			if s and s.name ~= "" and not s.spectator and s.frags > max then
				max = s.frags
				j = i
			end
		end
		if j >= 0 then
			local cur = cl.players[spec_track]
			if not camLocked or not cur or cl.players[j].frags > cur.frags then
				camLock(j)
			end
		else
			camUnlock()
		end
	end

	-- the tracked playerstate for this parse frame, or nil (gates both the
	-- camera override and Cam_DrawPlayer)
	local function camTrackedState(): qwcl.PlayerState?
		if not (cl.spectator and autocam ~= CAM_NONE and camLocked) then
			return nil
		end
		local ps = cl.frames[bit32.band(cl.parsecount, qwp.UPDATE_MASK)].playerstate[spec_track]
		if ps and ps.messagenum == cl.parsecount then
			return ps
		end
		return nil
	end

	-- Cam_Track + Cam_FinishMove essentials, once per sent cmd. Delta from
	-- C: hightrack retargeting only runs while unlocked so the jump-cycle
	-- choice sticks (pure cl_hightrack would return before the jump check).
	local function camTrack(buttons: number)
		if not cl.spectator or cl.state ~= "active" then
			return
		end
		if not camLocked then
			camCheckHighTarget()
		end
		if autocam == CAM_NONE then
			return
		end
		-- tracked player gone or turned spectator: retarget
		local ts = cl.players[spec_track]
		if camLocked and (not ts or ts.name == "" or ts.spectator) then
			camLocked = false
			camCheckHighTarget()
			return
		end
		-- cl_chasecam path of Cam_Track: clc_tmove keeps the spectator
		-- entity riding the tracked player on the server
		local ps = camTrackedState()
		if ps and vector.magnitude(ps.origin - cl.simorg) > 16 then
			msg.writeByte(cl.netchan.message, qwp.clc_tmove)
			msg.writeCoord(cl.netchan.message, ps.origin.x)
			msg.writeCoord(cl.netchan.message, ps.origin.y)
			msg.writeCoord(cl.netchan.message, ps.origin.z)
		end
		-- BUTTON_JUMP cycles to the next player (Cam_FinishMove)
		if camLocked then
			if bit32.band(buttons, BUTTON_JUMP) ~= 0 and bit32.band(camOldbuttons, BUTTON_JUMP) ~= 0 then
				return -- don't pogo stick
			end
			if bit32.band(buttons, BUTTON_JUMP) == 0 then
				camOldbuttons = bit32.band(camOldbuttons, bit32.bnot(BUTTON_JUMP))
				return
			end
			camOldbuttons = bit32.bor(camOldbuttons, BUTTON_JUMP) -- don't jump again until released
		end
		local endi = if camLocked and autocam ~= CAM_NONE then (spec_track + 1) % qwp.MAX_CLIENTS else spec_track
		local i = endi
		repeat
			local s = cl.players[i]
			if s and s.name ~= "" and not s.spectator then
				camLock(i)
				return
			end
			i = (i + 1) % qwp.MAX_CLIENTS
		until i == endi
		-- stay on same guy?
		local s = cl.players[spec_track]
		if s and s.name ~= "" and not s.spectator then
			camLock(spec_track)
			return
		end
		consolelib.print(con, "No target found ...")
		autocam = CAM_NONE
		camLocked = false
	end

	----------------------------------------------------------------------
	-- entity linking (packet entities + players + nails)
	local renderEnts: { [string]: entrender.RenderEnt } = {}
	local renderDefs: { [string]: entrender.ModelDef } = {}
	local liveKeys: { [string]: boolean } = {}
	local trailOrigins: { [string]: vector } = {}
	local gunEnt: entrender.RenderEnt? = nil
	local gunModelIndex = 0

	local function linkEnt(key: string, modelindex: number, origin: vector, angles: vector, frame: number, skinnum: number, time: number, colors: number?)
		local def = getModelDef(modelindex)
		if not def or def.kind == "none" then
			return
		end
		liveKeys[key] = true
		local re = renderEnts[key]
		if re and renderDefs[key] ~= def then
			entrender.destroy(re)
			re = nil
		end
		if not re then
			re = entrender.create(def, entFolder)
			if not re then
				return
			end
			renderEnts[key] = re
			renderDefs[key] = def
		end
		if def.kind == "alias" then
			if bit32.band(def.flags, mdllib.EF_ROTATE) ~= 0 then
				-- items spin: autorotate = anglemod(100*cl.time)
				angles = vector.create(0, (100 * time) % 360, 0)
			end
			entrender.updateAlias(re, def, origin, angles, frame, skinnum, 0, time, colors)
		elseif def.kind == "sprite" then
			entrender.updateSprite(re, def, origin, frame)
		elseif def.kind == "brush" then
			entrender.updateBrush(re, origin, angles)
		end
	end

	local function relinkEntities(time: number)
		table.clear(liveKeys)
		local frame: qwcl.Frame = cl.frames[bit32.band(cl.netchan.incoming_sequence, qwp.UPDATE_MASK)]

		for _, es in frame.packet_entities do
			linkEnt(`e{es.number}`, es.modelindex, es.origin, es.angles, es.frame, es.skinnum, time)

			-- EF_ effects dlights (quad/pent glow, brightlight/dimlight)
			if bit32.band(es.effects, 12) ~= 0 then -- EF_BRIGHTLIGHT|EF_DIMLIGHT
				local dl = allocDlight(es.number, time)
				local up = if bit32.band(es.effects, 4) ~= 0 then 16 else 0
				dl.origin = es.origin + vector.create(0, 0, up)
				dl.radius = (if bit32.band(es.effects, 4) ~= 0 then 400 else 200) + math.random(0, 31)
				dl.die = time + 0.1
			end

			-- model-flag trails + rocket glow
			local def = getModelDef(es.modelindex)
			local mflags = if def then def.flags else 0
			if mflags ~= 0 then
				local key = `e{es.number}`
				local oldOrg = trailOrigins[key]
				if oldOrg and oldOrg ~= es.origin then
					if bit32.band(mflags, 2) ~= 0 then -- EF_ROCKET
						particleslib.rocketTrail(psys, oldOrg, es.origin, 0, time)
						local dl = allocDlight(es.number, time)
						dl.origin = es.origin
						dl.radius = 200
						dl.die = time + 0.1
					elseif bit32.band(mflags, 4) ~= 0 then -- EF_GRENADE
						particleslib.rocketTrail(psys, oldOrg, es.origin, 1, time)
					elseif bit32.band(mflags, 1) ~= 0 then -- EF_GIB
						particleslib.rocketTrail(psys, oldOrg, es.origin, 2, time)
					elseif bit32.band(mflags, 32) ~= 0 then -- EF_ZOMGIB
						particleslib.rocketTrail(psys, oldOrg, es.origin, 4, time)
					elseif bit32.band(mflags, 16) ~= 0 then -- EF_TRACER
						particleslib.rocketTrail(psys, oldOrg, es.origin, 3, time)
					elseif bit32.band(mflags, 64) ~= 0 then -- EF_TRACER2
						particleslib.rocketTrail(psys, oldOrg, es.origin, 5, time)
					elseif bit32.band(mflags, 128) ~= 0 then -- EF_TRACER3
						particleslib.rocketTrail(psys, oldOrg, es.origin, 6, time)
					end
				end
				trailOrigins[key] = es.origin
			end
		end

		-- players from playerinfo (self is drawn by the camera instead):
		-- extrapolated forward by half the elapsed move (CL_LinkPlayers)
		-- with the V_CalcRoll strafe lean
		local predicted = qwcl.predictedPlayerOrigins(cl)
		for num, ps in frame.playerstate do
			if ps.messagenum ~= cl.parsecount or num == cl.playernum then
				continue
			end
			-- Cam_DrawPlayer: don't draw the target we are chase camming
			if cl.spectator and autocam ~= CAM_NONE and camLocked and num == spec_track then
				continue
			end
			local angles = vector.create(-ps.viewangles.x / 3, ps.viewangles.y, 0)
			local _f, right, _u = mathlib.angleVectors(angles)
			local side = vector.dot(ps.velocity, right)
			local sign = if side < 0 then -1 else 1
			side = math.abs(side)
			local roll = (if side < 200 then side * 2.0 / 200 else 2.0) * sign * 4
			angles = vector.create(angles.x, angles.y, roll)
			local porigin = predicted[num] or ps.origin
			-- CL_NewTranslation: shirt/pants byte for the player skin
			local colors: number? = nil
			local info = cl.players[num]
			if info and ps.modelindex == cl.playerindex then
				local top = tonumber(info.userinfo.topcolor) or 0
				local bottom = tonumber(info.userinfo.bottomcolor) or 0
				colors = top * 16 + bottom
			end
			linkEnt(`p{num}`, ps.modelindex, porigin, angles, ps.frame, ps.skinnum, time, colors)

			-- CL_AddFlagModels: CTF flag riding on the carrier's back
			local efFlag = bit32.band(ps.effects, 16 + 32) -- EF_FLAG1|EF_FLAG2
			if efFlag ~= 0 and cl.flagindex then
				local f = 14
				local pf = ps.frame
				if pf >= 29 and pf <= 34 then
					f += ({ [29] = 2, [30] = 8, [31] = 12, [32] = 11, [33] = 10, [34] = 4 })[pf] or 0
				elseif pf >= 35 and pf <= 40 then
					f += ({ [35] = 2, [36] = 10, [37] = 10, [38] = 8, [39] = 4, [40] = 2 })[pf] or 0
				elseif pf >= 103 and pf <= 106 then
					f += 6
				elseif pf >= 107 and pf <= 118 then
					f += 7
				end
				local ff, fr, _fu = mathlib.angleVectors(angles)
				ff = vector.create(ff.x, ff.y, -ff.z) -- reverse z component
				local forg = porigin - ff * f + fr * 22 + vector.create(0, 0, -16)
				local fang = vector.create(angles.x, angles.y, angles.z - 45)
				linkEnt(`pf{num}`, cl.flagindex, forg, fang, 0, if bit32.band(ps.effects, 32) ~= 0 then 1 else 0, time)
			end
		end

		-- CL_UpdateExplosions: s_explod.spr at 10 Hz until frames run out
		if not explosionIndex then
			for i, name in cl.model_name do
				if name == "progs/s_explod.spr" then
					explosionIndex = i
				end
			end
		end
		if explosionIndex then
			local def = getModelDef(explosionIndex)
			local numframes = if def and def.sprite then #(def.sprite :: any).frames else 6
			for i = 1, 8 do
				local ex = explosions[i]
				if ex then
					local f = math.floor(10 * (time - ex.start))
					if f >= numframes then
						explosions[i] = nil
					else
						linkEnt(`x{i}`, explosionIndex, ex.origin, vector.zero, f, 0, time)
					end
				end
			end
		end

		-- nails ride their own compact message
		if cl.nails then
			for i, nail in cl.nails do
				linkEnt(`n{i}`, cl.spikeindex or 0, nail.origin, nail.angles, 0, 0, time)
			end
		end

		for key, re in renderEnts do
			if not liveKeys[key] then
				entrender.destroy(re)
				renderEnts[key] = nil
				renderDefs[key] = nil
			end
		end
	end

	----------------------------------------------------------------------
	-- lightstyles (cl_main frame animation)
	local function updateLightstyles(time: number)
		local changed: { [number]: boolean } = {}
		local i = math.floor(time * 10)
		-- 10Hz texture writers ride the same tick (R_UpdateSky/turb + the
		-- R_TextureAnimation +wall chain at (int)(cl.time*5) %% total)
		if i ~= lastStyleFrame then
			lastStyleFrame = i
			for _, ta in textureAnims do
				if ta.kind == "turb" then
					textures.writeTurbFrame(ta.img, ta.pixels, ta.w, ta.h, pal, cl.time)
				elseif ta.kind == "sky" then
					textures.writeSkyFrame(ta.img, ta.pixels, ta.w, ta.h, pal, cl.time)
				elseif ta.kind == "wall" then
					local base = ta.base
					local frames = ta.frames
					local parts = ta.parts
					if base and frames and parts and base.anim_total > 0 then
						local reletive = math.floor(cl.time * 5) % base.anim_total
						local tex = base
						local count = 0
						while tex.anim_min > reletive or tex.anim_max <= reletive do
							local nxt = tex.anim_next
							if not nxt then
								error("R_TextureAnimation: broken cycle")
							end
							tex = nxt
							count += 1
							if count > 100 then
								error("R_TextureAnimation: infinite cycle")
							end
						end
						if tex.name ~= ta.current then
							local fimg = frames[tex.name]
							if fimg then
								ta.current = tex.name
								local content = Content.fromObject(fimg)
								for _, part in parts do
									part.TextureContent = content
								end
							end
						end
					end
				end
			end
		end
		for style, map in cl.lightstyles do
			if #map > 0 then
				local c = map:byte((i % #map) + 1) - string.byte("a")
				local v = c * 22
				if styleValues[style] ~= v then
					styleValues[style] = v
					changed[style] = true
				end
			end
		end
		if next(changed) then
			worldmesh.updateLightStyles(changed)
		end
	end

	----------------------------------------------------------------------
	-- connect + main loop
	qwcl.connect(cl, function(packet: buffer)
		reliable:FireServer(packet)
	end)
	print("[robloquake] qw client connecting...")

	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	-- CalcFov over the vrect (window minus sbar), per SCR_CalcRefdef
	local currentFov = 90
	local currentViewsize = 100
	local gunVrectPitch = 0
	local function applyFov()
		local vp = camera.ViewportSize
		local fovY = qcoords.vrect(currentFov, vp.X, vp.Y, hudlib.sbarLinesPx(currentViewsize))
		camera.FieldOfView = fovY
		gunVrectPitch = 0 -- superseded by the viewmodel ViewportFrame
		viewmodellib.setLayout(vmgun, currentFov, hudlib.sbarLinesPx(currentViewsize))
	end
	applyFov()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyFov)
	input.init(0)
	input.lockMouse()
	input.setEnabled(true)

	-- direct key wiring plus the console/messagemode tiers (keys.c
	-- Key_Event: console first, chat line second, game keys last)
	local UserInputService = game:GetService("UserInputService")

	local function refreshInputMode()
		-- while the console or chat line is up the player stops moving
		input.setEnabled(not (con.open or chatOpen))
	end

	-- Cmd_ExecuteString subset: the client commands the QW boot handles
	-- locally; everything else is forwarded verbatim (Cmd_ForwardToServer:
	-- "things like godmode, noclip, etc, are commands directed to the
	-- server, so when they are typed in at the console, they will need to
	-- be forwarded")
	local function execCommand(line: string)
		local cmd, args = line:match("^(%S+)%s*(.*)$")
		if not cmd then
			return
		end
		cmd = cmd:lower()
		if cmd == "messagemode" or cmd == "messagemode2" then
			-- Con_MessageMode_f / Con_MessageMode2_f
			chatTeam = cmd == "messagemode2"
			chatOpen = true
			chatBuffer = ""
			refreshInputMode()
		elseif cmd == "quit" or cmd == "disconnect" then
			-- CL_Quit_f / CL_Disconnect_f: N/A on this platform
			consolelib.print(con, "use the Roblox menu to leave the experience")
		elseif cmd == "+showscores" or cmd == "-showscores" then
			-- Sbar_ShowScores / Sbar_DontShowScores (TAB binds these)
			hudlib.setShowScores(hud, cmd == "+showscores")
		elseif cmd == "fov" then
			local v = tonumber(args)
			if v and v >= 10 and v <= 170 then
				currentFov = v
				applyFov()
			end
		elseif cmd == "viewsize" then
			-- screen.c: 100 full HUD, 110 status row only, 120 none
			local v = tonumber(args)
			if v then
				currentViewsize = math.clamp(v, 30, 120)
				hudlib.setViewsize(hud, currentViewsize)
				applyFov()
			end
		elseif cmd == "clear" then
			table.clear(con.lines)
		elseif cmd == "toggleconsole" then
			consolelib.toggle(con)
			refreshInputMode()
		elseif cl.state == "disconnected" then
			consolelib.print(con, `Can't "{cmd}", not connected`)
		else
			-- say/say_team and every unrecognized command → clc_stringcmd
			qwcl.sendStringCmd(cl, line)
		end
	end
	con.onCommand = execCommand

	-- console text entry straight from key codes (same scheme as the NQ
	-- boot: no TextBox, GetStringForKeyCode + shifted punctuation)
	local SHIFT_MAP: { [string]: string } = {
		["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%",
		["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
		["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}", ["\\"] = "|",
		[";"] = ":", ["'"] = "\"", [","] = "<", ["."] = ">", ["/"] = "?",
	}

	local function keyToChar(key: Enum.KeyCode, shifted: boolean): string?
		local ok, str = pcall(UserInputService.GetStringForKeyCode, UserInputService, key)
		if not ok or #str ~= 1 then
			if key == Enum.KeyCode.Space then
				return " "
			end
			return nil
		end
		local b = str:byte()
		if b < 32 or b >= 127 then
			return nil
		end
		-- GetStringForKeyCode reports letters uppercase; the console types
		-- lowercase unless shift is held (key_console behaviour)
		if str:match("%a") then
			return if shifted then str:upper() else str:lower()
		end
		if shifted then
			return SHIFT_MAP[str] or str
		end
		return str
	end

	local function isShiftDown(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	-- Key_Console via the consolelib line editor
	local function consoleKey(key: Enum.KeyCode)
		local fake = { KeyCode = key, UserInputType = Enum.UserInputType.Keyboard }
		if consolelib.handleKey(con, fake :: any) then
			local ch = keyToChar(key, isShiftDown())
			if ch then
				consolelib.handleText(con, ch)
			end
		end
	end

	-- Key_Message: the chat line typed after T (messagemode)
	local function messageKey(key: Enum.KeyCode)
		if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			execCommand((if chatTeam then "say_team" else "say") .. " \"" .. chatBuffer .. "\"")
			chatOpen = false
			chatBuffer = ""
			refreshInputMode()
		elseif key == Enum.KeyCode.Escape then
			chatOpen = false
			chatBuffer = ""
			refreshInputMode()
		elseif key == Enum.KeyCode.Backspace then
			chatBuffer = chatBuffer:sub(1, -2)
		else
			local ch = keyToChar(key, isShiftDown())
			if ch then
				chatBuffer ..= ch
			end
		end
	end

	-- debug hook: drive the console remotely (verification without keypresses)
	local dbgConsole = Instance.new("BindableFunction")
	dbgConsole.Name = "RQDBG_Console"
	dbgConsole.Parent = Workspace
	dbgConsole.OnInvoke = function(action: string, arg: string?)
		if action == "toggle" then
			consolelib.toggle(con)
			refreshInputMode()
			return tostring(con.open)
		elseif action == "isopen" then
			return tostring(con.open)
		elseif action == "exec" then
			-- raw line through execCommand (no pre-splitting; the QW
			-- subset has no Cbuf, but quoted args must survive intact)
			execCommand(arg :: string)
			return "ok"
		elseif action == "key" then
			consoleKey((Enum.KeyCode :: any)[arg])
			return con.inputText
		elseif action == "text" then
			return con.inputText
		elseif action == "lines" then
			return table.concat(con.lines, "\n")
		end
		return ""
	end
	local keyButtons: { [Enum.KeyCode]: string } = {
		[Enum.KeyCode.W] = "forward",
		[Enum.KeyCode.Up] = "forward",
		[Enum.KeyCode.S] = "back",
		[Enum.KeyCode.Down] = "back",
		[Enum.KeyCode.A] = "moveleft",
		[Enum.KeyCode.D] = "moveright",
		[Enum.KeyCode.Space] = "jump",
		[Enum.KeyCode.LeftControl] = "attack",
		[Enum.KeyCode.LeftShift] = "speed",
	}
	local showScoresDown = false
	local lastPingRequest = 0
	local function onKey(io: InputObject, down: boolean)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			input.setButton("attack", down)
			return
		end
		if io.KeyCode == Enum.KeyCode.Tab then
			-- +showscores (Roblox also opens its playerlist; documented)
			if down ~= showScoresDown then
				showScoresDown = down
				hudlib.setShowScores(hud, down)
			end
			return
		end
		local name = keyButtons[io.KeyCode]
		if name then
			input.setButton(name, down)
		elseif down and io.KeyCode.Value >= Enum.KeyCode.One.Value and io.KeyCode.Value <= Enum.KeyCode.Eight.Value then
			input.setImpulse(io.KeyCode.Value - Enum.KeyCode.Zero.Value)
		end
	end
	UserInputService.InputBegan:Connect(function(io, processed)
		if io.UserInputType == Enum.UserInputType.Keyboard then
			local key = io.KeyCode
			-- tilde/backquote toggles the console from anywhere
			if key == Enum.KeyCode.Backquote or key == Enum.KeyCode.Tilde then
				if chatOpen then
					chatOpen = false
					chatBuffer = ""
				end
				consolelib.toggle(con)
				refreshInputMode()
				return
			end
			if con.open then
				consoleKey(key)
				return
			end
			if chatOpen then
				messageKey(key)
				return
			end
			if key == Enum.KeyCode.T then
				execCommand("messagemode") -- default.cfg "bind t messagemode"
				return
			end
		elseif con.open or chatOpen then
			return -- mouse buttons don't reach the game while typing
		end
		if not processed then
			onKey(io, true)
		end
	end)
	UserInputService.InputEnded:Connect(function(io, _processed)
		onKey(io, false)
	end)

	local sndDrained = 0
	local accum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		cl.realtime += dt

		-- SCR_DrawConsole / Con_DrawNotify: console slide + the chat line
		consolelib.update(con, cl.realtime)
		chatHolder.Visible = chatOpen
		if chatOpen then
			local ccursor = if math.floor(cl.realtime * 4) % 2 == 0 then string.char(11) else " "
			confontlib.setRow(con.font, chatRow, "say: " .. chatBuffer .. ccursor)
		end

		-- inbound packets
		for _, packet in inbound do
			local ok, err = pcall(qwcl.processPacket, cl, packet)
			if not ok then
				warn("[qwcl] " .. tostring(err))
			end
		end
		table.clear(inbound)

		if cl.state == "disconnected" then
			return
		end

		-- level change: rebuild the render world from scratch
		if (cl.levelResets or 0) ~= seenLevelResets then
			seenLevelResets = cl.levelResets or 0
			worldBuilt = false
			staticsSpawned = 0
			staticSoundsSpawned = 0
			table.clear(modelDefs)
			-- release the old level's meshes SYNCHRONOUSLY: Destroying
			-- signals are deferred, so ClearAllChildren alone still holds
			-- the EditableMesh budget while the new world builds, starving
			-- it into skipped batches (holes in the world)
			for _, tpl in brushTemplates do
				worldmesh.destroyBuild(tpl)
			end
			table.clear(brushTemplates)
			table.clear(lightAnim)
			table.clear(textureAnims)
			for key, re in renderEnts do
				entrender.destroy(re)
				renderEnts[key] = nil
				renderDefs[key] = nil
			end
			for _, re in staticRes do
				entrender.destroy(re)
			end
			table.clear(staticRes)
			if gunEnt then
				entrender.destroy(gunEnt)
				gunEnt = nil
			end
			gunModelIndex = 0
			for _, child in worldFolder:GetChildren() do
				worldmesh.destroyBuild(child)
			end
			-- rebuild next frame: destroyed fixed-mesh budget is reclaimed
			-- asynchronously, and a same-frame rebuild starves into skipped
			-- batches (holes in the world)
			return
		end

		buildWorld()
		if not worldBuilt then
			return
		end
		spawnPendingStatics()

		-- server-forced view angles (spawn/teleport fixangle)
		if cl.setangle then
			cl.setangle = false
			input.setAngles(cl.viewangles)
		end

		-- find the spike model index once for nail rendering
		if not cl.spikeindex then
			for i, name in cl.model_name do
					if name == "progs/spike.mdl" then
					cl.spikeindex = i -- precache slot, 1-based
				end
			end
		end

		-- send a move every frame like cl_maxfps (msec capped like C)
		input.updateTurn(dt)
		local st = input.sample()
		local viewangles = input.viewangles()
		cl.viewangles = viewangles
		local buttons = 0
		if st.attack then
			buttons += 1
		end
		if st.jump then
			buttons += 2
		end
		accum += dt
		local msec = math.floor(accum * 1000)
		if msec > 250 then
			msec = 100 -- CL_FinishMove's hitch substitution
			accum = 0
		end
		if msec >= 1 and cl.state ~= "connected" then
			accum -= msec / 1000
			-- Cam_Track/Cam_FinishMove ride the outgoing cmd; while locked
			-- the chase takes over the controls (moves zeroed like C)
			camTrack(buttons)
			local camOn = cl.spectator and autocam ~= CAM_NONE and camLocked
			qwcl.sendCmd(cl, {
				angles = viewangles,
				forwardmove = if camOn then 0 else st.forwardmove,
				sidemove = if camOn then 0 else st.sidemove,
				upmove = if camOn then 0 else st.upmove,
				buttons = buttons,
				impulse = st.impulse,
				msec = msec,
			})
			input.setImpulse(0)
		end

		qwcl.predictMove(cl)
		if cl.state ~= "active" then
			return
		end

		-- camera: predicted origin + view height + view angles
		local viewheight = cl.stats[qwp.STAT_VIEWHEIGHT]
		if not viewheight or viewheight == 0 then
			viewheight = 22
		end
		-- V_SetContentsColor from the view leaf + V_CalcPowerupCshift
		do
			local contents = -1
			if cl.worldmodel then
				local leaf = bsplib.pointInLeaf(cl.simorg + vector.create(0, 0, 22), cl.worldmodel)
				contents = leaf.contents
			end
			local cs = cshifts[1]
			if contents == -5 then -- CONTENTS_LAVA
				cs.r, cs.g, cs.b, cs.percent = 255, 80, 0, 150
			elseif contents == -4 or contents == -2 then -- SLIME / SOLID
				cs.r, cs.g, cs.b, cs.percent = 0, 25, 5, 150
			elseif contents == -3 then -- WATER
				cs.r, cs.g, cs.b, cs.percent = 130, 80, 50, 128
			else
				cs.percent = 0
			end

			local itbits = cl.stats[qwp.STAT_ITEMS] or 0
			local pw = cshifts[4]
			if bit32.band(itbits, 4194304) ~= 0 then -- IT_QUAD
				pw.r, pw.g, pw.b, pw.percent = 0, 0, 255, 30
			elseif bit32.band(itbits, 2097152) ~= 0 then -- IT_SUIT
				pw.r, pw.g, pw.b, pw.percent = 0, 255, 0, 20
			elseif bit32.band(itbits, 524288) ~= 0 then -- IT_INVISIBILITY
				pw.r, pw.g, pw.b, pw.percent = 100, 100, 100, 100
			elseif bit32.band(itbits, 1048576) ~= 0 then -- IT_INVULNERABILITY
				pw.r, pw.g, pw.b, pw.percent = 255, 255, 0, 30
			else
				pw.percent = 0
			end

			-- drop the damage and bonus values
			cshifts[2].percent = math.max(cshifts[2].percent - dt * 150, 0)
			cshifts[3].percent = math.max(cshifts[3].percent - dt * 100, 0)

			-- V_CalcBlend
			local r, g, b, a = 0, 0, 0, 0
			for _, csh in cshifts do
				local a2 = csh.percent / 255
				if a2 > 0 then
					a = a + a2 * (1 - a)
					a2 = a2 / a
					r = r * (1 - a2) + csh.r * a2
					g = g * (1 - a2) + csh.g * a2
					b = b * (1 - a2) + csh.b * a2
				end
			end
			a = math.clamp(a, 0, 1)
			if a > 0 then
				cshiftFrame.BackgroundColor3 = Color3.fromRGB(r, g, b)
				cshiftFrame.BackgroundTransparency = 1 - a
			else
				cshiftFrame.BackgroundTransparency = 1
			end
		end

		-- V_CalcRefdef: bob, roll, kicks, death/gib view, intermission
		-- DropPunchAngle, verbatim: punchangle -= 10*dt, clamped at 0 from
		-- below — since kicks arrive negative, a kick lasts one frame
		-- (authentic QW; the lingering NQ recoil was NetQuake behavior)
		cl.punchangle -= 10 * dt
		if cl.punchangle < 0 then
			cl.punchangle = 0
		end
		local ownState = cl.frames[bit32.band(cl.parsecount, qwp.UPDATE_MASK)].playerstate[cl.playernum]
		local trackPs = camTrackedState()
		local eye, angles
		local gunVisible = false
		local gunFrame = ownState.weaponframe
		if cl.intermission ~= 0 then
			-- V_CalcIntermissionRefdef: fixed org/angles, no bob/height
			eye = cl.simorg
			angles = cl.simangles
		elseif trackPs then
			-- Cam_Track chase lock: through the tracked player's eyes at
			-- their predicted origin (stats already mirror the target)
			local predicted = qwcl.predictedPlayerOrigins(cl)
			eye = (predicted[spec_track] or trackPs.origin) + vector.create(0, 0, viewheight)
			angles = trackPs.viewangles
			-- Cam_DrawViewModel true while chase locked; self->weaponframe
			-- = player->weaponframe
			gunVisible = true
			gunFrame = trackPs.weaponframe
		elseif (cl.stats[qwp.STAT_HEALTH] or 100) <= 0 or bit32.band(ownState.flags, qwp.PF_DEAD) ~= 0 then
			-- dead: corpse view at -16 with the 80-degree death roll
			eye = cl.simorg + vector.create(0, 0, -16)
			angles = vector.create(cl.simangles.x, cl.simangles.y, 80)
		else
			-- V_CalcBob
			local cycle = (cl.time % 0.6) / 0.6
			if cycle < 0.5 then
				cycle = math.pi * cycle / 0.5
			else
				cycle = math.pi + math.pi * (cycle - 0.5) / 0.5
			end
			local bob = math.sqrt(cl.simvel.x * cl.simvel.x + cl.simvel.y * cl.simvel.y) * 0.02
			bob = math.clamp(bob * 0.3 + bob * 0.7 * math.sin(cycle), -7, 4)

			-- V_CalcRoll on own velocity
			local _bf, bright, _bu = mathlib.angleVectors(cl.simangles)
			local side = vector.dot(cl.simvel, bright)
			local rsign = if side < 0 then -1 else 1
			side = math.abs(side)
			local roll = (if side < 200 then side * 2.0 / 200 else 2.0) * rsign

			if bit32.band(ownState.flags, qwp.PF_GIB) ~= 0 then
				viewheight += 8 -- gibbed: view from the head
			end
			-- V_CalcViewRoll damage kick
			local kroll, kpitch = 0, 0
			if v_dmg_time > 0 then
				kroll = v_dmg_time / V_KICKTIME * v_dmg_roll
				kpitch = v_dmg_time / V_KICKTIME * v_dmg_pitch
				v_dmg_time -= dt
			end
			eye = cl.simorg + vector.create(0, 0, viewheight + bob)
			angles = vector.create(cl.simangles.x + cl.punchangle + kpitch, cl.simangles.y, cl.simangles.z + roll + kroll)
			gunVisible = true
		end
		-- smooth out stair step ups (view.c V_CalcRefdef): oldz glides up
		-- at 80 u/s and never lags more than 12 units below the real z
		if cl.intermission == 0 and not trackPs and ownState.onground ~= -1 and cl.simorg.z - v_oldz > 0 then
			v_oldz += dt * 80
			if v_oldz > cl.simorg.z then
				v_oldz = cl.simorg.z
			end
			if cl.simorg.z - v_oldz > 12 then
				v_oldz = cl.simorg.z - 12
			end
			eye += vector.create(0, 0, v_oldz - cl.simorg.z)
		else
			v_oldz = cl.simorg.z
		end

		local fwd, right, up = mathlib.angleVectors(angles)
		camera.CFrame = qcoords.cframe(eye, fwd, right, up)
		viewmodellib.update(vmgun, camera)

		-- view weapon: STAT_WEAPON model at the eye, weaponframe animated
		local gunModel = cl.stats[qwp.STAT_WEAPON] or 0
		if gunVisible and gunModel ~= 0 then
			if gunModelIndex ~= gunModel then
				if gunEnt then
					entrender.destroy(gunEnt)
					gunEnt = nil
				end
				gunModelIndex = gunModel
				local def = getModelDef(gunModel)
				if def and def.kind == "alias" then
					-- the gun renders through its own projection (viewmodel.luau)
					gunEnt = entrender.create(def, vmgun.world)
				end
			end
			local ge = gunEnt
			if ge then
				local def = getModelDef(gunModel) :: entrender.ModelDef
				local gunorg = eye + fwd * (math.sqrt(cl.simvel.x * cl.simvel.x + cl.simvel.y * cl.simvel.y) * 0.02 * 0.4)
				-- vrect: in C the gun hugs the 3D view bottom, which ends
				-- ABOVE the sbar; rotate it up by the vrect center offset
				-- so the HUD doesn't cover it (see qcoords.vrect)
				entrender.updateAlias(ge, def, gunorg, vector.create(-angles.x, angles.y, angles.z), gunFrame, 0, 0, cl.time)
				-- R_DrawViewModel: always give some light on the gun
				local glight = if cl.worldmodel then lightpoint.at(cl.worldmodel, eye, styleValueFor) else 255
				for _, dl in dlights do
					if dl.die >= cl.time and dl.radius > 0 then
						local add = dl.radius - vector.magnitude(eye - dl.origin)
						if add > 0 then
							glight += add
						end
					end
				end
				entrender.setLight(ge, math.max(glight, 24))
			end
		elseif gunEnt then
			entrender.updateAlias(gunEnt, getModelDef(gunModelIndex) :: entrender.ModelDef, vector.create(0, 0, -10000), vector.zero, 0, 0, 0, cl.time)
		end

		relinkEntities(cl.time)
		updateLightstyles(cl.realtime)

		-- studio diagnostics + command hook (console overlay is follow-up)
		local pendingCmd = Workspace:GetAttribute("QW_Cmd")
		if typeof(pendingCmd) == "string" and pendingCmd ~= "" then
			Workspace:SetAttribute("QW_Cmd", "")
			qwcl.sendStringCmd(cl, pendingCmd)
		end
		Workspace:SetAttribute("QW_SimOrg", Vector3.new(cl.simorg.x, cl.simorg.y, cl.simorg.z))
		Workspace:SetAttribute("QW_OnGround", ownState.onground)
		Workspace:SetAttribute("QW_State", cl.state)
		Workspace:SetAttribute("QW_SeqIn", cl.netchan.incoming_sequence)
		Workspace:SetAttribute("QW_SeqOut", cl.netchan.outgoing_sequence)
		Workspace:SetAttribute("QW_Valid", cl.validsequence)

		-- sounds
		for i = sndDrained + 1, #cl.sounds do
			local snd = cl.sounds[i]
			if snd.num < 0 then
				soundlib.stop(sndsys, snd.ent, snd.channel) -- svc_stopsound
			else
				local name = cl.sound_name[snd.num]
				if name then
					soundlib.start(sndsys, snd.ent, snd.channel, name, snd.pos, snd.vol / 255, snd.atten)
				end
			end
		end
		sndDrained = #cl.sounds
		if sndDrained > 512 then
			table.clear(cl.sounds)
			sndDrained = 0
		end

		-- CL_ParseTEnt / CL_MuzzleFlash
		for _, te in cl.tempEntities do
			handleTempEntity(te)
		end
		table.clear(cl.tempEntities)
		updateBeams()
		particleslib.update(psys, cl.time, dt)

		-- CL_DecayLights + the dynamic light surface pass
		do
			local active: { lightatlaslib.Dlight } = {}
			for _, dl in dlights do
				if dl.die >= cl.time and dl.radius > 0 then
					dl.radius -= dt * dl.decay
					if dl.radius > 0 then
						table.insert(active, dl)
					end
				end
			end
			if cl.worldmodel then
				worldmesh.updateDlights(cl.worldmodel.brush, active)
			end
		end
		while #cl.centerprints > 0 do
			local cp = table.remove(cl.centerprints, 1)
			if cp then
				hudlib.centerPrint(hud, cp, cl.time)
			end
		end

		-- Con_Printf: notify lines onto the hud + console scrollback
		while #cl.prints > 0 do
			local p = table.remove(cl.prints, 1)
			if p then
				hudlib.print(hud, p.text, cl.time)
				consolelib.print(con, p.text)
				print("[qw] " .. p.text:gsub("\n$", ""))
			end
		end

		-- Sbar_Draw
		hudlib.setLoading(hud, false)
		hudlib.setPaused(hud, cl.paused == true)
		updateHudAdapter()
		-- request new ping times every two seconds while the board shows
		if (showScoresDown or cl.intermission ~= 0) and cl.realtime - (lastPingRequest or 0) > 2 then
			lastPingRequest = cl.realtime
			qwcl.sendStringCmd(cl, "pings")
		end
		hudlib.updateOverlaysQW(hud, hudC)
		hudlib.update(hud, hudC)
	end)
end
