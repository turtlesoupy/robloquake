--!strict
-- RobloQuake server bootstrap: assembles the pak from synced asset chunks,
-- spawns the Quake server, and bridges Roblox players/remotes to the
-- engine's client transport model.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local pak = require(engine.common.pak)
local vfs = require(engine.common.vfs)
local host = require(engine.server.host)
local svlib = require(engine.server.sv)

-- start map: attribute override, else per-game default

-- reassemble pak files from base64 chunk StringValues; decode chunk-wise
-- with yields so the live-server script watchdog never triggers
local assetchunks = require(script.assetchunks)

local function loadPak(gameFolder: Instance, pakName: string): pak.Pack?
	local pakFolder = gameFolder:FindFirstChild(pakName)
	if not pakFolder then
		return nil
	end
	return pak.load(`{gameFolder.Name}/{pakName}.pak`, assetchunks.loadRaw(pakFolder))
end

-- the full pak chunks live in ServerStorage so 200MB of pak data is never
-- replicated to joining clients (that stalled published-game joins);
-- a per-map client bundle is published to ReplicatedStorage instead
local assets = ServerStorage:FindFirstChild("QuakeAssets") or ReplicatedStorage:WaitForChild("QuakeAssets")
local gameDir = assets:GetAttribute("game")
if typeof(gameDir) ~= "string" then
	gameDir = "id1"
end
local gameFolder = assets:WaitForChild(gameDir)

local startAttr = assets:GetAttribute("startmap")
local START_MAP = if typeof(startAttr) == "string" then startAttr else "start"

-- COM_AddGameDirectory: add a game/mod dir's paks pak0..pakN; each newly
-- added pak is searched before the ones added earlier
local fsys = vfs.new()
local function addGameDirectory(dirFolder: Instance)
	for i = 0, 9 do
		local pack = loadPak(dirFolder, `pak{i}`)
		if not pack then
			break
		end
		vfs.addPack(fsys, pack)
		print(`[robloquake] loaded {dirFolder.Name}/pak{i}.pak ({pack.numfiles} files)`)
	end
end
addGameDirectory(gameFolder)

-- mod support: gamedir attribute stacks a mod's paks over the base game
-- (COM_InitFilesystem's -game). Missing mod files fall through to the base
-- game automatically because the searchpath stack is searched newest-first.
local gamedirAttr = assets:GetAttribute("gamedir")
local modDir: string? = nil
local modFolder: Instance? = nil
if typeof(gamedirAttr) == "string" and gamedirAttr ~= "" and gamedirAttr ~= gameDir then
	modFolder = assets:FindFirstChild(gamedirAttr)
	if modFolder then
		modDir = gamedirAttr
		addGameDirectory(modFolder :: Instance)
	else
		warn(`[robloquake] gamedir "{gamedirAttr}" not found under QuakeAssets — running base game`)
	end
end

-- remotes
local net = Instance.new("Folder")
net.Name = "QuakeNet"
local reliable = Instance.new("RemoteEvent")
reliable.Name = "Reliable"
reliable.Parent = net
local unreliable = Instance.new("UnreliableRemoteEvent")
unreliable.Name = "Unreliable"
unreliable.Parent = net
net.Parent = ReplicatedStorage

-- engine selection: campaign/coop places run NetQuake (default),
-- competitive places set engine="qw" on QuakeAssets for QuakeWorld
local engineAttr = assets:GetAttribute("engine")
if engineAttr == "qw" then
	require(script.qwserver)({
		fsys = fsys,
		assets = assets,
		gameFolder = gameFolder,
		gameDir = gameDir,
		modDir = modDir,
		modFolder = modFolder,
		startMap = START_MAP,
		reliable = reliable,
		unreliable = unreliable,
	})
	return
end

-- server (NetQuake)
local svr = host.newGame(fsys, 16)
svr.print = function(s: string)
	print("[sv] " .. s)
end

-- game-rule cvars from asset-folder attributes, applied before the world
-- spawns so QC sees them (deathmatch spawn points, item rules, skill)
local cvarlib = require(engine.common.cvar)
for _, name in { "deathmatch", "coop", "skill", "fraglimit", "timelimit" } do
	local v = assets:GetAttribute(name)
	if typeof(v) == "number" then
		cvarlib.setValue(svr.cvars, name, v)
		print(`[robloquake] {name} = {v}`)
	end
end

host.spawnServer(svr, START_MAP)
assert(svr.active, "server failed to spawn")
_G.RQ_SERVER = svr -- studio debugging access

-- client asset bundle (shared with the QW boot)
local clientbundle = require(script.clientbundle)
local bundle = clientbundle.new(fsys, gameDir, gameFolder, modDir, modFolder)
bundle.clientFS:SetAttribute("engine", "nq")
bundle.publishAll(svr)
local publishFile = bundle.publishFile;

(svr :: any).onFileRequest = function(path: string)
	publishFile(path) -- no-ops when the pak doesn't have it
end;
-- player speech must pass Roblox text filtering: clients speak through
-- TextChatService, and the server refuses raw wire say from anyone
(svr :: any).suppressSay = true

-- saved games persist in the place file (ServerStorage.QuakeSaves)
do
	local folder = ServerStorage:FindFirstChild("QuakeSaves")
	if folder then
		local sg = (svr :: any)
		sg.savegames = sg.savegames or {}
		for _, sv in folder:GetChildren() do
			if sv:IsA("StringValue") then
				sg.savegames[sv.Name] = sv.Value
			end
		end
	end
end

-- player <-> client slot bridging
local slotByPlayer: { [Player]: number } = {}

-- host-command policy: a real NetQuake listen server only takes cheats/
-- level control from the local console. The Roblox mapping: Studio is
-- always the host; a private server's owner is the host (the faithful
-- owner=listen-server mapping); the place creator counts for dev tests.
local function playerIsHost(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	if game.PrivateServerOwnerId ~= 0 and player.UserId == game.PrivateServerOwnerId then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return false
end;
(svr :: any).commandGate = function(client: svlib.Client): boolean
	for player, slot in slotByPlayer do
		if slot == client.num then
			return playerIsHost(player)
		end
	end
	return false
end

local function connectPlayer(player: Player)
	local slot = host.findFreeClient(svr)
	if not slot then
		player:Kick("Server is full")
		return
	end
	slotByPlayer[player] = slot
	local client = svr.clients[slot]
	client.sendUnreliable = function(data: buffer)
		-- UnreliableRemoteEvents silently drop payloads over ~900 bytes;
		-- busy scenes exceed that, so oversized datagrams ride the
		-- reliable channel instead (packet loss isn't a thing here anyway)
		if buffer.len(data) > 850 then
			reliable:FireClient(player, data)
		else
			unreliable:FireClient(player, data)
		end
		return true
	end
	client.sendReliable = function(data: buffer)
		reliable:FireClient(player, data)
		return true
	end
	client.canSendReliable = function()
		return true
	end
	host.connectClient(svr, slot)
	print(`[robloquake] {player.Name} connected as client {slot}`)
end

svr.onDropClient = function(_svr, client)
	for player, slot in slotByPlayer do
		if slot == client.num then
			slotByPlayer[player] = nil
			break
		end
	end
end

-- clients announce readiness with a first message (their remote handlers
-- must be live before the serverinfo is sent, so PlayerAdded is too early)
Players.PlayerRemoving:Connect(function(player)
	local slot = slotByPlayer[player]
	if slot then
		slotByPlayer[player] = nil
		local client = svr.clients[slot]
		if client.active then
			svlib.dropClient(svr, client, false)
		end
	end
end)

local function onInbound(player: Player, data: unknown)
	if typeof(data) ~= "buffer" then
		return
	end
	local slot = slotByPlayer[player]
	if not slot then
		connectPlayer(player)
		slot = slotByPlayer[player]
		if not slot then
			return
		end
	end
	local client = svr.clients[slot]
	if client.active then
		table.insert(client.inbox, data :: buffer)
	end
end
reliable.OnServerEvent:Connect(onInbound)
unreliable.OnServerEvent:Connect(onInbound)

-- frame loop: Quake host frames clamped like host.c (max 0.1s per tick)
local vmlib = require(engine.progs.vm)
local defs = require(engine.progs.defs)
local diagAccum = 0
RunService.Heartbeat:Connect(function(dt: number)
	if not svr.active then
		return
	end
	host.frame(svr, math.clamp(dt, 0.001, 0.1))

	diagAccum += dt
	if diagAccum > 0.5 then
		diagAccum = 0
		local ServerStorage = game:GetService("ServerStorage")
		ServerStorage:SetAttribute("SV_Time", svr.time)
		ServerStorage:SetAttribute("SV_Edicts", svr.vm.num_edicts)
		local c1 = svr.clients[1]
		if c1 and c1.active and c1.edict then
			ServerStorage:SetAttribute("SV_CmdF", c1.cmd.forwardmove)
			local o = vmlib.edVector(c1.edict, defs.ent.origin)
			local v = vmlib.edVector(c1.edict, defs.ent.velocity)
			ServerStorage:SetAttribute("SV_Origin", Vector3.new(o.x, o.y, o.z))
			ServerStorage:SetAttribute("SV_Vel", Vector3.new(v.x, v.y, v.z))
			ServerStorage:SetAttribute("SV_VAngleY", vmlib.edVector(c1.edict, defs.ent.v_angle).y)

			-- monster census: alive count + nearest live monster to the player
			local alive = 0
			local nearest: Vector3? = nil
			local nearestDist = math.huge
			for i = 1, svr.vm.num_edicts - 1 do
				local e = svr.vm.edicts[i + 1]
				if e.free then
					continue
				end
				if bit32.band(vmlib.edFloat(e, defs.ent.flags), 32) ~= 0 and vmlib.edFloat(e, defs.ent.health) > 0 then
					alive += 1
					local mo = vmlib.edVector(e, defs.ent.origin)
					local d = vector.magnitude(mo - o)
					if d < nearestDist then
						nearestDist = d
						nearest = Vector3.new(mo.x, mo.y, mo.z)
					end
				end
			end
			ServerStorage:SetAttribute("SV_MonstersAlive", alive)
			ServerStorage:SetAttribute("SV_NearestMonster", nearest)
			ServerStorage:SetAttribute("SV_Kills", vmlib.globalFloat(svr.vm, defs.glob.killed_monsters))

			-- nearest door (debug)
			local bestDoor: Vector3? = nil
			local bestDist = math.huge
			for i = 1, svr.vm.num_edicts - 1 do
				local e = svr.vm.edicts[i + 1]
				if e.free then
					continue
				end
				local cn = vmlib.edString(svr.vm, e, defs.ent.classname)
				if cn == "door" or cn == "door_trigger" then
					local mo = (vmlib.edVector(e, defs.ent.absmin) + vmlib.edVector(e, defs.ent.absmax)) * 0.5
					local d = vector.magnitude(mo - o)
					if d < bestDist then
						bestDist = d
						bestDoor = Vector3.new(mo.x, mo.y, mo.z)
					end
				end
			end
			ServerStorage:SetAttribute("SV_NearestDoor", bestDoor)
			ServerStorage:SetAttribute("SV_NearestDoorDist", bestDist)

			-- debug loadout: ServerStorage attribute SVDBG_SpawnGive (comma-
			-- separated Host_Give specs, e.g. "7,r 100") re-applies whenever a
			-- player lacks the first listed weapon — i.e. once per spawn, so
			-- respawns and changelevels keep the loadout. Clear it to disable.
			local giveSpec = ServerStorage:GetAttribute("SVDBG_SpawnGive")
			if typeof(giveSpec) == "string" and giveSpec ~= "" then
				local firstWeapon = tonumber(giveSpec:match("%d"))
				local wbit = if firstWeapon and firstWeapon >= 2 and firstWeapon <= 8
					then bit32.lshift(1, firstWeapon - 2)
					else 0
				for _, cl in svr.clients do
					if cl.active and wbit ~= 0 and bit32.band(vmlib.edFloat(cl.edict, defs.ent.items), wbit) == 0 then
						for spec in giveSpec:gmatch("[^,]+") do
							host.clientCommand(svr, cl, "give " .. (spec:match("^%s*(.-)%s*$") :: string))
						end
					end
				end
			end

			-- debug: fire the use function of a door by edict number (-1 = nearest)
			local useReq = ServerStorage:GetAttribute("SVDBG_UseDoor")
			if typeof(useReq) == "number" then
				ServerStorage:SetAttribute("SVDBG_UseDoor", nil)
				local doorEd = nil
				if useReq >= 1 then
					doorEd = svr.vm.edicts[useReq + 1]
				else
					local bd = math.huge
					for i = 1, svr.vm.num_edicts - 1 do
						local e = svr.vm.edicts[i + 1]
						if not e.free and vmlib.edString(svr.vm, e, defs.ent.classname) == "door" then
							local mo = (vmlib.edVector(e, defs.ent.absmin) + vmlib.edVector(e, defs.ent.absmax)) * 0.5
							local d = vector.magnitude(mo - o)
							if d < bd then
								bd = d
								doorEd = e
							end
						end
					end
				end
				if doorEd and not doorEd.free then
					local fn = vmlib.edInt(doorEd, defs.ent.use)
					if fn ~= 0 then
						buffer.writef32(svr.vm.globals, defs.glob.time * 4, svr.time)
						buffer.writei32(svr.vm.globals, defs.glob.self * 4, doorEd.num)
						buffer.writei32(svr.vm.globals, defs.glob.other * 4, c1.edict.num)
						local adef = svr.vm.progs.globaldefsByName["activator"]
						if adef then
							buffer.writei32(svr.vm.globals, adef.ofs * 4, c1.edict.num)
						end
						vmlib.exec(svr.vm, fn)
						print("[svdbg] fired use of door", doorEd.num)
					end
				end
			end

			-- debug finale trigger (SVDBG family): send svc_finale exactly
			-- like end.qc's finale text so the client overlay can be staged
			local fin = ServerStorage:GetAttribute("SVDBG_Finale")
			if typeof(fin) == "string" and fin ~= "" then
				ServerStorage:SetAttribute("SVDBG_Finale", nil)
				local msglib = require(engine.common.msg)
				local proto = require(engine.protocol)
				msglib.writeByte(c1.message, proto.svc_finale)
				msglib.writeString(c1.message, fin)
				print("[svdbg] finale sent")
			end

			-- debug teleport request: try the exact spot, then nearby offsets,
			-- keeping the first position the player isn't stuck in
			local tp = ServerStorage:GetAttribute("SVDBG_SetOrigin")
			if typeof(tp) == "Vector3" then
				ServerStorage:SetAttribute("SVDBG_SetOrigin", nil)
				local world = require(engine.server.world)
				local before = vmlib.edVector(c1.edict, defs.ent.origin)
				local candidates = { vector.create(tp.X, tp.Y, tp.Z) }
				for _, d in { 48, 96, 144 } do
					table.insert(candidates, vector.create(tp.X + d, tp.Y, tp.Z))
					table.insert(candidates, vector.create(tp.X - d, tp.Y, tp.Z))
					table.insert(candidates, vector.create(tp.X, tp.Y + d, tp.Z))
					table.insert(candidates, vector.create(tp.X, tp.Y - d, tp.Z))
					table.insert(candidates, vector.create(tp.X, tp.Y, tp.Z + d))
				end
				local placed = false
				for _, cand in candidates do
					vmlib.edSetVector(c1.edict, defs.ent.origin, cand)
					world.linkEdict(svr.world, c1.edict, false)
					if not world.testEntityPosition(svr.world, c1.edict) then
						placed = true
						print("[svdbg] teleported player to", cand)
						break
					end
				end
				if not placed then
					vmlib.edSetVector(c1.edict, defs.ent.origin, before)
					world.linkEdict(svr.world, c1.edict, false)
					print("[svdbg] teleport failed: all candidates solid")
				end
			end
		end
	end

	-- deferred loadgame (host clientCommand "load")
	local sg = (svr :: any)
	local loadReq = sg.loadgameRequest
	if loadReq then
		sg.loadgameRequest = nil
		local text = sg.savegames and sg.savegames[loadReq]
		if text then
			print(`[robloquake] loading {loadReq}.sav`)
			local savegamelib = require(engine.server.savegame)
			savegamelib.load(svr, text, function(m: string)
				host.spawnServer(svr, m)
			end)
			bundle.publishAll(svr)
			for _, slot in slotByPlayer do
				host.connectClient(svr, slot)
			end
		end
	end
	-- mirror fresh saves into ServerStorage (Studio place persistence)
	if sg.savegameDirty then
		local name = sg.savegameDirty
		sg.savegameDirty = nil
		local folder = ServerStorage:FindFirstChild("QuakeSaves")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "QuakeSaves"
			folder.Parent = ServerStorage
		end
		local sv = folder:FindFirstChild(name)
		if not sv then
			sv = Instance.new("StringValue")
			sv.Name = name
			sv.Parent = folder
		end
		(sv :: StringValue).Value = sg.savegames[name]
	end

	-- level change requested by QC (trigger_changelevel)
	local nextLevel = svr.changelevelTo
	if nextLevel then
		svr.changelevelTo = nil
		print(`[robloquake] changelevel to {nextLevel}`)
		host.saveSpawnparms(svr) -- inventory carries across levels
		host.spawnServer(svr, nextLevel)
		bundle.publishAll(svr) -- new map + newly precached models
		for _, slot in slotByPlayer do
			host.connectClient(svr, slot, true)
		end
	end
end)

print("[robloquake] server running: " .. START_MAP)
