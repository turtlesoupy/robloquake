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

local entrender = require(script.Parent.render.entrender)
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

	local styleValues: { [number]: number } = {}
	local function styleValueFor(style: number): number
		return styleValues[style] or worldmesh.BASE_STYLE_VALUE
	end

	local lightAnim: { worldmesh.AnimEntry } = {}
	local modelDefs: { [number]: entrender.ModelDef } = {}
	local brushTemplates: { [string]: Model } = {}
	local worldBuilt = false

	-- model defs come straight from qwcl's loaded models (modellist)
	local function getModelDef(modelindex: number): entrender.ModelDef?
		local def = modelDefs[modelindex]
		if def then
			return def
		end
		local m = cl.models[modelindex + 1]
		local name = cl.model_name[modelindex + 1]
		if not m or not name then
			return nil
		end
		if m.kind == "alias" then
			def = { kind = "alias" :: "alias", alias = m.alias, flags = m.alias.flags }
			entrender.prepareImages(def, pal)
		elseif m.kind == "sprite" then
			def = { kind = "sprite" :: "sprite", sprite = m.sprite, flags = 0 }
			entrender.prepareImages(def, pal)
		elseif m.kind == "brush" and name:sub(1, 1) == "*" then
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
		-- statics (svc_spawnstatic)
		for _, es in cl.static_entities do
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
		for _, ss in cl.static_sounds do
			local name = cl.sound_name[ss.num]
			if name then
				soundlib.static(sndsys, ss.pos, name, ss.vol / 255, ss.atten)
			end
		end
		print(`[robloquake] qw world built: {cl.levelname}`)
	end

	----------------------------------------------------------------------
	-- entity linking (packet entities + players + nails)
	local renderEnts: { [string]: entrender.RenderEnt } = {}
	local renderDefs: { [string]: entrender.ModelDef } = {}
	local liveKeys: { [string]: boolean } = {}

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
		end

		-- players from playerinfo (self is drawn by the camera instead)
		for num, ps in frame.playerstate do
			if ps.messagenum ~= cl.parsecount or num == cl.playernum then
				continue
			end
			local angles = vector.create(-ps.viewangles.x / 3, ps.viewangles.y, 0)
			linkEnt(`p{num}`, ps.modelindex, ps.origin, angles, ps.frame, ps.skinnum, time)
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
	input.init(0)
	input.lockMouse()
	input.setEnabled(true)

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
		buildWorld()
		if not worldBuilt then
			return
		end

		-- find the spike model index once for nail rendering
		if not cl.spikeindex then
			for i, name in cl.model_name do
				if name == "progs/spike.mdl" then
					cl.spikeindex = i - 1
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
		local msec = math.clamp(math.floor(accum * 1000), 0, 250)
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
		local eye = cl.simorg + vector.create(0, 0, viewheight)
		local fwd, right, up = mathlib.angleVectors(cl.simangles)
		camera.CFrame = qcoords.cframe(eye, fwd, right, up)

		relinkEntities(cl.time)
		updateLightstyles(cl.realtime)

		-- sounds
		for i = sndDrained + 1, #cl.sounds do
			local snd = cl.sounds[i]
			local name = cl.sound_name[snd.num]
			if name and snd.num >= 0 then
				soundlib.start(sndsys, snd.ent, snd.channel, name, snd.pos, snd.vol / 255, snd.atten)
			end
		end
		sndDrained = #cl.sounds
		if sndDrained > 512 then
			table.clear(cl.sounds)
			sndDrained = 0
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
