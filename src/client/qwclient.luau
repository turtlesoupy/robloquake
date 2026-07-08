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
local qwplerp = require(engine.qw.qwplerp)
local qwview = require(engine.qw.qwview)

local bsplib = require(engine.bsp.bsp)
local mdllib = require(engine.models.mdl)

local avatarlayer = require(script.Parent.render.avatarlayer)
local confontlib = require(script.Parent.render.confont)
local entrender = require(script.Parent.render.entrender)
local lightatlaslib = require(script.Parent.render.lightatlas)
local mildmode = require(script.Parent.render.mildmode)
local lightpoint = require(engine.client.lightpoint)
local viewlib = require(engine.client.view)
local particleslib = require(script.Parent.render.particles)
local skinforge = require(script.Parent.render.skinforge)
local textures = require(script.Parent.render.textures)
local worldmesh = require(script.Parent.render.worldmesh)
local consolelib = require(script.Parent.console)
local hudlib = require(script.Parent.hud)
local menulib = require(script.Parent.menu)
local input = require(script.Parent.input)
local keymap = require(script.Parent.keymap)
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

	-- remote players render on a slightly delayed, interpolated timeline
	-- (qwplerp) instead of QW's extrapolate-and-snap — every wire state
	-- is buffered here as it parses, keyed by its state_time
	local plerpHists: { [number]: qwplerp.Hist } = {}
	cl.onPlayerState = function(num: number, st: any)
		local h = plerpHists[num]
		if not h then
			h = qwplerp.new()
			plerpHists[num] = h
		end
		qwplerp.push(h, st.messagenum, st.state_time, st.origin, st.viewangles.x, st.viewangles.y, st.velocity, st.frame)
	end

	-- live net diagnostics: one compact line per rendered remote player
	-- every 10s to the client log (F9 developer console) — published
	-- playtests have no attribute access, and these numbers are the
	-- whole debugging story: rendered step uniformity + which smoothing
	-- mechanism fired (dups/holds/resyncs) + delay/noise levels
	type NetDiag = {
		prev: vector?,
		n: number,
		sum: number,
		sumsq: number,
		max: number,
		stalls: number,
		spikes: number,
		delayMs: number,
		pushes: number, -- hist counter baselines (window diffing)
		dups: number,
		holds: number,
		resyncs: number,
	}
	local netdiag: { [number]: NetDiag } = {}
	local lastNetDiagAt = 0
	local function netDiagStep(num: number, porigin: vector, delay: number)
		local d = netdiag[num]
		if not d then
			d = { n = 0, sum = 0, sumsq = 0, max = 0, stalls = 0, spikes = 0, delayMs = 0, pushes = 0, dups = 0, holds = 0, resyncs = 0 }
			local h = plerpHists[num]
			if h then
				d.pushes, d.dups, d.holds, d.resyncs = h.pushes, h.dups, h.holds, h.resyncs
			end
			netdiag[num] = d
		end
		d.delayMs = math.max(d.delayMs, delay * 1000)
		local prev = d.prev
		d.prev = porigin
		if prev then
			local s = vector.magnitude(porigin - prev)
			d.n += 1
			d.sum += s
			d.sumsq += s * s
			if s > d.max then
				d.max = s
			end
			local m = d.sum / d.n
			if m > 1 then -- stall/spike shape only means something in motion
				if s < 0.2 * m then
					d.stalls += 1
				elseif s > 2 * m then
					d.spikes += 1
				end
			end
		end
	end
	local function netDiagFlush(now: number)
		if now - lastNetDiagAt < 10 then
			return
		end
		lastNetDiagAt = now
		for num, d in netdiag do
			local h = plerpHists[num]
			if d.n > 30 and h then
				local m = d.sum / d.n
				local sd = math.sqrt(math.max(d.sumsq / d.n - m * m, 0))
				print(
					`[qwnet] p{num} snaps={h.pushes - d.pushes}(+{h.dups - d.dups}dup)`
						.. ` holds={h.holds - d.holds} resyncs={h.resyncs - d.resyncs}`
						.. ` delay={math.floor(d.delayMs + 0.5)}ms noise={math.floor(math.abs(h.timeErr) * 1000 + 0.5)}ms`
						.. ` | step qu/frame mean={string.format("%.1f", m)} sd={string.format("%.1f", sd)}`
						.. ` max={string.format("%.1f", d.max)} stalls={d.stalls} spikes={d.spikes} n={d.n}`
				)
			end
		end
		table.clear(netdiag)
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
	input.setLookLocked(true)
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
		scoresGen = 0,
		viewentity = 1,
		levelname = "",
		paused = false,
	}
	local lastDamageCount = 0

	-- view blends (view.c): the offline-tested qwview pipeline
	local blend = qwview.newBlendState()
	-- V_CalcRefdef persistent state: V_CalcBob bobtime/held-bob + stair oldz
	local qwRefdefState = viewlib.newQWRefdefState()
	-- V_DriftPitch state (QW has no idealpitch wire — centers to 0)
	local pitchDrift = viewlib.newPitchDrift()
	local lastDriftPitch: number? = nil
	local showFps = false -- SCR_DrawFPS gate (show_fps command)
	-- cl_demo.c: in-memory .qwd store (no user filesystem; same policy
	-- as the NQ boot's demo store)
	local demos: { [string]: buffer } = {}
	local demoRecordName: string? = nil
	local demoBlocks: { any }? = nil
	local demoIdx = 1
	local demoTime = 0

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
	if not sndsys.enabled then
		consolelib.notifyBox(con, "No soundbank built - running silent.\nSee tools/build_soundbank.py.")
	end
	local mnu = menulib.create(fs, pal, overlayGui)
	mnu.qwMode = true
	mnu.onBeep = function(name: string)
		soundlib.localSound(sndsys, name)
	end
	mnu.print = function(s2: string)
		consolelib.print(con, s2)
	end
	mnu.onQuit = function()
		consolelib.print(con, "use the Roblox menu to leave the experience")
	end

	-- SCR_DrawCrosshair: the conchars '+' glyph, gated by the crosshair
	-- cvar (same window-centre anchoring rationale as the NQ boot)
	local crosshairLabel = Instance.new("ImageLabel")
	crosshairLabel.Name = "crosshair"
	crosshairLabel.BackgroundTransparency = 1
	crosshairLabel.ResampleMode = Enum.ResamplerMode.Pixelated
	crosshairLabel.Size = UDim2.fromOffset(8 * 2, 8 * 2)
	crosshairLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshairLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
	crosshairLabel.ZIndex = 0
	confontlib.apply(con.font, crosshairLabel, string.byte("+"))
	crosshairLabel.Parent = overlayGui

	-- Chat compliance (see the NQ boot's twin): say/say_team submit to
	-- TextChatService for filtering; filtered text rides cl.prints as
	-- PRINT_CHAT so it renders like a wire chat line. The server refuses
	-- raw wire say.
	local generalChat: TextChannel? = nil
	task.spawn(function()
		local TextChatService = game:GetService("TextChatService")
		local ok, channels = pcall(function()
			return TextChatService:WaitForChild("TextChannels", 10)
		end)
		local found = if ok and channels then channels:FindFirstChild("RBXGeneral") else nil
		if found and found:IsA("TextChannel") then
			local tch = found :: TextChannel
			generalChat = tch
			tch.MessageReceived:Connect(function(m: TextChatMessage)
				if m.Status ~= Enum.TextChatMessageStatus.Success then
					return
				end
				local src = m.TextSource
				local name = if src then src.Name else "?"
				table.insert(cl.prints, { level = qwp.PRINT_CHAT, text = `{name}: {m.Text}\n` })
			end)
		else
			warn("[fragparty] TextChatService general channel unavailable — say disabled (filtering is required for player speech)")
		end
	end)
	local function sayViaTextChat(text: string)
		if text:sub(1, 1) == '"' then
			text = text:sub(2, -2)
		end
		if text == "" then
			return
		end
		local ch = generalChat
		if not ch then
			consolelib.print(con, "chat unavailable")
			return
		end
		task.spawn(function()
			pcall(function()
				ch:SendAsync(text)
			end)
		end)
	end

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
	local explosions: { qwview.Explosion? } = {}
	local explosionIndex: number? = nil

	-- forward ref: execCommand is declared after the stufftext consumer
	-- below, but stuffed lines must run through the full command layer
	-- (Cbuf_AddText semantics — mods stuff "setinfo topcolor N" etc.)
	local execStuffLine: (string) -> () = function(_line: string) end

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
				qwview.parseDamage(blend, dmg.save, dmg.take, dmg.from, cl.simorg, cl.simangles)
			end
		end

		-- server-stuffed commands run through the console layer like C's
		-- Cbuf_AddText: "bf"/"v_cshift" from pickups and triggers, but
		-- also mod stuffcmds — threewave's color lock stuffs "setinfo
		-- topcolor/bottomcolor N" to team-color new joiners
		local raw = cl.rawStufftext
		if raw and raw ~= "" then
			cl.rawStufftext = ""
			for line in raw:gmatch("[^\n]+") do
				execStuffLine(line)
			end
		end

		-- Sbar_SortFrags source: scoreboard slots from player infos; any
		-- field change bumps scoresGen, the HUD's rebuild gate
		local scoresDirty = false
		for i = 0, qwp.MAX_CLIENTS - 1 do
			local info = cl.players[i]
			local slot = hudC.scores[i + 1]
			if not slot then
				slot = { name = "", frags = 0, colors = 0 }
				hudC.scores[i + 1] = slot
				scoresDirty = true
			end
			if info then
				local team = info.userinfo.team or ""
				local top = tonumber(info.userinfo.topcolor) or 0
				local bottom = tonumber(info.userinfo.bottomcolor) or 0
				local colors = top * 16 + bottom
				if
					slot.name ~= info.name
					or slot.frags ~= info.frags
					or slot.ping ~= info.ping
					or slot.pl ~= info.pl
					or slot.entertime ~= info.entertime
					or slot.spectator ~= info.spectator
					or slot.team ~= team
					or slot.colors ~= colors
				then
					scoresDirty = true
					slot.name = info.name
					slot.frags = info.frags
					slot.ping = info.ping
					slot.pl = info.pl
					slot.entertime = info.entertime
					slot.spectator = info.spectator
					slot.team = team
					slot.colors = colors
				end
			elseif slot.name ~= "" then
				slot.name = ""
				scoresDirty = true
			end
		end
		if scoresDirty then
			hudC.scoresGen += 1
		end

		-- Sbar_TeamOverlay/serverinfo gate + own slot for the mini overlay
		hudC.teamplay = tonumber(cl.serverinfo.teamplay) or 0
		hudC.playerslot = cl.playernum + 1
		hudC.spectator = cl.spectator
	end

	-- CL_AllocDlight pool lives in qwcl (shared, offline-tested)
	local function allocDlight(key: number, _time: number): lightatlaslib.Dlight
		return qwcl.allocDlight(cl, key)
	end

	-- CL_ParseBeam state (bolt models, 0.2s lifetime, 30-unit segments)
	local MAX_BEAMS = 8
	local beams: { any } = {}
	local beamDefs: { [string]: any } = {}
	local beamPool: { [string]: { entrender.RenderEnt } } = {}
	local updateBeams: () -> ()
	local handleTempEntity: (te: any) -> ()
	local muzzleFlashUntil: { [number]: number } = {} -- 1-based player ent num

	local styleValues: { [number]: number } = {}
	local function styleValueFor(style: number): number
		return styleValues[style] or worldmesh.BASE_STYLE_VALUE
	end

	local lightAnim: { worldmesh.AnimEntry } = {}
	local textureAnims: { worldmesh.TextureAnim } = {}
	local lastStyleFrame = -1
	local modelDefs: { [number]: entrender.ModelDef } = {}
	local brushTemplates: { [string]: Model } = {}
	local buildingTemplates: { [string]: boolean } = {}
	local worldBuilt = false -- buildWorld entered (guards re-entry from later frames)
	local worldReady = false -- buildWorld returned: every mesh batch is up
	local seenLevelResets = 0
	local staticsSpawned = 0
	local staticSoundsSpawned = 0
	-- destroyed on level change; def/es kept so framegroup statics (torch
	-- flames) can re-pose by time each frame like R_DrawEntitiesOnList
	local staticRes: { { re: entrender.RenderEnt, def: any, es: any } } = {}

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
			def = {
				kind = "alias" :: "alias",
				alias = m.alias,
				flags = m.alias.flags,
				-- mild mode: gibs/heads render untextured white
				forceWhite = if mildmode.enabled and mildmode.isGibModel(name) then true else nil,
			}
			entrender.prepareImages(def, pal)
		elseif m.kind == "sprite" then
			def = { kind = "sprite" :: "sprite", sprite = m.sprite, flags = 0 }
			entrender.prepareImages(def, pal)
		elseif m.kind == "brush" and modelindex ~= 1 then
			-- submodels ("*n") AND standalone brush models (ammo/health
			-- boxes, b_*.bsp) — everything but the world itself
			local template = brushTemplates[name]
			if not template then
				-- worldmesh.build can YIELD (budget backoff); a relink during
				-- that yield must not start a second build of the same
				-- template (each re-parse leaks fresh light-atlas regions)
				if buildingTemplates[name] then
					return nil -- build in flight; caller retries next frame
				end
				buildingTemplates[name] = true
				local anim
				template, anim = worldmesh.build(m.brush, pal, nil :: any, name)
				buildingTemplates[name] = nil
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

	----------------------------------------------------------------------
	-- Roblox avatars mode (product layer, live-flippable via the
	-- roblox_avatars attribute the server mirrors onto QuakeClientFS).
	-- All rules live in the SHARED avatarlayer module (same code as the
	-- NQ boot); this block only adapts QW data shapes. The alias renderer
	-- remains the fallback (rig loading, toggle off).
	local avatarLocalFolder = Instance.new("Folder")
	avatarLocalFolder.Name = "QuakeAvatarRigs"
	avatarLocalFolder.Parent = Workspace

	local function avatarsOn(): boolean
		return clientAssets:GetAttribute("roblox_avatars") == true
	end

	-- Avatar HUD face (product layer, live-flippable): the sbar face
	-- becomes the local player's avatar head. avatar_face attribute:
	-- absent = follow roblox_avatars; explicit boolean forces either way.
	local function avatarFaceOn(): boolean
		local af = clientAssets:GetAttribute("avatar_face")
		if af == nil then
			return avatarsOn()
		end
		return af == true
	end
	hudlib.setAvatarFace(hud, avatarFaceOn())
	clientAssets:GetAttributeChangedSignal("avatar_face"):Connect(function()
		hudlib.setAvatarFace(hud, avatarFaceOn())
	end)
	clientAssets:GetAttributeChangedSignal("roblox_avatars"):Connect(function()
		hudlib.setAvatarFace(hud, avatarFaceOn())
	end)

	-- R_AliasSetupLighting: lightmap sample under the entity plus dynamic
	-- light adds (rigs + hand weapons; QW alias ents keep their own path)
	local function entityLight(origin: vector): number
		if not cl.worldmodel then
			return 255
		end
		local elight = lightpoint.at(cl.worldmodel, origin, styleValueFor)
		for _, dl in cl.dlights do
			if dl.die >= cl.time and dl.radius > 0 then
				local add = dl.radius - vector.magnitude(origin - dl.origin)
				if add > 0 then
					elight += add
				end
			end
		end
		return elight
	end

	-- procedural weapon skins: forged per (model, spec) and cached for the
	-- session. The tweaks menu (T) picks a spec per viewmodel name; the
	-- RQ_WeaponSkin workspace attribute (e.g. "camo:7") is a debug override
	-- applied to weapons without a menu selection. nil/empty spec restores
	-- the authentic skin.
	local forgedSkins: { [string]: EditableImage } = {}
	local weaponSkins: { [string]: string } = {} -- viewmodel name -> recipe spec
	local gunSkinApplied: string? = nil
	local GUN_SKIN_STALE = "\0stale" -- never equals a real cache key
	local function applyGunSkin(re: entrender.RenderEnt, def: entrender.ModelDef, modelindex: number)
		local name = cl.model_name[modelindex]
		local spec: string? = if name then weaponSkins[name] else nil
		if not spec then
			local attr = Workspace:GetAttribute("RQ_WeaponSkin")
			if type(attr) == "string" and attr ~= "" then
				spec = attr
			end
		end
		local key = if spec then `{name or modelindex}|{spec}` else nil
		if key == gunSkinApplied then
			return
		end
		gunSkinApplied = key
		if not key or not spec then
			entrender.setSkinOverride(re, nil)
			re.fullbrightSkin = def.fullbrightSkin
			return
		end
		local img = forgedSkins[key]
		if not img and def.skinPixels then
			local forged =
				skinforge.createImage(spec :: string, def.skinPixels :: buffer, def.skinW :: number, def.skinH :: number, pal)
			if forged then
				forgedSkins[key] = forged
				img = forged
			end
		end
		entrender.setSkinOverride(re, img)
		-- saturated skins are marked unlit so setLight keeps them vivid
		-- in dark rooms (same path as torch flames)
		re.fullbrightSkin = def.fullbrightSkin or (img ~= nil and skinforge.isUnlit(spec :: string))
	end

	-- third-person twin of applyGunSkin for avatarlayer: forge (or fetch)
	-- a skin spec against the held g_ world model's own skin sheet; nil =
	-- authentic. Called per frame, so failed forges are cached to avoid
	-- re-forging every frame. forgeSkin also serves OTHER players' picks
	-- (replicated via the RQWeaponSkins attribute prefstore stamps).
	local forgeFailed: { [string]: boolean } = {}
	local function forgeSkin(spec: string, worldModel: string, def: entrender.ModelDef): EditableImage?
		if not def.skinPixels then
			return nil
		end
		local key = `{worldModel}|{spec}`
		local img = forgedSkins[key]
		if not img and not forgeFailed[key] then
			local forged =
				skinforge.createImage(spec, def.skinPixels :: buffer, def.skinW :: number, def.skinH :: number, pal)
			if forged then
				forgedSkins[key] = forged
				img = forged
			else
				forgeFailed[key] = true
			end
		end
		return img
	end
	local function localWeaponSkin(vmName: string, worldModel: string, def: entrender.ModelDef): EditableImage?
		local spec = weaponSkins[vmName]
		return if spec then forgeSkin(spec, worldModel, def) else nil
	end

	local avatarLayer = avatarlayer.new({
		rigFolder = avatarLocalFolder,
		entFolder = entFolder,
		getModelDef = getModelDef,
		modelIndexByName = function(name: string): number?
			for i, n in cl.model_name do
				if n == name then
					return i
				end
			end
			return nil
		end,
		entityLight = entityLight,
		worldHull = function(): any?
			local wm = cl.worldmodel
			return if wm then wm.hulls[1] else nil
		end,
		time = function(): number
			return cl.time
		end,
		palette = pal,
		localWeaponSkin = localWeaponSkin,
		forgeSkin = forgeSkin,
	})

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
		-- worldmesh.build yields on budget backoff, so frames run while it
		-- streams batches in; worldReady (not worldBuilt, which flips at
		-- entry as the re-entrancy guard) is what gates the render loop
		worldReady = true
		print(`[fragparty] qw world built: {cl.levelname}`)
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
					table.insert(staticRes, { re = re, def = def, es = es })
					if def.kind == "alias" then
						entrender.updateAlias(re, def, es.origin, es.angles, es.frame, es.skinnum, 0, cl.time)
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
			-- (QW signals the flash here, not via entity effects — mark it
			-- so the avatar layer's weapon flash/recoil/burst still fires)
			local entnum = te.entity or 0
			muzzleFlashUntil[entnum] = cl.time + 0.1
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
			-- C keys by positive entity number: a player's muzzleflash and
			-- EF_*LIGHT dlight share one slot (flash replaces glow)
			local dl = allocDlight(entnum, cl.time)
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
			-- mild mode: 225's palette band is shared with lava splashes
			-- and knight spikes, so whiten by substituting the regular
			-- blood color here instead of remapping the band
			local lbColor = if mildmode.enabled then 73 else 225
			particleslib.runEffect(psys, te.pos, vector.zero, lbColor, 50, cl.time, true)
		elseif t == qwp.TE_EXPLOSION or t == qwp.TE_TAREXPLOSION then
			particleslib.explosion(psys, te.pos, cl.time)
			if t == qwp.TE_EXPLOSION then
				-- CL_AllocExplosion: reuse a free slot, else the oldest
				-- (ring logic offline-tested in test_qwview)
				qwview.allocExplosion(explosions, te.pos, cl.time)
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
	-- spectator autocam (cl_cam.c): logic lives in qwcl (offline-tested);
	-- these thin views adapt it for the render loop
	local CAM_NONE = 0
	local function camTrackedState(): qwcl.PlayerState?
		return qwcl.camTrackedState(cl)
	end
	local function camTrack(buttons: number)
		local msgText = qwcl.camTrack(cl, buttons)
		if msgText then
			consolelib.print(con, msgText)
		end
	end

	----------------------------------------------------------------------
	-- entity linking (packet entities + players + nails)
	local renderEnts: { [string]: entrender.RenderEnt } = {}
	local renderDefs: { [string]: entrender.ModelDef } = {}
	local liveKeys: { [string]: boolean } = {}
	local trailOrigins: { [string]: vector } = {}
	local gunEnt: entrender.RenderEnt? = nil
	local gunModelIndex = 0

	-- Render-ent pool: QW delta compression drops entities freely (PVS
	-- edges, packet overflow) and they return a frame or two later. C keeps
	-- cl_entities render state forever and just skips drawing; destroying
	-- the EditableMesh on drop meant an async ms-scale rebuild (and mesh-
	-- budget churn) on return, with the entity invisible meanwhile. Instead
	-- retired ents hide into a per-modeldef pool and are reused on return;
	-- entries idle past POOL_GRACE are destroyed for real.
	local entPool: { [entrender.ModelDef]: { entrender.RenderEnt } } = {}
	local entPoolAt: { [entrender.RenderEnt]: number } = {}
	local POOL_GRACE = 5 -- seconds hidden before a pooled ent is freed

	local function setEntVisible(re: entrender.RenderEnt, visible: boolean)
		local root: Instance? = re.part or re.billboardPart or re.model
		if root then
			(root :: any).Parent = if visible then entFolder else nil
		end
	end

	local function retireEnt(key: string, time: number)
		local re = renderEnts[key]
		local def = renderDefs[key]
		renderEnts[key] = nil
		renderDefs[key] = nil
		if not re then
			return
		end
		if not def then
			entrender.destroy(re)
			return
		end
		setEntVisible(re, false)
		local pool = entPool[def]
		if not pool then
			pool = {}
			entPool[def] = pool
		end
		table.insert(pool, re)
		entPoolAt[re] = time
	end

	local function sweepEntPool(time: number)
		for def, pool in entPool do
			local i = 1
			while i <= #pool do
				local re = pool[i]
				if time - (entPoolAt[re] or 0) > POOL_GRACE then
					entrender.destroy(re)
					entPoolAt[re] = nil
					pool[i] = pool[#pool]
					pool[#pool] = nil
				else
					i += 1
				end
			end
			if #pool == 0 then
				entPool[def] = nil
			end
		end
	end

	local function destroyEntPool()
		for _, pool in entPool do
			for _, re in pool do
				entrender.destroy(re)
			end
		end
		table.clear(entPool)
		table.clear(entPoolAt)
	end

	local function linkEnt(key: string, modelindex: number, origin: vector, angles: vector, frame: number, skinnum: number, time: number, colors: number?)
		local def = getModelDef(modelindex)
		if not def or def.kind == "none" then
			return
		end
		liveKeys[key] = true
		local re = renderEnts[key]
		if re and renderDefs[key] ~= def then
			retireEnt(key, time)
			re = nil
		end
		if not re then
			local pool = entPool[def]
			local n = if pool then #pool else 0
			if pool and n > 0 then
				re = pool[n]
				pool[n] = nil
				entPoolAt[re :: entrender.RenderEnt] = nil
				setEntVisible(re :: entrender.RenderEnt, true)
			else
				re = entrender.create(def, entFolder)
			end
			if not re then
				return
			end
			renderEnts[key] = re
			renderDefs[key] = def
		end
		-- a pooled/reused ent may carry a mild-mode corpse fade; restore
		-- it (no-op otherwise; the corpse path re-applies after linking)
		mildmode.applyFade(re, 0)
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
		local seenAvatars: { [number]: boolean } = {}
		local frame: qwcl.Frame = cl.frames[bit32.band(cl.netchan.incoming_sequence, qwp.UPDATE_MASK)]

		for _, es in frame.packet_entities do
			local key = `e{es.number}`
			-- bodyque corpses (CopyToBodyQue): player.mdl packet entities in
			-- the death band keep the owner's avatar — colormap carries the
			-- owner's slot, exactly like the NQ boot
			-- mild mode: bodyque corpses fade after a hold. Packet entities
			-- in player.mdl death frames ARE corpses (live players arrive
			-- via playerinfo); a recycled bodyque slot resets the timer via
			-- its origin jump (see mildmode.corpseAlpha)
			local mildCorpse = mildmode.enabled
				and es.modelindex == cl.playerindex
				and avatarLayer.isDeathFrame(es.frame)
			local corpseFade = if mildCorpse then mildmode.corpseAlpha(`e{es.number}`, es.origin, cl.time) else 0

			local corpsePlayer: Player? = nil
			local corpseColors: number? = nil
			if
				avatarsOn()
				and es.modelindex == cl.playerindex
				and avatarLayer.isDeathFrame(es.frame)
				and es.colormap > 0
				and es.colormap <= qwp.MAX_CLIENTS
			then
				corpsePlayer = avatarLayer.playerForSlot(es.colormap)
				-- corpses keep the owner's shirt/pants re-skin (colormap is
				-- the 1-based owner slot; cl.players is 0-based)
				local info = cl.players[es.colormap - 1]
				if info then
					local top = tonumber(info.userinfo.topcolor) or 0
					local bottom = tonumber(info.userinfo.bottomcolor) or 0
					corpseColors = top * 16 + bottom
				end
			end
			if
				corpsePlayer
				and avatarLayer.updatePlayer(1000 + es.number, corpsePlayer, es.origin, es.angles, es.frame, 0, corpseColors, true)
			then
				avatarLayer.setFade(1000 + es.number, corpseFade) -- after update: 0 restores
				seenAvatars[1000 + es.number] = true
			else
				-- projectile muzzle blend: tag fresh projectiles near an
				-- avatar's gun; render blended toward the true origin
				local re0 = renderEnts[key]
				local org = if re0 and avatarsOn() then avatarLayer.blendOrigin(re0, es.origin) else es.origin
				linkEnt(key, es.modelindex, org, es.angles, es.frame, es.skinnum, time)
				if mildCorpse then
					mildmode.applyFade(renderEnts[key], corpseFade)
				end
				if not re0 and avatarsOn() then
					local re1 = renderEnts[key]
					if re1 then
						avatarLayer.tagMuzzle(re1, cl.model_name[es.modelindex], es.origin)
					end
				end
			end

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
		-- RQDBG_QWSelfAvatar: render your OWN avatar too (normally skipped,
		-- since it is the first-person camera) so avatar behaviour —
		-- especially the velocity-driven walk animation — can be verified
		-- solo without a second client
		local drawSelf = workspace:GetAttribute("RQDBG_QWSelfAvatar") == true
		local velProbe = workspace:GetAttribute("RQDBG_QWVelProbe") == true
		-- RQDBG_QWNoLerp: fall back to CL_LinkPlayers extrapolate-and-snap.
		-- RQDBG_QWLerpSelf: route your OWN avatar through the remote-player
		-- path (its playerstates arrive at wire rate, a faithful solo proxy
		-- for how other players render — pair with RQDBG_QWSelfAvatar).
		local noLerp = workspace:GetAttribute("RQDBG_QWNoLerp") == true
		local lerpSelf = workspace:GetAttribute("RQDBG_QWLerpSelf") == true
		local playertime = math.min(cl.realtime - cl.latency + 0.02, cl.realtime)
		local peakPeerLagMs = 0
		local peakTimeNoiseMs = 0 -- wire-vs-assigned timeline error (jitter gauge)
		local peakPeerVel, peakPeerNum = 0, -1
		for num, ps in frame.playerstate do
			if ps.messagenum ~= cl.parsecount or (num == cl.playernum and not drawSelf) then
				continue
			end
			-- Cam_DrawPlayer: don't draw the target we are chase camming
			if cl.spectator and cl.cam.autocam ~= CAM_NONE and cl.cam.locked and num == cl.cam.spec_track then
				continue
			end
			-- remote players: interpolated delayed timeline (see qwplerp);
			-- the local player keeps the live predicted origin
			local porigin = predicted[num] or ps.origin
			local ppitch, pyaw = ps.viewangles.x, ps.viewangles.y
			local pvel = ps.velocity
			local pframe = ps.frame
			local remotePath = num ~= cl.playernum or lerpSelf
			local sampleDelay = 0
			if remotePath and lerpSelf and num == cl.playernum and noLerp then
				porigin = ps.origin -- raw wire baseline for the A/B probe
			elseif remotePath and not noLerp then
				local h = plerpHists[num]
				if h then
					local rt, d = qwplerp.step(h, playertime, cl.realtime)
					sampleDelay = d
					peakPeerLagMs = math.max(peakPeerLagMs, d * 1000)
					peakTimeNoiseMs = math.max(peakTimeNoiseMs, math.abs(h.timeErr) * 1000)
					local o, pi_, ya, ve, fr = qwplerp.sample(h, rt)
					if o then
						porigin, ppitch, pyaw, pvel, pframe = o, pi_, ya, ve, fr
					end
				end
			end
			if remotePath then
				netDiagStep(num, porigin, sampleDelay)
			end
			local angles = vector.create(-ppitch / 3, pyaw, 0)
			-- CL_LinkPlayers lean: V_CalcRoll (shared) * 4
			local roll = viewlib.calcRoll(angles, pvel) * 4
			angles = vector.create(angles.x, angles.y, roll)
			-- CL_NewTranslation: shirt/pants byte for the player skin
			local colors: number? = nil
			local info = cl.players[num]
			if info and ps.modelindex == cl.playerindex then
				local top = tonumber(info.userinfo.topcolor) or 0
				local bottom = tonumber(info.userinfo.bottomcolor) or 0
				colors = top * 16 + bottom
			end
			-- Roblox avatars mode: wire playernum is slot-1, so RQSlot maps
			-- num+1 -> Player. Death band renders the rig's scripted corpse.
			local avatarDrawn = false
			if avatarsOn() and ps.modelindex == cl.playerindex then
				local aplayer = avatarLayer.playerForSlot(num + 1)
				if aplayer then
					local effects = ps.effects
					if (muzzleFlashUntil[num + 1] or 0) > time then
						effects = bit32.bor(effects, 2) -- EF_MUZZLEFLASH for the layer
					end
					-- QW replicates velocity — drives the run/idle/jump/fall
					-- animation state directly (tick-rate origins can't).
					-- RQDBG_QWVelProbe: record the fastest rendered peer's
					-- horizontal wire speed so a 2-client test shows whether
					-- velocity actually arrives for other players
					if velProbe then
						local v = ps.velocity
						local vh = math.sqrt(v.x * v.x + v.y * v.y)
						if vh > peakPeerVel then
							peakPeerVel = vh
							peakPeerNum = num
						end
					end
					if avatarLayer.updatePlayer(num + 1, aplayer, porigin, angles, pframe, effects, colors, nil, nil, pvel) then
						seenAvatars[num + 1] = true
						avatarDrawn = true
					end
					-- rig still loading: alias fallback below
				end
			end
			if not avatarDrawn then
				linkEnt(`p{num}`, ps.modelindex, porigin, angles, pframe, ps.skinnum, time, colors)
			end

			-- CL_AddFlagModels: CTF flag riding on the carrier's back
			-- (placement math offline-tested in test_qwview)
			local efFlag = bit32.band(ps.effects, 16 + 32) -- EF_FLAG1|EF_FLAG2
			if efFlag ~= 0 and cl.flagindex then
				local forg, fang = qwview.flagPlacement(pframe, angles, porigin)
				linkEnt(`pf{num}`, cl.flagindex, forg, fang, 0, if bit32.band(ps.effects, 32) ~= 0 then 1 else 0, time)
			end
		end
		if velProbe then
			workspace:SetAttribute("RQDBG_QWPeerVel", peakPeerVel)
			workspace:SetAttribute("RQDBG_QWPeerNum", peakPeerNum)
		end
		if peakPeerLagMs > 0 then
			workspace:SetAttribute("QW_PeerLagMs", math.floor(peakPeerLagMs + 0.5))
			workspace:SetAttribute("QW_TimeNoiseMs", math.floor(peakTimeNoiseMs + 0.5))
		end
		netDiagFlush(time)

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
					local f = qwview.explosionFrame(ex, time, numframes)
					if not f then
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

		for key in renderEnts do
			if not liveKeys[key] then
				retireEnt(key, time)
			end
		end
		sweepEntPool(time)
		avatarLayer.hideExcept(seenAvatars)
	end

	----------------------------------------------------------------------
	-- lightstyles (cl_main frame animation)
	local changedScratch: { [number]: boolean } = {} -- reused per frame; empty on non-tick frames
	local function updateLightstyles(time: number)
		local changed = changedScratch
		table.clear(changed)
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
	-- The per-frame movement stream rides the UnreliableRemoteEvent so
	-- real-network loss/batching can't head-of-line stall it (netchan
	-- sequencing absorbs drops and reorders, as over UDP). Packets
	-- carrying netchan-reliable content must never be lost — the
	-- handshake is a content-driven lockstep with no retry clock — so
	-- they ALSO ride the reliable remote; whichever copy arrives second
	-- is discarded as a stale sequence. Payloads over ~900 bytes are
	-- silently dropped by unreliable remotes, hence reliable-only.
	qwcl.connect(cl, function(packet: buffer, hasReliable: boolean?)
		local fits = buffer.len(packet) <= 850
		if fits then
			unreliable:FireServer(packet)
		end
		if hasReliable or not fits then
			reliable:FireServer(packet)
		end
	end)
	print("[fragparty] qw client connecting...")

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
	-- sbarLinesPx scales with hud.luau's mobile factor, which only settles
	-- once the HUD gui measures its real size (after boot on phones) —
	-- refit the vrect + viewmodel frame whenever the drawn strip changes
	-- height, or the gun floats clipped above the HUD
	hud.sbarStrip:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyFov)
	input.init(0)
	input.lockMouse()
	input.setEnabled(true)

	-- direct key wiring plus the console/messagemode tiers (keys.c
	-- Key_Event: console first, chat line second, game keys last)
	local UserInputService = game:GetService("UserInputService")

	local directorUiOpen = false
	local tweaksUiOpen = false
	local pauseUiOpen = false
	local function refreshInputMode()
		-- while the console, chat line or menu is up the player stops
		-- moving (Key_ClearStates lives in input.setEnabled(false))
		input.setEnabled(
			not (con.open or chatOpen or directorUiOpen or tweaksUiOpen or pauseUiOpen or menulib.isOpen(mnu))
		)
		if directorUiOpen or tweaksUiOpen or pauseUiOpen then
			input.freeMouse() -- the admin/tweaks/pause menus are clickable UI
		end
	end

	-- ===== match director UI (PRODUCT layer) — twin of the NQ block;
	-- see src/server/director.luau for the REMOVAL note. Placed after
	-- refreshInputMode so onUiToggle can drive input mode. =====
	local directorHandle = require(script.Parent.directorui).attach({
		playerGui = player:WaitForChild("PlayerGui"),
		net = net,
		-- vote panel draws pause-menu style (menukit box/conchars)
		fs = fs,
		pal = pal,
		isTyping = function()
			return con.open or chatOpen
		end,
		onUiToggle = function(open: boolean)
			directorUiOpen = open
			refreshInputMode()
		end,
	})
	-- ===== end match director UI =====

	-- ===== prefs bridge (PRODUCT layer) — twin of the NQ block; persisted
	-- settings + weapon skin picks + avatar tint; see src/server/prefstore.luau
	-- for the REMOVAL note =====
	-- quake shirt/pants rows: the local mirror the AVATAR page reads; sets
	-- ride the `color` command via execStuffLine (the forward ref — the
	-- real execCommand is declared later in this boot)
	local myTopColor, myBottomColor = 0, 0
	local prefsHandle = require(script.Parent.prefs).attach({
		net = net,
		-- SETTINGS page rows (menu.c M_Options): look/run live in input,
		-- volume is the soundbank master
		settings = {
			getSensitivity = input.getSensitivity,
			setSensitivity = input.setSensitivity,
			getInvertMouse = input.getInvertMouse,
			setInvertMouse = input.setInvertMouse,
			getAlwaysRun = input.getAlwaysRun,
			setAlwaysRun = input.setAlwaysRun,
			getVolume = function()
				return soundlib.getMasterVolume(sndsys)
			end,
			setVolume = function(v: number)
				soundlib.setMasterVolume(sndsys, v)
			end,
			getColors = function(): (number, number)
				return myTopColor, myBottomColor
			end,
			setColors = function(top: number, bottom: number)
				myTopColor, myBottomColor = top, bottom
				execStuffLine(`color {top} {bottom}`)
			end,
		},
		setWeaponSkin = function(mdlName: string, spec: string?)
			weaponSkins[mdlName] = spec
			gunSkinApplied = GUN_SKIN_STALE -- re-evaluate the held gun next frame
		end,
		validSpec = function(spec: string)
			return skinforge.parse(spec) ~= nil
		end,
	})
	-- ===== end prefs bridge =====

	-- ===== leaderboard data source (PRODUCT layer) — resolves the server's
	-- Leaderboards RemoteFunction for the pause menu's RANKINGS page; dormant
	-- when the stats pipeline is absent. REMOVAL: see src/server/stats.luau =====
	local lbHandle = require(script.Parent.leaderboardui).attach({ net = net })
	-- ===== end leaderboard data source =====

	-- ===== shop bridge (PRODUCT layer) — twin of the NQ block; Frag Coin
	-- wallet + owned skins for the pause menu's SHOP/MY SKINS pages.
	-- REMOVAL: see src/server/shop.luau =====
	local shopHandle = require(script.Parent.shopclient).attach({ net = net })
	-- ===== end shop bridge =====

	-- ===== pause menu (PRODUCT layer) — FRAG/SHOP overlay on E or the
	-- top-right MENU plaque, darkens the world 80% without pausing it;
	-- twin of the NQ block =====
	local pauseHandle = require(script.Parent.pausemenu).attach({
		playerGui = player:WaitForChild("PlayerGui"),
		fs = fs,
		pal = pal,
		isTyping = function()
			return con.open or chatOpen
		end,
		onUiToggle = function(open: boolean)
			pauseUiOpen = open
			refreshInputMode()
		end,
		playSound = function()
			soundlib.localSound(sndsys, "misc/menu2.wav") -- S_LocalSound menu click
		end,
		setWeaponSkin = prefsHandle.setWeaponSkin,
		-- MY SKINS block reads the equipped rocket-launcher pick from the mirror
		getWeaponSkin = prefsHandle.getWeaponSkin,
		-- RANKINGS page (L / the RANKINGS block) reads the kill boards from here
		leaderboards = lbHandle,
		-- CALL A VOTE page: live state + proposals ride the director bridge
		callvote = directorHandle.cv,
		-- SETTINGS page (menu.c M_Options): setters persist via the prefs bridge
		settings = prefsHandle.settings,
		-- AVATAR page: quake shirt/pants tint, persisted like any setting
		avatarColors = {
			get = prefsHandle.settings.getColors,
			set = prefsHandle.settings.setColors,
		},
		-- SHOP/MY SKINS pages: Frag Coin wallet, ownership, purchases
		shop = shopHandle,
	})
	-- ===== end pause menu =====

	-- ===== tweaks menu (PRODUCT layer) — weapon skin picker on T (its
	-- authentic talk job moved to Y; M calls a map vote, backslash is
	-- the engine menu) =====
	require(script.Parent.tweaksui).attach({
		playerGui = player:WaitForChild("PlayerGui"),
		isTyping = function()
			return con.open or chatOpen
		end,
		onUiToggle = function(open: boolean)
			tweaksUiOpen = open
			refreshInputMode()
		end,
		setWeaponSkin = prefsHandle.setWeaponSkin,
		menuFont = {
			isBig = pauseHandle.isBigFont,
			setBig = pauseHandle.setBigFont,
		},
		buttonBg = {
			isGrainy = pauseHandle.isGrainyBg,
			setGrainy = pauseHandle.setGrainyBg,
		},
	})
	-- ===== end tweaks menu =====

	-- keys.c bind system (Key_SetBinding/Key_Bind_f family): quake key
	-- names from the shared keymap; Key_Init seeds default.cfg-parity
	-- bindings. +/- button commands route through input.setButton.
	local BUTTON_CMDS = {
		forward = true, back = true, moveleft = true, moveright = true,
		left = true, right = true, lookup = true, lookdown = true,
		jump = true, attack = true, speed = true, strafe = true,
		klook = true,
	}
	local bindings: { [string]: string } = {
		w = "+forward", uparrow = "+forward",
		s = "+back", downarrow = "+back",
		a = "+moveleft", d = "+moveright",
		leftarrow = "+left", rightarrow = "+right",
		pgup = "+lookup", pgdn = "+lookdown",
		space = "+jump", ctrl = "+attack", shift = "+speed",
		-- talk sits on Y: T is the product tweaks-menu hotkey (tweaksui.luau).
		-- TAB is the scoreboard, default.cfg-style — the native player list
		-- CoreGui is disabled at boot (init.client.luau), freeing the key
		tab = "+showscores", y = "messagemode",
	}
	for i = 1, 8 do
		bindings[tostring(i)] = `impulse {i}`
	end
	local showScoresDown = false
	local lastPingRequest = 0

	-- Cmd_ExecuteString subset: the client commands the QW boot handles
	-- locally; everything else is forwarded verbatim (Cmd_ForwardToServer:
	-- "things like godmode, noclip, etc, are commands directed to the
	-- server, so when they are typed in at the console, they will need to
	-- be forwarded")
	-- Cmd_Alias_f store: mods stuff alias sets at connect (TeamFortress
	-- binds "scout"/"changeclass"/"+gren1"... to impulse chains); an alias
	-- body runs through execCommand per ';'-separated part
	local aliases: { [string]: string } = {}
	local aliasDepth = 0
	local function execCommand(line: string)
		local cmd, args = line:match("^(%S+)%s*(.*)$")
		if not cmd then
			return
		end
		cmd = cmd:lower()
		if cmd == "say" or cmd == "say_team" then
			-- player speech goes through Roblox filtering, never the wire
			sayViaTextChat(args :: string)
		elseif cmd == "messagemode" or cmd == "messagemode2" then
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
			showScoresDown = cmd == "+showscores"
			hudlib.setShowScores(hud, showScoresDown)
		elseif cmd == "+showteamscores" or cmd == "-showteamscores" then
			-- Sbar_ShowTeamScores / Sbar_DontShowTeamScores
			hudlib.setShowTeamScores(hud, cmd == "+showteamscores")
		elseif cmd == "record" or cmd == "rerecord" then
			-- CL_Record_f / CL_ReRecord_f (rerecord drops the current take)
			local name = (args :: string):match("[%w_%-]+")
			if not name then
				consolelib.print(con, "record <demoname>")
			elseif cl.recording and cmd == "record" then
				consolelib.print(con, "Already recording.")
			elseif cl.state ~= "active" then
				consolelib.print(con, "You must be connected to record.")
			else
				demoRecordName = name
				qwcl.recordStart(cl)
				consolelib.print(con, `recording to {name}.qwd.`)
			end
		elseif cmd == "stop" then
			-- CL_Stop_f
			local blocks = qwcl.recordStop(cl)
			if blocks and demoRecordName then
				demos[demoRecordName] = qwcl.demoSerialize(blocks)
				consolelib.print(con, "Completed demo")
			else
				consolelib.print(con, "Not recording a demo.")
			end
		elseif cmd == "playdemo" then
			-- CL_PlayDemo_f: replay a recorded .qwd (live packets are
			-- ignored while playing, like C's disconnect)
			local name = (args :: string):match("[%w_%-]+")
			local qwd = name and demos[name]
			if not qwd then
				consolelib.print(con, `couldn't open {tostring(name)}.qwd`)
			else
				demoBlocks = qwcl.demoParse(qwd)
				demoIdx = 1
				demoTime = (demoBlocks :: { any })[1].time
				consolelib.print(con, `Playing demo from {name}.qwd.`)
			end
		elseif cmd == "stopdemo" then
			demoBlocks = nil
			consolelib.print(con, "demo stopped; reconnecting")
			qwcl.sendStringCmd(cl, "new") -- rejoin the live stream
		elseif cmd == "show_fps" then
			-- SCR_DrawFPS gate
			showFps = (tonumber(args) or 0) ~= 0
			if not showFps then
				hudlib.setFps(hud, nil)
			end
		elseif cmd == "togglemenu" then
			menulib.toggle(mnu)
			refreshInputMode()
		elseif cmd == "crosshair" then
			local v = tonumber(args)
			if v then
				crosshairLabel.Visible = v ~= 0
			end
			consolelib.print(con, `"crosshair" is "{if crosshairLabel.Visible then 1 else 0}"`)
		elseif cmd == "play" or cmd == "playvol" then
			-- S_Play / S_PlayVol (C appends .wav when the name has no dot)
			local toks = {}
			for tok in (args :: string):gmatch("%S+") do
				table.insert(toks, tok)
			end
			local i = 1
			while i <= #toks do
				local name = toks[i]
				if not name:find("%.") then
					name ..= ".wav"
				end
				local vol = 1
				if cmd == "playvol" then
					vol = tonumber(toks[i + 1]) or 1
					i += 2
				else
					i += 1
				end
				if not soundlib.localSound(sndsys, name, vol) then
					consolelib.print(con, `couldn't load {name}`)
				end
			end
		elseif cmd == "soundlist" then
			-- S_SoundList (bank regions replace file sizes)
			consolelib.print(con, soundlib.soundList(sndsys))
		elseif cmd == "volume" then
			-- the "volume" cvar -> soundbank master (also the settings slider)
			local v = tonumber(args)
			if v then
				soundlib.setMasterVolume(sndsys, v)
			else
				consolelib.print(con, `"volume" is "{soundlib.getMasterVolume(sndsys)}"`)
			end
		elseif cmd == "sizeup" or cmd == "sizedown" then
			-- SCR_SizeUp_f / SCR_SizeDown_f: viewsize +/- 10
			currentViewsize = math.clamp(currentViewsize + (if cmd == "sizeup" then 10 else -10), 30, 120)
			hudlib.setViewsize(hud, currentViewsize)
			applyFov()
		elseif cmd == "color" then
			-- CL_Color_f: "color <top> [bottom]" -> topcolor/bottomcolor
			-- setinfo (the server broadcasts the change back)
			local a1, a2 = (args :: string):match("^(%d+)%s*(%d*)$")
			local top = math.min(tonumber(a1) or 0, 13)
			local bottom = math.min(tonumber(a2 or "") or top, 13)
			qwcl.sendStringCmd(cl, `setinfo topcolor {top}`)
			qwcl.sendStringCmd(cl, `setinfo bottomcolor {bottom}`)
		elseif cmd == "fullinfo" then
			-- CL_FullInfo_f: backslash-delimited pairs -> setinfos
			local info = (args :: string):gsub('^"(.*)"$', "%1")
			for k, v in info:gmatch("\\([^\\]+)\\([^\\]*)") do
				qwcl.sendStringCmd(cl, `setinfo {k} {v}`)
			end
		elseif cmd == "version" then
			-- CL_Version_f (exe date replaced by the port identity)
			consolelib.print(con, "Version 2.40\nFrag Party QuakeWorld port")
		elseif cmd == "users" then
			-- CL_Users_f: userid frags name for every connected player
			consolelib.print(con, "userid frags name")
			consolelib.print(con, "------ ----- ----")
			local total = 0
			for i = 0, 31 do
				local info = cl.players[i]
				if info and info.name ~= "" then
					consolelib.print(con, ("%6i %4i %s"):format(info.userid or 0, info.frags or 0, info.name))
					total += 1
				end
			end
			consolelib.print(con, `{total} total users`)
		elseif cmd == "user" then
			-- CL_User_f: dump one player's userinfo by name or userid
			local who = args :: string
			if who == "" then
				consolelib.print(con, "Usage: user <username / userid>")
			else
				local found = false
				for i = 0, 31 do
					local info = cl.players[i]
					if info and info.name ~= "" and (info.name == who or tostring(info.userid) == who) then
						found = true
						local keys = {}
						for k in info.userinfo do
							table.insert(keys, k)
						end
						table.sort(keys)
						for _, k in keys do
							local pad = if #k < 20 then (" "):rep(20 - #k) else ""
							consolelib.print(con, k .. pad .. tostring(info.userinfo[k]))
						end
					end
				end
				if not found then
					consolelib.print(con, "User not in server.")
				end
			end
		elseif (cmd:sub(1, 1) == "+" or cmd:sub(1, 1) == "-") and BUTTON_CMDS[cmd:sub(2)] then
			-- KeyDown/KeyUp wrappers: +forward/-forward etc.
			input.setButton(cmd:sub(2), cmd:sub(1, 1) == "+")
		elseif cmd == "bind" then
			-- Key_Bind_f
			local t = {}
			for tok in line:gmatch("%S+") do
				table.insert(t, tok)
			end
			local key = (t[2] or ""):lower()
			if key == "" then
				consolelib.print(con, "bind <key> [command] : attach a command to a key")
			elseif not keymap.CODES[key] then
				consolelib.print(con, `"{key}" isn't a valid key`)
			elseif #t == 2 then
				consolelib.print(con, `"{key}" = "{bindings[key] or ""}"`)
			else
				bindings[key] = table.concat(t, " ", 3):gsub('^"(.*)"$', "%1")
			end
		elseif cmd == "unbind" then
			-- Key_Unbind_f
			local key = (args :: string):lower():match("%S+")
			if key then
				bindings[key] = nil
			end
		elseif cmd == "unbindall" then
			-- Key_Unbindall_f
			table.clear(bindings)
		elseif cmd == "centerview" then
			-- V_StartPitchDrift: glide back to level, not a snap
			viewlib.startPitchDrift(pitchDrift, cl.time)
		elseif cmd == "impulse" then
			-- IN_Impulse is a CLIENT command in C (cl_input.c); it rides
			-- the next move cmd, never a server stringcmd
			input.setImpulse(tonumber(args) or 0)
		elseif cmd == "v_cshift" then
			-- V_cshift_f: edits what empty contents look like
			qwview.cshiftCmd(blend, args :: string)
		elseif cmd == "bf" then
			-- V_BonusFlash_f is also a console command in C
			qwview.bonusFlash(blend)
		elseif cmd == "fov" then
			local v = tonumber(args)
			if v and v >= 10 and v <= 170 then
				currentFov = v
				applyFov()
			end
		elseif cmd == "pushlatency" then
			-- cl_pred.c cvar; CL_PredictMove clamps positive values to 0
			local v = tonumber(args)
			if v then
				cl.pushlatency = v
			else
				consolelib.print(con, `"pushlatency" is "{cl.pushlatency}"`)
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
		elseif cmd == "team" or cmd == "skin" then
			-- QW userinfo cvars (cl_main.c registers them CVAR_USERINFO):
			-- mods stuff "team blue"/"skin tf_snipe" and their anticheat
			-- compares infokey(self, ...) — TF kicks anyone whose userinfo
			-- doesn't echo these back within 10s of joining a team
			local value = (args :: string):gsub('^"(.*)"$', "%1")
			qwcl.sendStringCmd(cl, `setinfo {cmd} {value}`)
		elseif cmd == "alias" then
			-- Cmd_Alias_f: "alias name cmds" (no args lists them)
			local name, body = (args :: string):match('^(%S+)%s*(.*)$')
			if not name then
				for n, b in aliases do
					consolelib.print(con, `{n} : {b}`)
				end
			else
				aliases[name:lower()] = (body :: string):gsub('^"(.*)"$', "%1")
			end
		elseif aliases[cmd] then
			-- expand like Cbuf: each ';' part is a command of its own
			if aliasDepth < 8 then -- ALIAS_LOOP guard
				aliasDepth += 1
				for part in aliases[cmd]:gmatch("[^;]+") do
					execCommand((part:gsub("^%s+", "")))
				end
				aliasDepth -= 1
			end
		elseif cmd == "wait" then
			-- Cmd_Wait_f defers the rest of the buffer a frame; our stuffed
			-- lines already run one batch per frame, so it's a no-op
		elseif cl.state == "disconnected" then
			consolelib.print(con, `Can't "{cmd}", not connected`)
		else
			-- say/say_team and every unrecognized command → clc_stringcmd
			qwcl.sendStringCmd(cl, line)
		end
	end
	con.onCommand = execCommand
	execStuffLine = execCommand
	mnu.onColor = function(top: number, bottom: number)
		execCommand(`color {top} {bottom}`)
	end
	-- CompleteCommand list (keys.c Tab): local + forwarded commands
	con.completions = {
		"bf", "centerview", "clear", "disconnect", "fov", "impulse", "kill",
		"messagemode", "messagemode2", "pause", "pings", "quit", "say",
		"play", "playvol", "soundlist", "sizedown", "sizeup", "color",
		"crosshair", "fullinfo", "record", "rerecord", "stop", "playdemo",
		"stopdemo", "show_fps", "togglemenu",
		"say_team", "serverinfo", "setinfo", "toggleconsole", "user",
		"users", "v_cshift", "version", "viewsize", "volume",
		"+showscores", "-showscores", "+showteamscores", "-showteamscores",
	}

	-- ===== touch + gamepad controls (PRODUCT layer) — twin of the NQ
	-- block; see src/client/controls.luau for the removal note. =====
	require(script.Parent.controls).attach({
		playerGui = player:WaitForChild("PlayerGui"),
		exec = execCommand,
		isUiOpen = function()
			return con.open or chatOpen or directorUiOpen or pauseUiOpen or menulib.isOpen(mnu)
		end,
		menuKey = function(key: Enum.KeyCode): boolean
			if not menulib.isOpen(mnu) then
				return false
			end
			menulib.handleKey(mnu, { KeyCode = key, UserInputType = Enum.UserInputType.Keyboard } :: any)
			refreshInputMode()
			return true
		end,
		font = hud.font,
		tapFires = function()
			-- score screen or dead: a tap advances / respawns
			return cl.intermission ~= 0 or (cl.stats[qwp.STAT_HEALTH] or 100) <= 0
		end,
	})
	-- ===== end touch + gamepad controls =====

	-- ===== tap-to-switch: invisible overlays on the ibar weapon icons so a
	-- touch/click directly on an icon selects that weapon, riding the same
	-- impulse path as the 2-8 keybinds (twin of the NQ block) =====
	for i, icon in hud.weaponIcons do
		local tap = Instance.new("TextButton")
		tap.Name = "WeaponTap"
		tap.BackgroundTransparency = 1
		tap.Text = ""
		tap.AutoButtonColor = false
		tap.Position = icon.Position
		tap.Size = icon.Size
		tap.ZIndex = icon.ZIndex + 1
		tap.Parent = icon.Parent
		tap.InputBegan:Connect(function(io: InputObject)
			-- Begin-state check: a look-drag sliding over the icon row must
			-- not switch weapons (same rule as the FIRE/JUMP buttons)
			local began = (io.UserInputType == Enum.UserInputType.Touch and io.UserInputState == Enum.UserInputState.Begin)
				or io.UserInputType == Enum.UserInputType.MouseButton1
			if began and not (con.open or chatOpen or directorUiOpen or pauseUiOpen or menulib.isOpen(mnu)) then
				execCommand("impulse " .. (i + 1))
			end
		end)
	end
	-- ===== end tap-to-switch =====

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
	local function onKey(io: InputObject, down: boolean)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			input.setButton("attack", down)
			return
		end
		local keyname = keymap.keyName(io.KeyCode)
		local b = keyname and bindings[keyname]
		if not b then
			return
		end
		if down then
			execCommand(b)
		elseif b:sub(1, 1) == "+" then
			execCommand("-" .. b:sub(2))
		end
	end
	UserInputService.InputBegan:Connect(function(io, processed)
		if io.UserInputType == Enum.UserInputType.Keyboard then
			local key = io.KeyCode
			-- tilde/backquote toggles the console from anywhere (dev surface:
			-- admins only, like the engine menu below)
			if key == Enum.KeyCode.Backquote or key == Enum.KeyCode.Tilde then
				if player:GetAttribute("RQAdmin") ~= true then
					return
				end
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
			if menulib.isOpen(mnu) then
				menulib.handleKey(mnu, io)
				refreshInputMode()
				return
			end
			if key == Enum.KeyCode.BackSlash and player:GetAttribute("RQAdmin") == true then
				-- M_ToggleMenu_f (Escape is platform-reserved; M calls the
				-- product map vote, see pausemenu.luau). Admin-only: players
				-- get the product pause menu on E instead.
				menulib.toggle(mnu)
				refreshInputMode()
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
	local turtleCount = 0
	local lastReceivedAt = 0
	local fpsFrames, fpsStart = 0, 0
	local firstFrameStamped = false
	RunService.Heartbeat:Connect(function(dt: number)
		cl.realtime += dt

		-- SCR_DrawTurtle / SCR_DrawNet / SCR_DrawFPS conditions
		if dt < 0.1 then
			turtleCount = 0
		else
			turtleCount += 1
		end
		if #inbound > 0 then
			lastReceivedAt = os.clock()
		end
		hudlib.setIcons(hud, turtleCount > 2, false, cl.state == "active" and os.clock() - lastReceivedAt > 0.3)
		if showFps then
			fpsFrames += 1
			if cl.realtime - fpsStart >= 1 then
				hudlib.setFps(hud, math.floor(fpsFrames / (cl.realtime - fpsStart) + 0.5))
				fpsFrames, fpsStart = 0, cl.realtime
			end
		end

		-- SCR_DrawConsole / Con_DrawNotify: console slide + the chat line
		consolelib.update(con, cl.realtime)
		menulib.update(mnu, cl.realtime)
		chatHolder.Visible = chatOpen
		if chatOpen then
			local ccursor = if math.floor(cl.realtime * 4) % 2 == 0 then string.char(11) else " "
			confontlib.setRow(con.font, chatRow, "say: " .. chatBuffer .. ccursor)
		end

		-- inbound packets (dropped while a demo plays — CL_GetDemoMessage
		-- replaces the net stream)
		if demoBlocks then
			table.clear(inbound)
			demoTime += dt
			local ok, err = pcall(function()
				demoIdx = qwcl.demoStep(cl, demoBlocks :: { any }, demoIdx, demoTime)
			end)
			if not ok then
				warn("[qwcl] demo: " .. tostring(err))
				demoBlocks = nil
			elseif demoIdx > #(demoBlocks :: { any }) then
				demoBlocks = nil
				consolelib.print(con, "demo completed; use stopdemo to rejoin")
			end
		end
		for _, packet in inbound do
			-- the return-type cast restores pcall's (ok, err) pair: the callee
			-- returns no values, so the typed pcall would only return `ok`
			local ok, err = pcall(qwcl.processPacket :: (any, buffer) -> string?, cl, packet)
			if not ok then
				-- Host_EndGame: a parse error leaves half-applied frame
				-- state (netchan already advanced) — fail loudly and
				-- disconnect instead of playing against corrupt deltas
				warn("[qwcl] Host_EndGame: " .. tostring(err))
				cl.disconnected_reason = tostring(err)
				cl.state = "disconnected"
				consolelib.print(con, `Host_EndGame: {tostring(err)}`)
				break
			end
		end
		table.clear(inbound)

		if cl.state == "disconnected" then
			return
		end

		-- level change: rebuild the render world from scratch
		if (cl.levelResets or 0) ~= seenLevelResets then
			seenLevelResets = cl.levelResets or 0
			table.clear(plerpHists) -- state_time restarts with the level
			table.clear(netdiag)
			lastNetDiagAt = 0
			-- S_StopAllSounds: C calls it from CL_ParseServerData; without
			-- it looping sounds carry across level changes
			soundlib.clear(sndsys)
			-- SCR_BeginLoadingPlaque: curtain up + look frozen until the
			-- first rendered frame of the new level
			hudlib.setLoading(hud, true)
			input.setLookLocked(true)
			worldBuilt = false
			worldReady = false
			staticsSpawned = 0
			staticSoundsSpawned = 0
			for _, def in modelDefs do
				entrender.destroyDef(def)
			end
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
			destroyEntPool() -- pooled ents reference the old level's defs
			for _, st in staticRes do
				entrender.destroy(st.re)
			end
			table.clear(staticRes)
			avatarLayer.destroyWeapons() -- weapon defs are per-level
			avatarLayer.hideAll() -- rigs persist across levels
			particleslib.clear(psys) -- R_ClearParticles on the map change
			-- CL_ClearTEnts: beams + explosions zeroed on level start; the
			-- pooled beam render instances are port-side and released too
			qwview.clearTEnts(beams, explosions)
			explosionIndex = nil
			for _, pool in beamPool do
				for _, re in pool do
					entrender.destroy(re)
				end
			end
			table.clear(beamPool)
			for _, def in beamDefs do
				if def then
					entrender.destroyDef(def)
				end
			end
			table.clear(beamDefs)
			if gunEnt then
				entrender.destroy(gunEnt)
				gunEnt = nil
			end
			gunModelIndex = 0
			-- precache indices renumber across levels, so the forged-skin
			-- cache keys go stale; images are ours to release (same budget
			-- pressure as destroyDef)
			for _, img in forgedSkins do
				img:Destroy()
			end
			table.clear(forgedSkins)
			table.clear(forgeFailed)
			gunSkinApplied = nil
			for _, child in worldFolder:GetChildren() do
				worldmesh.destroyBuild(child)
			end
			-- rebuild next frame: destroyed fixed-mesh budget is reclaimed
			-- asynchronously, and a same-frame rebuild starves into skipped
			-- batches (holes in the world)
			return
		end

		buildWorld()
		if not worldReady then
			return
		end
		spawnPendingStatics()

		-- statics with framegroup models (torch flames) animate by time, so
		-- alias statics re-pose every frame like R_DrawEntitiesOnList
		for _, st in staticRes do
			if st.re.kind == "alias" then
				entrender.updateAlias(st.re, st.def, st.es.origin, st.es.angles, st.es.frame, st.es.skinnum, 0, cl.time)
			end
		end

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
		-- cl_maxfps 77 equivalent: never send more than ~77 cmds/s. The
		-- server does a full pmove + entity encode per packet, so a
		-- 150fps client would otherwise double the per-client server
		-- cost (and its own packet volume) for no gameplay benefit.
		-- C's CL_SendCmd runs in every state past ca_disconnected —
		-- including the handshake, where this steady packet stream is
		-- the heartbeat that drives netchan retransmit convergence (the
		-- content exchange is a lockstep with no retry clock; over the
		-- unreliable remote a dropped keepalive would otherwise stall
		-- it). The server reads and ignores pre-spawn moves, as in C.
		if msec >= 13 and cl.state ~= "disconnected" and not demoBlocks then
			accum -= msec / 1000
			-- Cam_Track/Cam_FinishMove ride the outgoing cmd; while locked
			-- the chase takes over the controls (moves zeroed like C)
			camTrack(buttons)
			local camOn = cl.spectator and cl.cam.autocam ~= CAM_NONE and cl.cam.locked
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
		-- view.c blend pipeline (offline-tested in test_qwview):
		-- V_SetContentsColor from the view leaf, V_CalcPowerupCshift,
		-- the V_UpdatePalette drops, then V_CalcBlend onto the frame
		do
			local contents = -1
			local leafAmbient: { number }? = nil
			if cl.worldmodel then
				local leaf = bsplib.pointInLeaf(cl.simorg + vector.create(0, 0, 22), cl.worldmodel)
				contents = leaf.contents
				leafAmbient = leaf.ambient
			end
			-- S_UpdateAmbientSounds: water/sky ambience from the view leaf
			soundlib.updateAmbients(sndsys, leafAmbient, dt)
			qwview.setContentsColor(blend, contents)
			qwview.calcPowerupCshift(blend, cl.stats[qwp.STAT_ITEMS] or 0)
			qwview.dropShifts(blend, dt)
			local r, g, b, a = qwview.calcBlend(blend)
			if a > 0 then
				cshiftFrame.BackgroundColor3 = Color3.fromRGB(r, g, b)
				cshiftFrame.BackgroundTransparency = 1 - a
			else
				cshiftFrame.BackgroundTransparency = 1
			end
		end

		-- V_DriftPitch (QW view.c): glide pitch toward 0 while running;
		-- any manual pitch motion stops the drift like C's IN_MouseMove,
		-- and active mouselook stops it every frame (C calls
		-- V_StopPitchDrift under +mlook even with zero delta) so the
		-- drift never re-arms and recenters the view under mouselook
		do
			local ownPs = cl.frames[bit32.band(cl.parsecount, qwp.UPDATE_MASK)].playerstate[cl.playernum]
			if cl.intermission == 0 and ownPs then
				local vp = cl.viewangles.x
				if input.mlookActive() or (lastDriftPitch ~= nil and vp ~= lastDriftPitch) then
					viewlib.stopPitchDrift(pitchDrift, cl.time)
				end
				local drifted = viewlib.driftPitch(pitchDrift, cl.time, vp, 0, dt, ownPs.onground ~= -1, st.forwardmove)
				if drifted ~= vp then
					input.setAngles(vector.create(drifted, cl.viewangles.y, 0))
					cl.viewangles = vector.create(drifted, cl.viewangles.y, cl.viewangles.z)
				end
				lastDriftPitch = cl.viewangles.x
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
		local eye, angles, gunorg, gunangles
		local gunVisible = false
		local gunFrame = ownState.weaponframe
		if cl.intermission ~= 0 then
			-- V_CalcIntermissionRefdef: fixed org/angles, no bob/height,
			-- full idle sway (v_idlescale forced 1, shared V_AddIdle)
			eye = cl.simorg
			local ip, iy, ir = viewlib.addIdle(cl.time, 1)
			angles = cl.simangles + vector.create(ip, iy, ir)
			gunorg, gunangles = eye, vector.create(-angles.x, angles.y, 0)
			qwRefdefState.oldz = cl.simorg.z
		elseif trackPs then
			-- Cam_Track chase lock: through the tracked player's eyes at
			-- their predicted origin (stats already mirror the target)
			local predicted = qwcl.predictedPlayerOrigins(cl)
			eye = (predicted[cl.cam.spec_track] or trackPs.origin) + vector.create(0, 0, viewheight)
			angles = trackPs.viewangles
			-- Cam_DrawViewModel true while chase locked; self->weaponframe
			-- = player->weaponframe
			gunVisible = true
			gunFrame = trackPs.weaponframe
			gunorg, gunangles = eye, vector.create(-angles.x, angles.y, 0)
			qwRefdefState.oldz = cl.simorg.z
		else
			-- V_CalcRefdef core (QW view.c): shared, C-truth-traced vs
			-- tools/view_truth.c (test_view_truth) — bob, lean, kicks,
			-- gib/dead heights, gun composition, punch order, stair glide
			local gib = bit32.band(ownState.flags, qwp.PF_GIB) ~= 0
			local dead = not gib
				and (bit32.band(ownState.flags, qwp.PF_DEAD) ~= 0 or (cl.stats[qwp.STAT_HEALTH] or 100) <= 0)
			eye, angles, gunorg, gunangles, gunVisible = viewlib.calcRefdefQW(qwRefdefState, blend, {
				dt = dt,
				simorg = cl.simorg,
				simvel = cl.simvel,
				simangles = cl.simangles,
				punchangle = cl.punchangle,
				onground = ownState.onground ~= -1,
				dead = dead,
				gib = gib,
				spectator = cl.spectator,
				viewheight = viewheight,
			})
		end
		local fwd, right, up = mathlib.angleVectors(angles)
		-- RQDBG_QWSelfAvatar: pull the camera back into third person so the
		-- self avatar (rendered at the eye) is visible; suppress the
		-- 1st-person viewmodel gun (it would float at the camera). Debug
		-- preview only — the self avatar holds the world weapon anyway.
		if workspace:GetAttribute("RQDBG_QWSelfAvatar") == true then
			local back = workspace:GetAttribute("RQDBG_QWSelfChaseDist")
			local d = if typeof(back) == "number" then back else 210
			-- pull back far enough that the whole body clears the HUD in a
			-- level view; only a small rise (camera looks horizontally)
			eye = eye - fwd * d + up * 34
			gunVisible = false
		end
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
				gunSkinApplied = nil -- fresh RenderEnt: reapply any forged skin
				gunModelIndex = gunModel
				local def = getModelDef(gunModel)
				if def and def.kind == "alias" then
					-- the gun renders through its own projection (viewmodel.luau)
					gunEnt = entrender.create(def, vmgun.world)
					if gunEnt then
						-- viewports ignore part/SA tints; light rides the frame
						gunEnt.lightFrame = vmgun.frame
					end
				end
			end
			local ge = gunEnt
			if ge then
				local def = getModelDef(gunModel) :: entrender.ModelDef
				applyGunSkin(ge, def, gunModel)
				-- vrect: in C the gun hugs the 3D view bottom, which ends
				-- ABOVE the sbar; rotate it up by the vrect center offset
				-- so the HUD doesn't cover it (see qcoords.vrect)
				entrender.updateAlias(ge, def, gunorg, gunangles, gunFrame, 0, 0, cl.time)
				-- R_DrawViewModel: always give some light on the gun
				local glight = if cl.worldmodel then lightpoint.at(cl.worldmodel, eye, styleValueFor) else 255
				for _, dl in cl.dlights do
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
		-- per-frame attribute replication is not free: publish the
		-- diagnostics only while a debugging session asks for them
		if Workspace:GetAttribute("RQDBG_QWDiag") then
			Workspace:SetAttribute("QW_SimOrg", Vector3.new(cl.simorg.x, cl.simorg.y, cl.simorg.z))
			Workspace:SetAttribute("QW_OnGround", ownState.onground)
			Workspace:SetAttribute("QW_State", cl.state)
			Workspace:SetAttribute("QW_SeqIn", cl.netchan.incoming_sequence)
			Workspace:SetAttribute("QW_SeqOut", cl.netchan.outgoing_sequence)
			Workspace:SetAttribute("QW_Valid", cl.validsequence)
			Workspace:SetAttribute("QW_NetDrops", cl.netDrops or 0)
		end

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

		-- CL_DecayLights + the dynamic light surface pass (shared math)
		do
			local active = qwcl.decayDlights(cl, dt)
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
				if p.level == qwp.PRINT_CHAT then
					soundlib.localSound(sndsys, "misc/talk.wav") -- S_LocalSound
				end
				-- wire prints arrive in pieces (QC sprints "You got the "
				-- and "nails\n" separately): Con_Print append joins them
				local text = mildmode.softPrint(p.text) -- crude obituaries -> tamer jokes
				hudlib.printCon(hud, text, cl.time)
				consolelib.printCon(con, text)
				print("[qw] " .. text:gsub("\n$", ""))
			end
		end

		-- Sbar_Draw
		hudlib.setLoading(hud, false)
		input.setLookLocked(false)
		hudlib.setPaused(hud, cl.paused == true)
		updateHudAdapter()
		-- request new ping times every two seconds while the board shows
		if (showScoresDown or cl.intermission ~= 0) and cl.realtime - (lastPingRequest or 0) > 2 then
			lastPingRequest = cl.realtime
			qwcl.sendStringCmd(cl, "pings")
		end
		hudlib.updateOverlaysQW(hud, hudC)
		hudlib.update(hud, hudC)

		-- first completed frame dismisses the ReplicatedFirst cover screen
		if not firstFrameStamped then
			firstFrameStamped = true
			player:SetAttribute("RQ_FirstFrame", true)
		end
	end)
end
