--!strict
-- RobloQuake client: connects the Quake client state machine to Roblox
-- rendering, input, and the QuakeNet remotes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local mathlib = require(engine.common.mathlib)
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
local consolelib = require(script.console)
local hudlib = require(script.hud)
local lightpoint = require(script.render.lightpoint)
local menulib = require(script.menu)
local soundlib = require(script.sound)
local input = require(script.input)
local viewlib = require(script.view)

--------------------------------------------------------------------------
-- filesystem from the server-published client bundle (gfx + precached
-- models + current map); the full paks stay server-side

local clientAssets = ReplicatedStorage:WaitForChild("QuakeClientFS")
while clientAssets:GetAttribute("ready") ~= true do
	clientAssets.AttributeChanged:Wait()
end
local fs = vfslib.new()
vfslib.addFolderSource(fs, clientAssets)

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

local playerGui = player:WaitForChild("PlayerGui")
local hud = hudlib.create(fs, pal, playerGui)
local psys = particleslib.new(pal, Workspace)
local snd = soundlib.new(Workspace)

-- console + menu live on their own gui above the hud
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "QuakeOverlay"
overlayGui.IgnoreGuiInset = true
overlayGui.DisplayOrder = 20
overlayGui.ResetOnSpawn = false
overlayGui.Parent = playerGui

-- fullscreen palette-flash tint (V_UpdatePalette)
local cshiftFrame = Instance.new("Frame")
cshiftFrame.Name = "cshift"
cshiftFrame.BorderSizePixel = 0
cshiftFrame.Size = UDim2.new(1, 0, 1, 0)
cshiftFrame.BackgroundTransparency = 1
cshiftFrame.ZIndex = 1
cshiftFrame.Parent = overlayGui

local con = consolelib.create(fs, pal, overlayGui)
local mnu = menulib.create(fs, pal, overlayGui)

-- SCR_DrawCrosshair: the conchars '+' glyph drawn with its top-left at the
-- centre of the 3d view (the screen minus the 48-line status bar), gated by
-- the crosshair cvar. WinQuake defaults it off; we default on.
local confontlib = require(script.render.confont)
local crosshairLabel = Instance.new("ImageLabel")
crosshairLabel.Name = "crosshair"
crosshairLabel.BackgroundTransparency = 1
crosshairLabel.ResampleMode = Enum.ResamplerMode.Pixelated
crosshairLabel.Size = UDim2.fromOffset(8 * 2, 8 * 2)
crosshairLabel.Position = UDim2.new(0.5, 0, 0.5, -48)
crosshairLabel.ZIndex = 0 -- under the console/menu
do
	local img = confontlib.glyph(con.font, string.byte("+"))
	if img then
		crosshairLabel.ImageContent = Content.fromObject(img)
	end
end
crosshairLabel.Parent = overlayGui

-- (Roblox CoreGui overlays stay enabled by request)

-- model definitions by precache index
local modelDefs: { [number]: entrender.ModelDef } = {}
-- brush submodel templates by name ("*1", ...)
local brushTemplates: { [string]: Model } = {}
local worldModels: { bsplib.Model } = {}

-- animated lightstyle vertices across all built brush geometry
local lightAnim: { worldmesh.AnimEntry } = {}
local styleValues: { [number]: number } = {}
local function styleValueFor(style: number): number
	return styleValues[style] or worldmesh.BASE_STYLE_VALUE
end
-- water / sky textures that rewrite their images every tick
local textureAnims: { worldmesh.TextureAnim } = {}

-- cl_dlights (CL_AllocDlight / CL_DecayLights)
local lightatlaslib = require(script.render.lightatlas)
local MAX_DLIGHTS = 32
local dlights: { lightatlaslib.Dlight } = {}
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

-- lightning beam state (CL_ParseBeam)
local MAX_BEAMS = 24
type Beam = { modelName: string, entity: number, startPos: vector, endPos: vector, endtime: number }
local beams: { Beam? } = {}
local beamDefs: { [string]: any } = {}
local beamPool: { [string]: { entrender.RenderEnt } } = {}


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
		local buf = vfslib.loadFile(fs, name, true)
		if not buf then
			def = { kind = "none", flags = 0 }
		else
			local am = mdllib.load(name, buf)
			def = { kind = "alias", alias = am, flags = am.flags }
			entrender.prepareImages(def, pal)
		end
	elseif name:sub(-4) == ".spr" then
		local buf = vfslib.loadFile(fs, name, true)
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
local loadingUp = 0 -- 1 = loading, 2 = built, awaiting first rendered frame
c.onServerInfo = function()
	print(`[cl] serverinfo: {c.levelname}`)
	-- SCR_BeginLoadingPlaque: sounds stop, notify/centerprints clear, the
	-- loading plaque holds until the first rendered frame of the new level
	loadingUp = 1
	hudlib.setLoading(hud, true)
	worldFolder:ClearAllChildren()
	entFolder:ClearAllChildren()
	soundlib.clear(snd)
	table.clear(modelDefs)
	table.clear(brushTemplates)
	table.clear(renderEnts)
	table.clear(staticEnts)
	gunEnt = nil
	gunModelIndex = 0
	table.clear(beams)
	table.clear(beamDefs)
	table.clear(beamPool)

	local worldName = c.model_precache[2]
	local buf = vfslib.loadFile(fs, worldName, true)
	assert(buf, "world bsp missing: " .. worldName)
	worldModels = bsplib.load(worldName, buf)
	table.clear(lightAnim)
	table.clear(styleValues)
	table.clear(dlights)
	worldmesh.resetLighting(styleValueFor)
	local _world, anim = worldmesh.build(worldModels[1], pal, worldFolder, "world")
	for _, e in anim do
		table.insert(lightAnim, e)
	end
	table.clear(textureAnims)
	for _, ta in worldmesh.takeTextureAnims() do
		table.insert(textureAnims, ta)
	end
	print(`[cl] world built: {worldName} ({#textureAnims} animated textures)`)
	loadingUp = 2
end

c.print = function(s: string)
	hudlib.print(hud, s, c.time)
	consolelib.print(con, s)
	print("[q] " .. s)
end

-- console command execution: a few local commands, everything else is
-- forwarded to the server like Cmd_ForwardToServer
local function sendStringCmd(line: string)
	local buf = buffer.create(#line + 2)
	buffer.writeu8(buf, 0, 4) -- clc_stringcmd
	buffer.writestring(buf, 1, line)
	buffer.writeu8(buf, 1 + #line, 0)
	reliable:FireServer(buf)
end

con.onCommand = function(line: string)
	local cmd, args = line:match("^(%S+)%s*(.*)$")
	if not cmd then
		return
	end
	cmd = cmd:lower()
	if cmd == "clear" then
		table.clear(con.lines)
	elseif cmd == "sensitivity" then
		local v = tonumber(args)
		if v then
			input.setSensitivity(v)
			consolelib.print(con, `"sensitivity" is "{v}"`)
		end
	elseif cmd == "impulse" then
		input.setImpulse(tonumber(args) or 0)
	elseif cmd == "crosshair" then
		local v = tonumber(args)
		if v then
			crosshairLabel.Visible = v ~= 0
			consolelib.print(con, `"crosshair" is "{v}"`)
		end
	elseif cmd == "toggleconsole" then
		consolelib.toggle(con)
	elseif cmd == "version" then
		consolelib.print(con, "robloquake — WinQuake 1.09 port")
	else
		sendStringCmd(line)
	end
end

mnu.onNewGame = function()
	sendStringCmd("map start")
end
mnu.onQuit = function()
	consolelib.print(con, "use the Roblox menu to leave the experience")
end
mnu.print = function(s: string)
	consolelib.print(con, s)
	hudlib.print(hud, s, c.time)
end
c.centerPrint = function(s: string)
	hudlib.centerPrint(hud, s, c.time)
end
c.onSetAngle = function(_c, angles)
	input.setAngles(angles)
end
c.onStuffText = function(_c, text)
	-- QC stuffs console commands at the client; "bf" is the bonus flash
	for line in text:gmatch("[^\n;]+") do
		if line == "bf" then
			c.cshift_bonus_percent = 50
		end
	end
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
-- CL_ParseBeam / CL_UpdateTEnts: lightning renders as chains of the real
-- bolt models, one segment every 30 units, random roll per segment
local function beamModelDef(name: string): entrender.ModelDef?
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
	return if def then def :: entrender.ModelDef else nil
end

local function parseBeam(modelName: string, te: cllib.TempEntityEvent)
	local entity = te.entity or 0
	local endPos = te.pos2 :: vector
	-- override any beam with the same entity
	if entity ~= 0 then
		for i = 1, MAX_BEAMS do
			local b = beams[i]
			if b and b.entity == entity then
				b.modelName = modelName
				b.startPos = te.pos
				b.endPos = endPos
				b.endtime = c.time + 0.2
				return
			end
		end
	end
	for i = 1, MAX_BEAMS do
		local b = beams[i]
		if not b or b.endtime < c.time then
			beams[i] = { modelName = modelName, entity = entity, startPos = te.pos, endPos = endPos, endtime = c.time + 0.2 }
			return
		end
	end
end

local function updateBeams()
	local used: { [string]: number } = {}
	for i = 1, MAX_BEAMS do
		local b = beams[i]
		if b and b.endtime >= c.time then
			-- if coming from the player, track the player origin
			if b.entity == c.viewentity then
				local pe = c.entities[c.viewentity]
				if pe then
					b.startPos = pe.origin
				end
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
					setEntVisible(re, true)
					entrender.updateAlias(re, def, org, vector.create(pitch, yaw, math.random(0, 359)), 0, 0, 0, c.time)
					entrender.setLight(re, 255)
					org += dir * 30
					d -= 30
					if n >= 40 then
						break
					end
				end
			end
		end
	end
	for name, pool in beamPool do
		for i = (used[name] or 0) + 1, #pool do
			setEntVisible(pool[i], false)
		end
	end
end

-- R_ParseTEnt: impact sounds are client-side in NetQuake (the QC r_exp3
-- call is commented out in the shipped progs); entity -1 = world sounds
local function teSound(sample: string, pos: vector)
	soundlib.start(snd, -1, 0, sample, pos, 1, 1)
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

c.onTempEntity = function(_c, te)
	if te.type == proto.TE_SPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 0, 10, c.time)
		spikeSound(te.pos)
	elseif te.type == proto.TE_SUPERSPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 0, 20, c.time)
		spikeSound(te.pos)
	elseif te.type == proto.TE_GUNSHOT then
		particleslib.runEffect(psys, te.pos, vector.zero, 0, 20, c.time)
	elseif te.type == proto.TE_EXPLOSION or te.type == proto.TE_EXPLOSION2 or te.type == proto.TE_TAREXPLOSION then
		particleslib.explosion(psys, te.pos, c.time)
		if te.type ~= proto.TE_TAREXPLOSION then
			local dl = allocDlight(0, c.time)
			dl.origin = te.pos
			dl.radius = 350
			dl.die = c.time + 0.5
			dl.decay = 300
		end
		teSound("weapons/r_exp3.wav", te.pos)
	elseif te.type == proto.TE_WIZSPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 20, 30, c.time)
		teSound("wizard/hit.wav", te.pos)
	elseif te.type == proto.TE_KNIGHTSPIKE then
		particleslib.runEffect(psys, te.pos, vector.zero, 226, 20, c.time)
		teSound("hknight/hit.wav", te.pos)
	elseif te.type == proto.TE_LAVASPLASH then
		particleslib.lavaSplash(psys, te.pos, c.time)
	elseif te.type == proto.TE_TELEPORT then
		particleslib.teleportSplash(psys, te.pos, c.time)
	elseif te.type == proto.TE_LIGHTNING1 then
		parseBeam("progs/bolt.mdl", te)
	elseif te.type == proto.TE_LIGHTNING2 then
		parseBeam("progs/bolt2.mdl", te)
	elseif te.type == proto.TE_LIGHTNING3 then
		parseBeam("progs/bolt3.mdl", te)
	elseif te.type == proto.TE_BEAM then
		parseBeam("progs/beam.mdl", te)
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

local UserInputService = game:GetService("UserInputService")

local function refreshInputMode()
	local uiOpen = con.open or menulib.isOpen(mnu)
	input.setEnabled(not uiOpen)
end

-- console text entry straight from key codes (no TextBox: Roblox chat and
-- CoreGui focus never get involved). GetStringForKeyCode gives the layout
-- character; shifted punctuation mapped for US layouts.
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

-- debug hook: drive the console remotely (verification without keypresses)
local dbgConsole = Instance.new("BindableFunction")
dbgConsole.Name = "RQDBG_Console"
dbgConsole.Parent = workspace
local lastKeyInfo = ""

local function consoleKey(key: Enum.KeyCode)
	local fake = { KeyCode = key, UserInputType = Enum.UserInputType.Keyboard }
	if consolelib.handleKey(con, fake :: any) then
		local shifted = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local ch = keyToChar(key, shifted)
		lastKeyInfo = ("key=%s char=%s"):format(key.Name, tostring(ch))
		if ch then
			consolelib.handleText(con, ch)
		end
	end
end

dbgConsole.OnInvoke = function(action: string, arg: string?)
	if action == "toggle" then
		consolelib.toggle(con)
		refreshInputMode()
		return tostring(con.open)
	elseif action == "isopen" then
		return tostring(con.open)
	elseif action == "exec" then
		-- run command(s) directly, independent of console open state
		for piece in (arg :: string):gmatch("[^;]+") do
			local trimmed = piece:match("^%s*(.-)%s*$")
			if trimmed ~= "" then
				con.onCommand(trimmed)
			end
		end
		return "ok"
	elseif action == "key" then
		consoleKey((Enum.KeyCode :: any)[arg])
		return con.inputText
	elseif action == "text" then
		return con.inputText
	elseif action == "lastkey" then
		return lastKeyInfo
	elseif action == "lines" then
		return table.concat(con.lines, "\n")
	end
	return ""
end

UserInputService.InputBegan:Connect(function(io: InputObject, _processed: boolean)
	if io.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = io.KeyCode
	lastKeyInfo = ("raw key=%s processed=%s conOpen=%s"):format(key.Name, tostring(_processed), tostring(con.open))

	-- tilde/backquote toggles the console from anywhere
	if key == Enum.KeyCode.Backquote or key == Enum.KeyCode.Tilde then
		consolelib.toggle(con)
		refreshInputMode()
		return
	end

	if con.open then
		consoleKey(key)
		return
	end

	-- the Quake menu lives on M (Escape is reserved by Roblox for its own menu)
	if key == Enum.KeyCode.M and not menulib.isOpen(mnu) then
		menulib.toggle(mnu)
		refreshInputMode()
		return
	end
	if menulib.isOpen(mnu) then
		menulib.handleKey(mnu, io)
		refreshInputMode()
		return
	end
end)

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
	if styleFrame ~= lastStyleFrame then
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
		if next(changed) then
			worldmesh.updateLightStyles(changed)
		end
	end

	-- CL_DecayLights + the dynamic light surface pass
	do
		local active: { lightatlaslib.Dlight } = {}
		for _, dl in dlights do
			if dl.die >= c.time and dl.radius > 0 then
				dl.radius -= dt * dl.decay
				if dl.radius > 0 then
					table.insert(active, dl)
				end
			end
		end
		if worldModels[1] then
			worldmesh.updateDlights(worldModels[1].brush, active)
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
			-- R_AliasSetupLighting: dynamic lights add straight onto the
			-- lightmap sample
			local elight = lightpoint.at(worldModels[1], e.origin, styleValueFor)
			for _, dl in dlights do
				if dl.die >= c.time and dl.radius > 0 then
					local add = dl.radius - vector.magnitude(e.origin - dl.origin)
					if add > 0 then
						elight += add
					end
				end
			end
			entrender.setLight(rr, elight)

			-- CL_RelinkEntities: entity effects become dynamic lights
			if bit32.band(e.effects, 2) ~= 0 then -- EF_MUZZLEFLASH
				local dl = allocDlight(num, c.time)
				local fv = mathlib.angleVectors(e.angles)
				dl.origin = e.origin + vector.create(0, 0, 16) + fv * 18
				dl.radius = 200 + math.random(0, 31)
				dl.minlight = 32
				dl.die = c.time + 0.1
			end
			if bit32.band(e.effects, 4) ~= 0 then -- EF_BRIGHTLIGHT
				local dl = allocDlight(num, c.time)
				dl.origin = e.origin + vector.create(0, 0, 16)
				dl.radius = 400 + math.random(0, 31)
				dl.die = c.time + 0.001
			end
			if bit32.band(e.effects, 8) ~= 0 then -- EF_DIMLIGHT
				local dl = allocDlight(num, c.time)
				dl.origin = e.origin
				dl.radius = 200 + math.random(0, 31)
				dl.die = c.time + 0.001
			end

			-- CL_RelinkEntities: model-flag particle trails (rockets, smoke,
			-- gibs, tracers) from last frame's origin to this one
			local mflags = def.flags
			if mflags ~= 0 then
				local oldorg = (rr :: any).trailOrg or e.origin
				if oldorg ~= e.origin then
					if bit32.band(mflags, 4) ~= 0 then -- EF_GIB
						particleslib.rocketTrail(psys, oldorg, e.origin, 2, c.time)
					elseif bit32.band(mflags, 32) ~= 0 then -- EF_ZOMGIB
						particleslib.rocketTrail(psys, oldorg, e.origin, 4, c.time)
					elseif bit32.band(mflags, 16) ~= 0 then -- EF_TRACER
						particleslib.rocketTrail(psys, oldorg, e.origin, 3, c.time)
					elseif bit32.band(mflags, 64) ~= 0 then -- EF_TRACER2
						particleslib.rocketTrail(psys, oldorg, e.origin, 5, c.time)
					elseif bit32.band(mflags, 1) ~= 0 then -- EF_ROCKET
						particleslib.rocketTrail(psys, oldorg, e.origin, 0, c.time)
						local dl = allocDlight(num, c.time)
						dl.origin = e.origin
						dl.radius = 200
						dl.die = c.time + 0.01
					elseif bit32.band(mflags, 2) ~= 0 then -- EF_GRENADE
						particleslib.rocketTrail(psys, oldorg, e.origin, 1, c.time)
					elseif bit32.band(mflags, 128) ~= 0 then -- EF_TRACER3
						particleslib.rocketTrail(psys, oldorg, e.origin, 6, c.time)
					end
				end
			end;
			(rr :: any).trailOrg = e.origin
		elseif rr.kind == "sprite" then
			entrender.updateSprite(rr, def, e.origin, e.frame)
		elseif rr.kind == "brush" then
			entrender.updateBrush(rr, e.origin, e.angles)
		end
	end

	-- CL_UpdateTEnts: lightning beam segments
	updateBeams()

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
			-- R_DrawViewModel: "allways give some light on gun"
			local glight = lightpoint.at(worldModels[1], refdef.vieworg, styleValueFor)
			for _, dl in dlights do
				if dl.die >= c.time and dl.radius > 0 then
					local add = dl.radius - vector.magnitude(refdef.vieworg - dl.origin)
					if add > 0 then
						glight += add
					end
				end
			end
			entrender.setLight(ge, math.max(glight, 24))
		end
	elseif gunEnt then
		setEntVisible(gunEnt, false)
	end

	-- particles
	particleslib.update(psys, c.time, dt)

	if loadingUp == 2 then
		loadingUp = 0
		hudlib.setLoading(hud, false)
	end
	hudlib.setPaused(hud, c.paused == true)

	-- console / menu overlays
	consolelib.update(con, c.time)
	menulib.update(mnu, c.time)

	-- V_UpdatePalette: decay + blend the palette flashes into the tint frame
	c.cshift_damage_percent = math.max(c.cshift_damage_percent - dt * 150, 0)
	c.cshift_bonus_percent = math.max(c.cshift_bonus_percent - dt * 100, 0)

	local shifts: { { number } } = {} -- {r,g,b,percent}
	local viewLeaf = bsplib.pointInLeaf(refdef.vieworg, worldModels[1])
	do
		-- contents shift from the view leaf (V_SetContentsColor)
		local cont = viewLeaf.contents
		if cont == -3 then -- water
			table.insert(shifts, { 130, 80, 50, 128 })
		elseif cont == -4 then -- slime
			table.insert(shifts, { 0, 25, 5, 150 })
		elseif cont == -5 then -- lava
			table.insert(shifts, { 255, 80, 0, 150 })
		end
	end
	-- S_UpdateAmbientSounds: leaf-based water/sky ambience
	soundlib.updateAmbients(snd, viewLeaf.ambient, dt)
	-- powerups (V_CalcPowerupCshift; quad wins over suit/ring/pent like the C)
	if bit32.band(c.items, 2097152) ~= 0 then -- IT_QUAD
		table.insert(shifts, { 0, 0, 255, 30 })
	elseif bit32.band(c.items, 1048576) ~= 0 then -- IT_SUIT
		table.insert(shifts, { 0, 255, 0, 20 })
	elseif bit32.band(c.items, 524288) ~= 0 then -- IT_INVISIBILITY
		table.insert(shifts, { 100, 100, 100, 100 })
	elseif bit32.band(c.items, 4194304) ~= 0 then -- IT_INVULNERABILITY
		table.insert(shifts, { 255, 255, 0, 30 })
	end
	if c.cshift_damage_percent > 0 then
		local dc = c.cshift_damage_color
		table.insert(shifts, { dc.x, dc.y, dc.z, c.cshift_damage_percent })
	end
	if c.cshift_bonus_percent > 0 then
		table.insert(shifts, { 215, 186, 69, c.cshift_bonus_percent })
	end

	if #shifts > 0 then
		local r, g, b, a = 0, 0, 0, 0
		for _, sh in shifts do
			local a2 = math.clamp(sh[4], 0, 255) / 255
			a = a + a2 * (1 - a)
			if a > 0 then
				local w2 = a2 / a
				r = r * (1 - w2) + sh[1] * w2
				g = g * (1 - w2) + sh[2] * w2
				b = b * (1 - w2) + sh[3] * w2
			end
		end
		cshiftFrame.BackgroundColor3 = Color3.fromRGB(r, g, b)
		cshiftFrame.BackgroundTransparency = 1 - math.min(a, 0.85)
	else
		cshiftFrame.BackgroundTransparency = 1
	end

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
