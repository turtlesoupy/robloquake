--!strict
-- RobloQuake client: connects the Quake client state machine to Roblox
-- rendering, input, and the QuakeNet remotes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local base64 = require(engine.common.base64)
local mathlib = require(engine.common.mathlib)
local paklib = require(engine.common.pak)
local vfslib = require(engine.common.vfs)
local bsplib = require(engine.bsp.bsp)
local mdllib = require(engine.models.mdl)
local sprlib = require(engine.models.spr)
local cllib = require(engine.client.cl)
local proto = require(engine.protocol)
local qcoords = require(engine.client.qcoords)

local entrender = require(script.render.entrender)
local particleslib = require(script.render.particles)
local textures = require(script.render.textures)
local worldmesh = require(script.render.worldmesh)
local hudlib = require(script.hud)
local soundlib = require(script.sound)
local input = require(script.input)
local viewlib = require(script.view)

--------------------------------------------------------------------------
-- filesystem from synced assets

local function loadPak(gameFolder: Instance, pakName: string): paklib.Pack?
	local pakFolder = gameFolder:FindFirstChild(pakName)
	if not pakFolder then
		return nil
	end
	local chunks = {}
	for _, child in pakFolder:GetChildren() do
		table.insert(chunks, child)
	end
	table.sort(chunks, function(a, b)
		return a.Name < b.Name
	end)
	local parts = table.create(#chunks)
	for _, chunk in chunks do
		table.insert(parts, (chunk :: StringValue).Value)
	end
	return paklib.load(`{gameFolder.Name}/{pakName}.pak`, base64.decode(table.concat(parts)))
end

local assets = ReplicatedStorage:WaitForChild("QuakeAssets")
local id1 = assets:WaitForChild("id1")
local gameDir = assets:GetAttribute("game")
if typeof(gameDir) ~= "string" then
	gameDir = "id1"
end
local gameFolder = assets:WaitForChild(gameDir)
local fs = vfslib.new()
for _, pakName in { "pak0", "pak1" } do
	local pack = loadPak(gameFolder, pakName)
	if pack then
		vfslib.addPack(fs, pack)
	end
end

local palbuf = vfslib.loadFile(fs, "gfx/palette.lmp")
assert(palbuf, "gfx/palette.lmp missing")
local pal = textures.parsePalette(palbuf)

--------------------------------------------------------------------------
-- client state

local player = Players.LocalPlayer
local c = cllib.new(player.Name, 0x04)

local net = ReplicatedStorage:WaitForChild("QuakeNet")
local reliable = net:WaitForChild("Reliable") :: RemoteEvent
local unreliable = net:WaitForChild("Unreliable") :: UnreliableRemoteEvent

local inbound: { buffer } = {}
reliable.OnClientEvent:Connect(function(data: unknown)
	if typeof(data) == "buffer" then
		table.insert(inbound, data :: buffer)
	end
end)
unreliable.OnClientEvent:Connect(function(data: unknown)
	if typeof(data) == "buffer" then
		table.insert(inbound, data :: buffer)
	end
end)

--------------------------------------------------------------------------
-- rendering state

local worldFolder = Instance.new("Folder")
worldFolder.Name = "QuakeWorld"
worldFolder.Parent = Workspace

local entFolder = Instance.new("Folder")
entFolder.Name = "QuakeEnts"
entFolder.Parent = Workspace

local hud = hudlib.create(fs, pal, player:WaitForChild("PlayerGui"))
local psys = particleslib.new(pal, Workspace)
local snd = soundlib.new(Workspace)

-- model definitions by precache index
local modelDefs: { [number]: entrender.ModelDef } = {}
-- brush submodel templates by name ("*1", ...)
local brushTemplates: { [string]: Model } = {}
local worldModels: { bsplib.Model } = {}

-- animated lightstyle vertices across all built brush geometry
local lightAnim: { worldmesh.AnimEntry } = {}
local styleValues: { [number]: number } = {}
-- water / sky textures that rewrite their images every tick
local textureAnims: { worldmesh.TextureAnim } = {}

local renderEnts: { [number]: entrender.RenderEnt } = {} -- by entity number
local staticEnts: { entrender.RenderEnt } = {}
local gunEnt: entrender.RenderEnt? = nil
local gunModelIndex = 0

local function getModelDef(modelindex: number): entrender.ModelDef?
	local def = modelDefs[modelindex]
	if def then
		return def
	end
	local name = c.model_precache[modelindex + 1]
	if not name then
		return nil
	end

	if name:sub(1, 1) == "*" then
		local sub = tonumber(name:sub(2)) :: number
		local template = brushTemplates[name]
		if not template and worldModels[sub + 1] then
			local anim
			template, anim = worldmesh.build(worldModels[sub + 1], pal, nil :: any, name)
			for _, e in anim do
				table.insert(lightAnim, e)
			end
			for _, ta in worldmesh.takeTextureAnims() do
				table.insert(textureAnims, ta)
			end
			brushTemplates[name] = template
		end
		def = { kind = "brush", flags = 0, brushModel = template }
	elseif name:sub(-4) == ".mdl" then
		local buf = vfslib.loadFile(fs, name)
		if not buf then
			def = { kind = "none", flags = 0 }
		else
			local am = mdllib.load(name, buf)
			def = { kind = "alias", alias = am, flags = am.flags }
			entrender.prepareImages(def, pal)
		end
	elseif name:sub(-4) == ".spr" then
		local buf = vfslib.loadFile(fs, name)
		if not buf then
			def = { kind = "none", flags = 0 }
		else
			def = { kind = "sprite", sprite = sprlib.load(name, buf), flags = 0 }
			entrender.prepareImages(def, pal)
		end
	elseif name:sub(-4) == ".bsp" then
		def = { kind = "none", flags = 0 } -- the world itself
	else
		def = { kind = "none", flags = 0 }
	end
	modelDefs[modelindex] = def
	return def
end

local function setEntVisible(re: entrender.RenderEnt, visible: boolean)
	local root: Instance? = re.part or re.billboardPart or re.model
	if root then
		(root :: any).Parent = if visible then entFolder else nil
	end
end

-- world load on serverinfo
c.onServerInfo = function()
	print(`[cl] serverinfo: {c.levelname}`)
	worldFolder:ClearAllChildren()
	entFolder:ClearAllChildren()
	soundlib.clear(snd)
	table.clear(modelDefs)
	table.clear(brushTemplates)
	table.clear(renderEnts)
	table.clear(staticEnts)
	gunEnt = nil
	gunModelIndex = 0

	local worldName = c.model_precache[2]
	local buf = vfslib.loadFile(fs, worldName)
	assert(buf, "world bsp missing: " .. worldName)
	worldModels = bsplib.load(worldName, buf)
	table.clear(lightAnim)
	table.clear(styleValues)
	local _world, anim = worldmesh.build(worldModels[1], pal, worldFolder, "world")
	for _, e in anim do
		table.insert(lightAnim, e)
	end
	table.clear(textureAnims)
	for _, ta in worldmesh.takeTextureAnims() do
		table.insert(textureAnims, ta)
	end
	print(`[cl] world built: {worldName} ({#lightAnim} animated light verts, {#textureAnims} animated textures)`)
end

c.print = function(s: string)
	hudlib.print(hud, s)
	print("[q] " .. s)
end
c.centerPrint = function(s: string)
	hudlib.centerPrint(hud, s, c.time)
end
c.onSetAngle = function(_c, angles)
	input.setAngles(angles)
end
c.onParticle = function(_c, org, dir, color, count)
	particleslib.runEffect(psys, org, dir, color, count, c.time)
end
c.onSound = function(_c, entnum, channel, sample, pos, vol, atten)
	soundlib.start(snd, entnum, channel, sample, pos, vol, atten)
end
c.onStaticSound = function(_c, pos, sample, vol, atten)
	soundlib.static(snd, pos, sample, vol, atten)
end

-- CL_ParseTEnt: temp entity events → particle effects; beams as brief
-- neon rods (sounds come with the audio pass)
local beamFolder = Instance.new("Folder")
beamFolder.Name = "QuakeBeams"
beamFolder.Parent = Workspace

local function spawnBeam(p1: vector, p2: vector)
	local a = qcoords.toRoblox(p1)
	local b = qcoords.toRoblox(p2)
	local len = (b - a).Magnitude
	if len < 0.1 then
		return
	end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(160, 170, 255)
	part.Size = Vector3.new(0.35, 0.35, len)
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
	part.Parent = beamFolder
	task.delay(0.12, function()
		part:Destroy()
	end)
end

c.onTempEntity = function(_c, te)
	if te.type == proto.TE_SPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 0, 10, c.time)
	elseif te.type == proto.TE_SUPERSPIKE or te.type == proto.TE_GUNSHOT then
		particleslib.runEffect(psys, te.pos, vector.zero, 0, 20, c.time)
	elseif te.type == proto.TE_EXPLOSION or te.type == proto.TE_EXPLOSION2 or te.type == proto.TE_TAREXPLOSION then
		particleslib.explosion(psys, te.pos, c.time)
	elseif te.type == proto.TE_WIZSPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 20, 30, c.time)
	elseif te.type == proto.TE_KNIGHTSPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 226, 20, c.time)
	elseif te.type == proto.TE_LAVASPLASH then
		particleslib.lavaSplash(psys, te.pos, c.time)
	elseif te.type == proto.TE_TELEPORT then
		particleslib.teleportSplash(psys, te.pos, c.time)
	elseif te.pos2 then
		spawnBeam(te.pos, te.pos2 :: vector)
	end
end
c.onDisconnect = function()
	print("[cl] disconnected")
end

--------------------------------------------------------------------------
-- camera

local camera = Workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = 75

input.init(90)
input.lockMouse()

-- announce readiness: the server connects us when it hears from us
do
	local hello = buffer.create(1)
	buffer.writeu8(hello, 0, 1) -- clc_nop
	reliable:FireServer(hello)
end

--------------------------------------------------------------------------
-- frame loop

local sendAccumulator = 0
local lastStyleFrame = -1
local diagAccumulator = 0
local statics_spawned = false

RunService.Heartbeat:Connect(function(dt: number)
	-- pump inbound messages
	if #inbound > 0 then
		local queue = inbound
		inbound = {}
		for _, data in queue do
			local ok, err = pcall(cllib.parseServerMessage, c, data)
			if not ok then
				warn("[cl] parse error: " .. tostring(err))
			end
		end
		-- flush any signon replies
		local rel = cllib.takeReliable(c)
		if rel then
			reliable:FireServer(rel)
		end
	end

	if c.signon < cllib.SIGNONS then
		return
	end

	-- clock
	c.oldtime = c.time
	c.time += dt

	-- input → viewangles → move packet (throttled to ~72Hz like NetQuake)
	c.viewangles = input.viewangles()
	sendAccumulator += dt
	if sendAccumulator >= 1 / 72 then
		sendAccumulator = 0
		local st = input.sample()
		local move = cllib.buildMove(c, st.forwardmove, st.sidemove, st.upmove, st.attack, st.jump, st.impulse)
		if move then
			unreliable:FireServer(move)
		end
		local rel = cllib.takeReliable(c)
		if rel then
			reliable:FireServer(rel)
		end
	end

	-- interpolate entities
	cllib.relinkEntities(c, function(mi: number): number
		local def = getModelDef(mi)
		return if def then def.flags else 0
	end)

	-- R_AnimateLight: lightstyle values tick at 10Hz from the style strings
	local styleFrame = math.floor(c.time * 10)
	if styleFrame ~= lastStyleFrame and #lightAnim > 0 then
		lastStyleFrame = styleFrame
		workspace:SetAttribute("RQ_LightTick", styleFrame)
		for _, ta in textureAnims do
			if ta.kind == "turb" then
				textures.writeTurbFrame(ta.img, ta.pixels, ta.w, ta.h, pal, c.time)
			else
				textures.writeSkyFrame(ta.img, ta.pixels, ta.w, ta.h, pal, c.time)
			end
		end
		local changed: { [number]: boolean } = {}
		for style, map in c.lightstyles do
			local value
			if #map == 0 then
				value = 256
			else
				value = (map:byte(styleFrame % #map + 1) - 97) * 22 -- 'a'
			end
			if styleValues[style] ~= value then
				styleValues[style] = value
				changed[style] = true
			end
		end
		local function styleValue(style: number): number
			return styleValues[style] or worldmesh.BASE_STYLE_VALUE
		end
		for _, entry in lightAnim do
			local dirty = false
			for _, sv in entry.layers do
				if changed[sv[1]] then
					dirty = true
					break
				end
			end
			if dirty then
				local light = worldmesh.combineLight(entry.layers, styleValue)
				entry.em:SetColor(entry.cid, Color3.new(light, light, light))
			end
		end
	end

	-- statics (once, after signon)
	if not statics_spawned and #c.statics > 0 then
		statics_spawned = true
		for _, se in c.statics do
			local def = getModelDef(se.modelindex)
			if def and def.kind ~= "none" then
				local re = entrender.create(def, entFolder)
				if re then
					if re.kind == "alias" then
						entrender.updateAlias(re, def, se.origin, se.angles, se.frame, se.skinnum, se.syncbase, c.time)
					elseif re.kind == "sprite" then
						entrender.updateSprite(re, def, se.origin, se.frame)
					elseif re.kind == "brush" then
						entrender.updateBrush(re, se.origin, se.angles)
					end
					table.insert(staticEnts, re)
				end
			end
		end
	end

	-- update dynamic entities
	for num = 1, c.num_entities - 1 do
		local e = c.entities[num]
		local re = renderEnts[num]

		local shouldDraw = e ~= nil and e.visible and e.modelindex ~= 0 and num ~= c.viewentity

		if not shouldDraw then
			if re then
				setEntVisible(re, false)
			end
			continue
		end

		-- recreate on model change
		if re and re.modelindex ~= e.modelindex then
			entrender.destroy(re)
			renderEnts[num] = nil
			re = nil
		end
		if not re then
			local def = getModelDef(e.modelindex)
			if not def or def.kind == "none" then
				continue
			end
			re = entrender.create(def, entFolder)
			if not re then
				continue
			end
			re.modelindex = e.modelindex
			renderEnts[num] = re
		end
		setEntVisible(re :: entrender.RenderEnt, true)

		local def = getModelDef(e.modelindex) :: entrender.ModelDef
		local rr = re :: entrender.RenderEnt
		if rr.kind == "alias" then
			local colors: number? = nil
			if e.colormap > 0 and e.colormap <= c.maxclients and c.scores[e.colormap] then
				colors = c.scores[e.colormap].colors
			end
			entrender.updateAlias(rr, def, e.origin, e.angles, e.frame, e.skinnum, e.syncbase, c.time, colors)
		elseif rr.kind == "sprite" then
			entrender.updateSprite(rr, def, e.origin, e.frame)
		elseif rr.kind == "brush" then
			entrender.updateBrush(rr, e.origin, e.angles)
		end
	end

	-- view / camera
	local refdef = viewlib.calcRefdef(c, dt)
	local forward, right, up = mathlib.angleVectors(refdef.viewangles)
	camera.CFrame = qcoords.cframe(refdef.vieworg, forward, right, up)

	-- view weapon
	if refdef.gunmodel ~= 0 and c.stats[cllib.STAT_HEALTH] > 0 and c.intermission == 0 then
		if gunModelIndex ~= refdef.gunmodel then
			if gunEnt then
				entrender.destroy(gunEnt)
				gunEnt = nil
			end
			gunModelIndex = refdef.gunmodel
			local def = getModelDef(refdef.gunmodel)
			if def and def.kind == "alias" then
				gunEnt = entrender.create(def, entFolder)
			end
		end
		local ge = gunEnt
		if ge then
			local def = getModelDef(refdef.gunmodel) :: entrender.ModelDef
			entrender.updateAlias(ge, def, refdef.gunorg, refdef.gunangles, refdef.gunframe, 0, 0, c.time)
		end
	elseif gunEnt then
		setEntVisible(gunEnt, false)
	end

	-- particles
	particleslib.update(psys, c.time, dt)

	-- hud
	hudlib.update(hud, c)

	-- diagnostics for external verification
	diagAccumulator += dt
	if diagAccumulator > 0.5 then
		diagAccumulator = 0
		local e = c.entities[c.viewentity]
		local visible = 0
		for i = 1, c.num_entities - 1 do
			if c.entities[i] and c.entities[i].visible then
				visible += 1
			end
		end
		workspace:SetAttribute("RQ_Signon", c.signon)
		workspace:SetAttribute("RQ_Time", c.time)
		workspace:SetAttribute("RQ_Health", c.stats[cllib.STAT_HEALTH])
		workspace:SetAttribute("RQ_Shells", c.stats[cllib.STAT_SHELLS])
		workspace:SetAttribute("RQ_VisEnts", visible)
		if e then
			workspace:SetAttribute("RQ_Origin", qcoords.toRoblox(e.origin))
		end
	end
end)

print("[robloquake] client ready")
