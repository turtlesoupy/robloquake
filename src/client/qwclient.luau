--!strict
-- QuakeWorld client boot: selected when QuakeClientFS has attribute
-- engine="qw". Drives the qwcl core (connection, delta frames,
-- prediction) and renders through the shared render/* modules. First
-- cut covers world + entities + players + sounds + input/camera; the
-- QW sbar/console overlay is tracked as follow-up work.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local mathlib = require(engine.common.mathlib)
local vfslib = require(engine.common.vfs)
local qcoords = require(engine.client.qcoords)
local qwcl = require(engine.qw.qwcl)
local qwp = require(engine.qw.qwprotocol)

local mdllib = require(engine.models.mdl)

local entrender = require(script.Parent.render.entrender)
local lightatlaslib = require(script.Parent.render.lightatlas)
local lightpoint = require(script.Parent.render.lightpoint)
local particleslib = require(script.Parent.render.particles)
local textures = require(script.Parent.render.textures)
local worldmesh = require(script.Parent.render.worldmesh)
local input = require(script.Parent.input)
local soundlib = require(script.Parent.sound)

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
	local modelDefs: { [number]: entrender.ModelDef } = {}
	local brushTemplates: { [string]: Model } = {}
	local worldBuilt = false
	local seenLevelResets = 0
	local staticsSpawned = 0
	local staticSoundsSpawned = 0

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
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 10, cl.time)
			spikeSound(te.pos)
		elseif t == qwp.TE_SUPERSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 20, cl.time)
			spikeSound(te.pos)
		elseif t == qwp.TE_GUNSHOT then
			particleslib.runEffect(psys, te.pos, vector.zero, 0, 20 * (te.count or 1), cl.time)
		elseif t == qwp.TE_BLOOD then
			particleslib.runEffect(psys, te.pos, vector.zero, 73, 20 * (te.count or 1), cl.time)
		elseif t == qwp.TE_LIGHTNINGBLOOD then
			particleslib.runEffect(psys, te.pos, vector.zero, 225, 50, cl.time)
		elseif t == qwp.TE_EXPLOSION or t == qwp.TE_TAREXPLOSION then
			particleslib.explosion(psys, te.pos, cl.time)
			if t == qwp.TE_EXPLOSION then
				local dl = allocDlight(0, cl.time)
				dl.origin = te.pos
				dl.radius = 350
				dl.die = cl.time + 0.5
				dl.decay = 300
			end
			teSound("weapons/r_exp3.wav", te.pos)
		elseif t == qwp.TE_WIZSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 20, 30, cl.time)
			teSound("wizard/hit.wav", te.pos)
		elseif t == qwp.TE_KNIGHTSPIKE then
			particleslib.runEffect(psys, te.pos, vector.zero, 226, 20, cl.time)
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
	-- entity linking (packet entities + players + nails)
	local renderEnts: { [string]: entrender.RenderEnt } = {}
	local renderDefs: { [string]: entrender.ModelDef } = {}
	local liveKeys: { [string]: boolean } = {}
	local trailOrigins: { [string]: vector } = {}
	local gunEnt: entrender.RenderEnt? = nil
	local gunModelIndex = 0

	local function linkEnt(key: string, modelindex: number, origin: vector, angles: vector, frame: number, skinnum: number, time: number)
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
			entrender.updateAlias(re, def, origin, angles, frame, skinnum, 0, time)
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
			local angles = vector.create(-ps.viewangles.x / 3, ps.viewangles.y, 0)
			local _f, right, _u = mathlib.angleVectors(angles)
			local side = vector.dot(ps.velocity, right)
			local sign = if side < 0 then -1 else 1
			side = math.abs(side)
			local roll = (if side < 200 then side * 2.0 / 200 else 2.0) * sign * 4
			angles = vector.create(angles.x, angles.y, roll)
			linkEnt(`p{num}`, ps.modelindex, predicted[num] or ps.origin, angles, ps.frame, ps.skinnum, time)
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
	-- CalcFov: fov 90 horizontal at the real viewport aspect
	local function applyFov()
		local vp = camera.ViewportSize
		camera.FieldOfView = qcoords.calcFovY(90, vp.X, vp.Y)
	end
	applyFov()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyFov)
	input.init(0)
	input.lockMouse()
	input.setEnabled(true)

	-- direct key wiring (the NQ boot routes through its bind system;
	-- QW console/bind integration is journaled follow-up work)
	local UserInputService = game:GetService("UserInputService")
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
	local function onKey(io: InputObject, down: boolean)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			input.setButton("attack", down)
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
			table.clear(brushTemplates)
			table.clear(lightAnim)
			for key, re in renderEnts do
				entrender.destroy(re)
				renderEnts[key] = nil
				renderDefs[key] = nil
			end
			worldFolder:ClearAllChildren()
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
			qwcl.sendCmd(cl, {
				angles = viewangles,
				forwardmove = st.forwardmove,
				sidemove = st.sidemove,
				upmove = st.upmove,
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
		-- V_CalcRefdef: bob, roll, kicks, death/gib view, intermission
		-- DropPunchAngle, verbatim: punchangle -= 10*dt, clamped at 0 from
		-- below — since kicks arrive negative, a kick lasts one frame
		-- (authentic QW; the lingering NQ recoil was NetQuake behavior)
		cl.punchangle -= 10 * dt
		if cl.punchangle < 0 then
			cl.punchangle = 0
		end
		local ownState = cl.frames[bit32.band(cl.parsecount, qwp.UPDATE_MASK)].playerstate[cl.playernum]
		local eye, angles
		local gunVisible = false
		if cl.intermission ~= 0 then
			-- V_CalcIntermissionRefdef: fixed org/angles, no bob/height
			eye = cl.simorg
			angles = cl.simangles
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
			eye = cl.simorg + vector.create(0, 0, viewheight + bob)
			angles = vector.create(cl.simangles.x + cl.punchangle, cl.simangles.y, cl.simangles.z + roll)
			gunVisible = true
		end
		local fwd, right, up = mathlib.angleVectors(angles)
		camera.CFrame = qcoords.cframe(eye, fwd, right, up)

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
					gunEnt = entrender.create(def, entFolder)
				end
			end
			local ge = gunEnt
			if ge then
				local def = getModelDef(gunModel) :: entrender.ModelDef
				local gunorg = eye + fwd * (math.sqrt(cl.simvel.x * cl.simvel.x + cl.simvel.y * cl.simvel.y) * 0.02 * 0.4)
				entrender.updateAlias(ge, def, gunorg, vector.create(-angles.x, angles.y, angles.z), ownState.weaponframe, 0, 0, cl.time)
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
				print("[qw center] " .. cp:gsub("\n", " "))
			end
		end

		-- chat/print lines to the output for now (QW console follow-up)
		while #cl.prints > 0 do
			local p = table.remove(cl.prints, 1)
			if p then
				print("[qw] " .. p.text:gsub("\n$", ""))
			end
		end
	end)
end
