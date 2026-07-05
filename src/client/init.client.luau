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
local lightpoint = require(engine.client.lightpoint)
local menulib = require(script.menu)
local soundlib = require(script.sound)
local input = require(script.input)
local viewlib = require(engine.client.view)
local viewmodellib = require(script.render.viewmodel)

--------------------------------------------------------------------------
-- filesystem from the server-published client bundle (gfx + precached
-- models + current map); the full paks stay server-side

local clientAssets = ReplicatedStorage:WaitForChild("QuakeClientFS")
while clientAssets:GetAttribute("ready") ~= true do
	clientAssets.AttributeChanged:Wait()
end

-- engine selection mirrors the server: campaign/coop places boot the
-- NetQuake client below; competitive places (engine="qw") boot QuakeWorld
if clientAssets:GetAttribute("engine") == "qw" then
	require(script.qwclient)()
	return
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

-- Cmd_ForwardToServer
local function sendStringCmd(line: string)
	local buf = buffer.create(#line + 2)
	buffer.writeu8(buf, 0, 4) -- clc_stringcmd
	buffer.writestring(buf, 1, line)
	buffer.writeu8(buf, 1 + #line, 0)
	reliable:FireServer(buf)
end

-- demo state (cl_demo.c); helpers live near the console commands
local demoPlaying = false
local demoBuf: buffer? = nil
local demoPos = 0
local demoRecording: { string }? = nil
local demoName = ""
local recordedDemos: { [string]: buffer } = {}
local playDemo: (name: string) -> () = function() end
local stopDemo: (msgText: string?) -> () = function() end
local demoFrame: () -> () = function() end

-- ask the server to publish a pak file into the client bundle, then the
-- folder-source loadFile(..., true) waits out replication
local function demandFile(name: string)
	if not clientAssets:FindFirstChild(name) then
		sendStringCmd("rq_need " .. name)
	end
end

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
local vmgun = viewmodellib.new(playerGui)
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
local staticEnts: { { re: entrender.RenderEnt, se: any, def: entrender.ModelDef } } = {}
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
		demandFile(name)
		local buf = vfslib.loadFile(fs, name, true)
		if not buf then
			def = { kind = "none", flags = 0 }
		else
			local am = mdllib.load(name, buf)
			def = { kind = "alias", alias = am, flags = am.flags }
			entrender.prepareImages(def, pal)
		end
	elseif name:sub(-4) == ".spr" then
		demandFile(name)
		local buf = vfslib.loadFile(fs, name, true)
		if not buf then
			def = { kind = "none", flags = 0 }
		else
			def = { kind = "sprite", sprite = sprlib.load(name, buf), flags = 0 }
			entrender.prepareImages(def, pal)
		end
	elseif name:sub(-4) == ".bsp" then
		if modelindex == 1 then
			def = { kind = "none", flags = 0 } -- the world itself
		else
			-- standalone brush models: ammo/health boxes (b_*.bsp)
			demandFile(name)
			local buf = vfslib.loadFile(fs, name, true)
			local template = brushTemplates[name]
			if not template and buf then
				local models = bsplib.load(name, buf)
				local anim
				template, anim = worldmesh.build(models[1], pal, nil :: any, name)
				for _, e in anim do
					table.insert(lightAnim, e)
				end
				for _, ta in worldmesh.takeTextureAnims() do
					table.insert(textureAnims, ta)
				end
				brushTemplates[name] = template
			end
			if template then
				def = { kind = "brush", flags = 0, brushModel = template }
			else
				def = { kind = "none", flags = 0 }
			end
		end
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
local worldBuildGen = 0 -- guards the deferred world build against fast changelevels
c.onServerInfo = function()
	print(`[cl] serverinfo: {c.levelname}`)
	-- SCR_BeginLoadingPlaque: sounds stop, notify/centerprints clear, the
	-- loading plaque holds until the first rendered frame of the new level
	loadingUp = 1
	hudlib.setLoading(hud, true)
	-- release every mesh from the old level SYNCHRONOUSLY. Destroying
	-- signals are deferred, so ClearAllChildren alone would still hold the
	-- EditableMesh budget while the new world builds below — starving it
	-- into skipped batches (holes in the world). Brush templates are
	-- unparented and render ents own fixed alias meshes, so both leak
	-- outright without an explicit destroy.
	for _, child in worldFolder:GetChildren() do
		worldmesh.destroyBuild(child)
	end
	for _, tpl in brushTemplates do
		worldmesh.destroyBuild(tpl)
	end
	for _, re in renderEnts do
		entrender.destroy(re)
	end
	for _, st in staticEnts do
		entrender.destroy(st.re)
	end
	if gunEnt then
		entrender.destroy(gunEnt)
	end
	for _, pool in beamPool do
		for _, re in pool do
			entrender.destroy(re)
		end
	end
	entFolder:ClearAllChildren()
	soundlib.clear(snd)
	for _, def in modelDefs do
		entrender.destroyDef(def)
	end
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
	demandFile(worldName)
	local buf = vfslib.loadFile(fs, worldName, true)
	assert(buf, "world bsp missing: " .. worldName)
	worldModels = bsplib.load(worldName, buf)
	table.clear(lightAnim)
	-- the old anim images were just destroyed synchronously above; stop
	-- the 10Hz pump from writing to them during the one-frame build gap
	table.clear(textureAnims)
	table.clear(styleValues)
	table.clear(dlights)
	worldmesh.resetLighting(styleValueFor)
	-- build the render world OUTSIDE the parse path, one frame later: the
	-- engine reclaims destroyed fixed-mesh budget asynchronously, so a
	-- same-frame rebuild starves into skipped batches (holes in the
	-- world). onServerInfo itself must not yield — the rest of the signon
	-- buffer parses right after it returns.
	worldBuildGen += 1
	local gen = worldBuildGen
	task.defer(function()
		task.wait() -- one Heartbeat for the old build's budget to release
		if gen ~= worldBuildGen then
			return -- a newer serverinfo superseded this build
		end
		local _world, anim = worldmesh.build(worldModels[1], pal, worldFolder, "world")
		for _, e in anim do
			table.insert(lightAnim, e)
		end
		for _, ta in worldmesh.takeTextureAnims() do
			table.insert(textureAnims, ta)
		end
		print(`[cl] world built: {worldName} ({#textureAnims} animated textures)`)
		loadingUp = 2
	end)
end

c.print = function(s: string)
	hudlib.print(hud, s, c.time)
	consolelib.print(con, s)
	print("[q] " .. s)
end

-- chase.c: chase_active third-person camera (defaults 100/16/0)
local worldlib = require(engine.server.world) -- pure hull math for TraceLine
local chase_active = false

local camera = Workspace.CurrentCamera
local currentFov = 90 -- fov cvar (horizontal, CalcFov semantics)
local currentViewsize = 100 -- screen.c viewsize (sb_lines)
local gunVrectPitch = 0 -- vrect view-model raise (see qcoords.vrect)
local applyFov: () -> () = function() end
local refreshInputMode: () -> () = function() end

--------------------------------------------------------------------------
-- keys.c: bindings, and cmd.c: alias/exec/wait

local KEYNAMES: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Space] = "space",
	[Enum.KeyCode.Return] = "enter",
	[Enum.KeyCode.KeypadEnter] = "enter",
	[Enum.KeyCode.Tab] = "tab",
	[Enum.KeyCode.Backspace] = "backspace",
	[Enum.KeyCode.Up] = "uparrow",
	[Enum.KeyCode.Down] = "downarrow",
	[Enum.KeyCode.Left] = "leftarrow",
	[Enum.KeyCode.Right] = "rightarrow",
	[Enum.KeyCode.LeftControl] = "ctrl",
	[Enum.KeyCode.RightControl] = "ctrl",
	[Enum.KeyCode.LeftShift] = "shift",
	[Enum.KeyCode.RightShift] = "shift",
	[Enum.KeyCode.LeftAlt] = "alt",
	[Enum.KeyCode.RightAlt] = "alt",
	[Enum.KeyCode.Insert] = "ins",
	[Enum.KeyCode.Delete] = "del",
	[Enum.KeyCode.PageDown] = "pgdn",
	[Enum.KeyCode.PageUp] = "pgup",
	[Enum.KeyCode.Home] = "home",
	[Enum.KeyCode.End] = "end",
	[Enum.KeyCode.Pause] = "pause",
	[Enum.KeyCode.Semicolon] = "semicolon",
	[Enum.KeyCode.Comma] = ",",
	[Enum.KeyCode.Period] = ".",
	[Enum.KeyCode.Slash] = "/",
	[Enum.KeyCode.Backquote] = "`",
	[Enum.KeyCode.Minus] = "-",
	[Enum.KeyCode.Equals] = "=",
	[Enum.KeyCode.LeftBracket] = "[",
	[Enum.KeyCode.RightBracket] = "]",
	[Enum.KeyCode.BackSlash] = "\\",
	[Enum.KeyCode.Quote] = "'",
}
for i = 0, 25 do
	KEYNAMES[(Enum.KeyCode :: any)[string.char(65 + i)]] = string.char(97 + i)
end
for i = 0, 9 do
	local names = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
	KEYNAMES[(Enum.KeyCode :: any)[names[i + 1]]] = tostring(i)
end
for i = 1, 12 do
	KEYNAMES[(Enum.KeyCode :: any)["F" .. i]] = "f" .. i
end

local bindings: { [string]: string } = {}
local aliases: { [string]: string } = {}
-- +commands routed to the input button model (cl_input.c kbutton_t)
local BUTTON_CMDS: { [string]: boolean } = {
	forward = true, back = true, moveleft = true, moveright = true,
	moveup = true, movedown = true, jump = true, attack = true,
	speed = true, strafe = true, klook = true, mlook = true,
	left = true, right = true, lookup = true, lookdown = true, use = true,
}

-- COM_Parse-ish tokenizer: quoted strings, // comments
local function tokenize(line: string): { string }
	local args = {}
	local i = 1
	local n = #line
	while i <= n do
		local ch = line:sub(i, i)
		if ch == " " or ch == "\t" then
			i += 1
		elseif ch == "/" and line:sub(i + 1, i + 1) == "/" then
			break
		elseif ch == '"' then
			local j = line:find('"', i + 1, true) or (n + 1)
			table.insert(args, line:sub(i + 1, j - 1))
			i = j + 1
		else
			local j = i
			while j <= n do
				local c2 = line:sub(j, j)
				if c2 == " " or c2 == "\t" or c2 == '"' then
					break
				end
				if c2 == "/" and line:sub(j + 1, j + 1) == "/" then
					break
				end
				j += 1
			end
			table.insert(args, line:sub(i, j - 1))
			i = j
		end
	end
	return args
end

-- Cbuf_Execute with wait support: wait defers the rest to the next frame
local cbufDeferred: { string } = {}
local cbufWait = false
local execCommand -- forward decl
local function execLine(text: string)
	-- Cbuf_Execute: break on ; and newlines, but quotes protect semicolons
	local pieces = {}
	local start = 1
	local inQuote = false
	for i = 1, #text + 1 do
		local ch = if i <= #text then text:sub(i, i) else "\n"
		if ch == '"' then
			inQuote = not inQuote
		elseif (ch == ";" and not inQuote) or ch == "\n" then
			table.insert(pieces, text:sub(start, i - 1))
			start = i + 1
		end
	end
	for _, piece in pieces do
		local trimmed = piece:match("^%s*(.-)%s*$") :: string
		if trimmed ~= "" and trimmed:sub(1, 2) ~= "//" then
			if cbufWait then
				table.insert(cbufDeferred, trimmed)
			else
				execCommand(trimmed)
			end
		end
	end
end

local function cbufFrame()
	cbufWait = false
	if #cbufDeferred == 0 then
		return
	end
	local q = cbufDeferred
	cbufDeferred = {}
	for _, cmdline in q do
		if cbufWait then
			table.insert(cbufDeferred, cmdline)
		else
			execCommand(cmdline)
		end
	end
end

-- Key_Event: keydowns run the bind; keyups run the matching -command
local function keyEvent(keyname: string, down: boolean)
	local b = bindings[keyname]
	if not b then
		return
	end
	if down then
		execLine(b)
	elseif b:sub(1, 1) == "+" then
		execLine("-" .. b:sub(2))
	end
end

execCommand = function(line: string)
	local cmd, args = line:match("^(%S+)%s*(.*)$")
	if not cmd then
		return
	end
	cmd = cmd:lower()

	-- keys.c / cmd.c commands
	local first = cmd:sub(1, 1)
	if first == "+" or first == "-" then
		local name = cmd:sub(2)
		if name == "showscores" then
			hudlib.setShowScores(hud, first == "+")
			return
		elseif BUTTON_CMDS[name] then
			input.setButton(name, first == "+")
			return
		end
	end
	if cmd == "bind" then
		local t = tokenize(line)
		local key = (t[2] or ""):lower()
		if key == "" then
			consolelib.print(con, "bind <key> [command] : attach a command to a key")
		elseif #t == 2 then
			consolelib.print(con, `"{key}" = "{bindings[key] or ""}"`)
		else
			bindings[key] = table.concat(t, " ", 3)
		end
		return
	elseif cmd == "unbind" then
		local t = tokenize(line)
		if t[2] then
			bindings[(t[2] :: string):lower()] = nil
		end
		return
	elseif cmd == "unbindall" then
		table.clear(bindings)
		return
	elseif cmd == "alias" then
		local t = tokenize(line)
		if not t[2] then
			for n, v in aliases do
				consolelib.print(con, `{n} : {v}`)
			end
		else
			aliases[t[2]] = table.concat(t, " ", 3)
		end
		return
	elseif cmd == "echo" then
		consolelib.print(con, args)
		return
	elseif cmd == "exec" then
		local name = args:match("%S+")
		local buf = if name then vfslib.loadFile(fs, name) else nil
		if not buf then
			consolelib.print(con, `couldn't exec {name}`)
		else
			consolelib.print(con, `execing {name}`)
			for cfgline in buffer.tostring(buf):gmatch("[^\r\n]+") do
				execLine(cfgline)
			end
		end
		return
	elseif cmd == "wait" then
		cbufWait = true
		return
	elseif cmd == "centerview" then
		input.centerview()
		return
	elseif cmd == "fov" then
		local v = tonumber(args)
		if v and v >= 10 and v <= 170 then
			-- quake fov is horizontal; CalcFov derives the vertical
			currentFov = v
			applyFov()
		end
		return
	elseif cmd == "viewsize" then
		-- screen.c: 100 full HUD, 110 status row only, 120 none
		local v = tonumber(args)
		if v then
			currentViewsize = math.clamp(v, 30, 120)
			hudlib.setViewsize(hud, currentViewsize)
			applyFov()
		end
		return
	elseif cmd == "togglemenu" then
		menulib.toggle(mnu)
		refreshInputMode()
		return
	elseif cmd == "bf" then
		-- V_BonusFlash_f (Cmd_AddCommand "bf" in C; the server stuffs it
		-- on every item pickup)
		c.cshift_bonus_percent = 50
		return
	elseif cmd == "messagemode" or cmd == "messagemode2" then
		consolelib.print(con, "use say <text> or the Roblox chat")
		return
	elseif cmd == "viewsize" or cmd == "gamma" or cmd == "volume" then
		return -- accepted, fixed on this platform
	elseif cmd == "sizeup" or cmd == "sizedown" or cmd == "screenshot" then
		return
	elseif cmd == "quit"
		or cmd == "menu_save" or cmd == "menu_load" or cmd == "menu_options"
		or cmd == "menu_multiplayer" or cmd == "help" then
		consolelib.print(con, `{cmd}: not implemented yet`)
		return
	elseif aliases[cmd] then
		execLine(aliases[cmd])
		return
	end

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
	elseif cmd == "playdemo" then
		playDemo(args:match("%S+") or "")
		return
	elseif cmd == "stopdemo" then
		stopDemo("demo stopped")
		return
	elseif cmd == "record" then
		-- CL_Record_f: record <demoname> [<map>]. C refuses a bare
		-- record while connected — the demo would miss the signon
		-- (serverinfo/baselines) and play back frozen. With a map
		-- argument the map command runs first and the fresh signon is
		-- captured, like C.
		local name, mapArg = args:match("(%S+)%s*(%S*)")
		if not name then
			consolelib.print(con, "record <demoname> [<map>]")
		elseif mapArg == "" and c.signon == cllib.SIGNONS then
			consolelib.print(con, "Can not record - already connected to server")
			consolelib.print(con, "Client demo recording must be started before connecting")
		else
			demoName = name .. ".dem"
			demoRecording = { "-1\n" } -- forced cd track line
			consolelib.print(con, `recording to {demoName}.`)
			if mapArg ~= "" then
				sendStringCmd("map " .. mapArg)
			end
		end
		return
	elseif cmd == "stop" then
		if demoRecording then
			local blob = table.concat(demoRecording :: { string })
			recordedDemos[demoName] = buffer.fromstring(blob)
			demoRecording = nil
			consolelib.print(con, `Completed demo ({#blob} bytes, playdemo {demoName})`)
		else
			consolelib.print(con, "Not recording a demo.")
		end
		return
	elseif cmd == "chase_active" then
		local v = tonumber(args)
		if v then
			chase_active = v ~= 0
			consolelib.print(con, `"chase_active" is "{v}"`)
		end
	elseif cmd == "+showscores" then
		hudlib.setShowScores(hud, true)
	elseif cmd == "-showscores" then
		hudlib.setShowScores(hud, false)
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

--------------------------------------------------------------------------
-- cl_demo.c: demo playback (and in-memory recording)

stopDemo = function(msgText: string?)
	if demoPlaying then
		demoPlaying = false
		demoBuf = nil
		consolelib.print(con, msgText or "demo completed")
		consolelib.print(con, "use map <name> to rejoin the live game")
	end
end

playDemo = function(name: string)
	if name == "" then
		consolelib.print(con, "playdemo <demoname> : plays a demo")
		return
	end
	if not name:find("%.dem$") then
		name ..= ".dem"
	end
	local buf = recordedDemos[name]
	if not buf then
		demandFile(name)
		buf = vfslib.loadFile(fs, name, true)
	end
	if not buf then
		consolelib.print(con, `ERROR: couldn't open {name}`)
		return
	end
	-- skip the forced cd track line
	local n = buffer.len(buf)
	local i = 0
	while i < n and buffer.readu8(buf, i) ~= 10 do
		i += 1
	end
	demoPos = i + 1
	demoBuf = buf
	demoPlaying = true
	c.signon = 0
	consolelib.print(con, `Playing demo from {name}.`)
end

-- CL_GetMessage's demo path: feed blocks until the message time passes
-- cl.time; always grab during signon
local demoBusy = false
demoFrame = function()
	if demoBusy then
		return -- a previous message is still building the world (yields)
	end
	demoBusy = true
	local fed = 0
	while demoPlaying do
		if c.signon == cllib.SIGNONS and c.time <= c.mtime0 then
			break
		end
		local db = demoBuf :: buffer
		if demoPos + 16 > buffer.len(db) then
			stopDemo()
			break
		end
		local msglen = buffer.readi32(db, demoPos)
		local ax = buffer.readf32(db, demoPos + 4)
		local ay = buffer.readf32(db, demoPos + 8)
		demoPos += 16
		if msglen < 0 or demoPos + msglen > buffer.len(db) then
			stopDemo("demo message > buffer")
			break
		end
		local block = buffer.create(msglen)
		buffer.copy(block, 0, db, demoPos, msglen)
		demoPos += msglen
		input.setAngles(vector.create(ax, ay, 0))
		local ok, err = pcall(cllib.parseServerMessage, c, block)
		cllib.takeReliable(c) -- drop signon replies; the demo has the answers
		if not ok then
			warn("[demo] parse error: " .. tostring(err))
			stopDemo("demo parse error")
			break
		end
		fed += 1
		if fed > 200 then
			break -- don't stall a frame on a huge signon burst
		end
	end
	demoBusy = false
end

con.onCommand = execLine

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
	-- CL_ParseServerMessage svc_stufftext -> Cbuf_AddText: stuffed
	-- commands run through the same command path as typed input
	for line in text:gmatch("[^\n]+") do
		execLine(line)
	end
end
c.onParticle = function(_c, org, dir, color, count)
	particleslib.runEffect(psys, org, dir, color, count, c.time)
end
c.onSound = function(_c, entnum, channel, sample, pos, vol, atten)
	soundlib.start(snd, entnum, channel, sample, pos, vol, atten)
end
c.onStopSound = function(_c, entnum, channel)
	soundlib.stop(snd, entnum, channel)
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
	elseif te.type == proto.TE_EXPLOSION then -- rocket explosion
		particleslib.explosion(psys, te.pos, c.time)
		local dl = allocDlight(0, c.time)
		dl.origin = te.pos
		dl.radius = 350
		dl.die = c.time + 0.5
		dl.decay = 300
		teSound("weapons/r_exp3.wav", te.pos)
	elseif te.type == proto.TE_EXPLOSION2 then -- color mapped explosion
		particleslib.particleExplosion2(psys, te.pos, te.colorStart or 0, te.colorLength or 1, c.time)
		local dl = allocDlight(0, c.time)
		dl.origin = te.pos
		dl.radius = 350
		dl.die = c.time + 0.5
		dl.decay = 300
		teSound("weapons/r_exp3.wav", te.pos)
	elseif te.type == proto.TE_TAREXPLOSION then -- tarbaby explosion (no dlight)
		particleslib.blobExplosion(psys, te.pos, c.time)
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

camera.CameraType = Enum.CameraType.Scriptable
currentFov = 90
applyFov = function()
	-- CalcFov over the vrect (window minus sbar), per SCR_CalcRefdef
	local vp = camera.ViewportSize
	local fovY = qcoords.vrect(currentFov, vp.X, vp.Y, hudlib.sbarLinesPx(currentViewsize))
	camera.FieldOfView = fovY
	gunVrectPitch = 0 -- superseded by the viewmodel ViewportFrame
	viewmodellib.setLayout(vmgun, currentFov, hudlib.sbarLinesPx(currentViewsize))
end
applyFov()
camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyFov)

input.init(90)
input.lockMouse()

local UserInputService = game:GetService("UserInputService")

refreshInputMode = function()
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
		-- run a raw line through the real Cbuf path (con.onCommand =
		-- execLine): quote-aware ';' splitting and wait deferral behave
		-- exactly as typed input (the old harness pre-split on ';',
		-- breaking quoted alias bodies and Cmd_Wait_f)
		con.onCommand(arg :: string)
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

-- debug hook: probe the live light atlas (regions by lightofs) and force
-- rewrites — execute_luau runs in a separate VM so it cannot require the
-- live module state directly
local dbgAtlas = Instance.new("BindableFunction")
dbgAtlas.Name = "RQDBG_Atlas"
dbgAtlas.Parent = workspace
dbgAtlas.OnInvoke = function(action: string, arg: string?)
	local atlas, styleFn = worldmesh._debug()
	if not atlas then
		return "no atlas"
	end
	if action == "info" then
		return ("pages=%d regions=%d animated=%d styleFn10=%s styleFn0=%s sv10=%s"):format(
			#atlas.pages, #atlas.regions, #atlas.animated,
			tostring(styleFn(10)), tostring(styleFn(0)), tostring(styleValues[10]))
	elseif action == "region" then
		local want = tonumber(arg)
		for _, r in atlas.regions do
			if r.surf.lightofs == want then
				local inAnim = table.find(atlas.animated, r) ~= nil
				local page = atlas.pages[r.page]
				return ("page=%d x=%d y=%d smax=%d tmax=%d animated=%s inAnimList=%s styles=%d,%d,%d,%d live=%s"):format(
					r.page, r.x, r.y, r.smax, r.tmax, tostring(r.animated), tostring(inAnim),
					r.surf.styles[1], r.surf.styles[2], r.surf.styles[3], r.surf.styles[4],
					tostring(page and page.live))
			end
		end
		return "region not found for lightofs " .. tostring(want)
	elseif action == "rewrite" then
		local want = tonumber(arg)
		for _, r in atlas.regions do
			if r.surf.lightofs == want then
				lightatlaslib.writeRegion(atlas, r, function()
					return 264
				end)
				return "rewrote bright"
			end
		end
		return "not found"
	elseif action == "alpha" then
		-- current CPU-mirror alpha bytes for the region's first row
		-- (alpha = 1 - brightness: 0 bright, 255 black)
		local want = tonumber(arg)
		for _, r in atlas.regions do
			if r.surf.lightofs == want then
				local page = atlas.pages[r.page]
				if not page then
					return "no page"
				end
				local vals = {}
				for px = 0, r.smax + 1 do
					local b = buffer.readu32(page.cpu, ((r.y + 1) * 1024 + r.x + px) * 4)
					table.insert(vals, tostring(bit32.rshift(b, 24)))
				end
				return table.concat(vals, ",")
			end
		end
		return "not found"
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

	-- Key_Event: run the bind
	local name = KEYNAMES[key]
	if name then
		keyEvent(name, true)
	end
end)

-- mouse buttons are keys too (MOUSE1-3)
local MOUSENAMES: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton1] = "mouse1",
	[Enum.UserInputType.MouseButton2] = "mouse2",
	[Enum.UserInputType.MouseButton3] = "mouse3",
}
UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
	local mname = MOUSENAMES[io.UserInputType]
	if mname and not processed and not con.open and not menulib.isOpen(mnu) then
		keyEvent(mname, true)
	end
end)

UserInputService.InputEnded:Connect(function(io: InputObject)
	if io.UserInputType == Enum.UserInputType.Keyboard then
		local name = KEYNAMES[io.KeyCode]
		if name then
			keyEvent(name, false)
		end
	else
		local mname = MOUSENAMES[io.UserInputType]
		if mname then
			keyEvent(mname, false)
		end
	end
end)

-- quake.rc: the 1996 defaults, then the modern layout as the authentic
-- autoexec mechanism (WASD wasn't the default; arrows were)
execLine("exec default.cfg")
for _, l in {
	"bind w +forward",
	"bind s +back",
	"bind a +moveleft",
	"bind d +moveright",
	"bind e +moveup",
	"bind c +movedown",
	"bind m togglemenu",
} do
	execLine(l)
end
execLine("exec autoexec.cfg")

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
	cbufFrame()
	input.updateTurn(dt)

	-- pump inbound messages (demo playback detaches from the live stream)
	if demoPlaying then
		inbound = {}
		demoFrame()
	end
	if #inbound > 0 then
		local queue = inbound
		inbound = {}
		for _, data in queue do
			if demoRecording then
				-- CL_WriteDemoMessage: length, viewangles, payload
				local va = input.viewangles()
				local hdr = buffer.create(16)
				buffer.writei32(hdr, 0, buffer.len(data))
				buffer.writef32(hdr, 4, va.x)
				buffer.writef32(hdr, 8, va.y)
				buffer.writef32(hdr, 12, 0)
				table.insert(demoRecording :: { string }, buffer.tostring(hdr))
				table.insert(demoRecording :: { string }, buffer.tostring(data))
			end
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
	if sendAccumulator >= 1 / 72 and not demoPlaying then
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
			elseif ta.kind == "sky" then
				textures.writeSkyFrame(ta.img, ta.pixels, ta.w, ta.h, pal, c.time)
			elseif ta.kind == "wall" then
				-- R_TextureAnimation: world surfaces have entity frame 0,
				-- so only the base (+N) chain ever shows
				local base = ta.base
				local frames = ta.frames
				local parts = ta.parts
				if base and frames and parts and base.anim_total > 0 then
					local reletive = styleFrame % base.anim_total
					local tex: bsplib.Texture = base
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
						entrender.setLight(re, lightpoint.at(worldModels[1], se.origin, styleValueFor))
					elseif re.kind == "sprite" then
						entrender.updateSprite(re, def, se.origin, se.frame)
					elseif re.kind == "brush" then
						entrender.updateBrush(re, se.origin, se.angles)
					end
					table.insert(staticEnts, { re = re, se = se, def = def })
				end
			end
		end
	end

	-- statics with framegroup models (torch flames) animate by time, so
	-- alias statics re-pose every frame like R_DrawEntitiesOnList
	for _, st in staticEnts do
		if st.re.kind == "alias" then
			entrender.updateAlias(st.re, st.def, st.se.origin, st.se.angles, st.se.frame, st.se.skinnum, st.se.syncbase, c.time)
		end
	end

	-- update dynamic entities
	for num = 1, c.num_entities - 1 do
		local e = c.entities[num]
		local re = renderEnts[num]

		local shouldDraw = e ~= nil and e.visible and e.modelindex ~= 0 and (num ~= c.viewentity or chase_active)

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

			-- CL_RelinkEntities: entity effects
			if bit32.band(e.effects, 1) ~= 0 then -- EF_BRIGHTFIELD
				particleslib.entityParticles(psys, e.origin, c.time)
			end
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
	if chase_active and worldModels[1] then
		-- Chase_Update: pull back 100, up 16; re-pitch at the traced
		-- lookpoint. The original doesn't clip the camera against walls.
		local dest = refdef.vieworg - forward * 100 - right * 0
		dest = vector.create(dest.x, dest.y, refdef.vieworg.z + 16)
		local lookdest = refdef.vieworg + forward * 4096
		local tr = {
			allsolid = false,
			startsolid = false,
			inopen = false,
			inwater = false,
			fraction = 1,
			endpos = lookdest,
			planeNormal = vector.zero,
			planeDist = 0,
			ent = nil,
		}
		local hull = worldModels[1].hulls[1]
		worldlib.recursiveHullCheck(hull, hull.firstclipnode, 0, 1, refdef.vieworg, lookdest, tr :: any)
		local stop = tr.endpos - refdef.vieworg
		local d = math.max(vector.dot(stop, forward), 1)
		refdef.viewangles = vector.create(-math.deg(math.atan(stop.z / d)), refdef.viewangles.y, refdef.viewangles.z)
		refdef.vieworg = dest
		forward, right, up = mathlib.angleVectors(refdef.viewangles)
	end
	camera.CFrame = qcoords.cframe(refdef.vieworg, forward, right, up)
	viewmodellib.update(vmgun, camera)

	-- view weapon
	if refdef.gunmodel ~= 0 and c.stats[cllib.STAT_HEALTH] > 0 and c.intermission == 0 and not chase_active then
		if gunModelIndex ~= refdef.gunmodel then
			if gunEnt then
				entrender.destroy(gunEnt)
				gunEnt = nil
			end
			gunModelIndex = refdef.gunmodel
			local def = getModelDef(refdef.gunmodel)
			if def and def.kind == "alias" then
				-- the gun renders through its own projection (viewmodel.luau)
			gunEnt = entrender.create(def, vmgun.world)
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
	hudlib.updateOverlays(hud, c)

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
		workspace:SetAttribute("RQ_CshiftBonus", c.cshift_bonus_percent)
		workspace:SetAttribute("RQ_Yaw", c.viewangles.y)
		if e then
			workspace:SetAttribute("RQ_Origin", qcoords.toRoblox(e.origin))
		end
	end
end)

print("[robloquake] client ready")
