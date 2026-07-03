--!strict
-- RobloQuake server bootstrap: assembles the pak from synced asset chunks,
-- spawns the Quake server, and bridges Roblox players/remotes to the
-- engine's client transport model.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local base64 = require(engine.common.base64)
local pak = require(engine.common.pak)
local vfs = require(engine.common.vfs)
local host = require(engine.server.host)
local svlib = require(engine.server.sv)

local START_MAP = "e1m1"

-- reassemble pak files from base64 chunk StringValues
local function loadPak(gameFolder: Instance, pakName: string): pak.Pack?
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
	local data = base64.decode(table.concat(parts))
	return pak.load(`{gameFolder.Name}/{pakName}.pak`, data)
end

local assets = ReplicatedStorage:WaitForChild("QuakeAssets")
local id1 = assets:WaitForChild("id1")

local fsys = vfs.new()
for _, pakName in { "pak0", "pak1" } do
	local pack = loadPak(id1, pakName)
	if pack then
		vfs.addPack(fsys, pack)
		print(`[robloquake] loaded {pakName}.pak ({pack.numfiles} files)`)
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

-- server
local svr = host.newGame(fsys, 16)
svr.print = function(s: string)
	print("[sv] " .. s)
end

host.spawnServer(svr, START_MAP)
assert(svr.active, "server failed to spawn")

-- player <-> client slot bridging
local slotByPlayer: { [Player]: number } = {}

local function connectPlayer(player: Player)
	local slot = host.findFreeClient(svr)
	if not slot then
		player:Kick("Server is full")
		return
	end
	slotByPlayer[player] = slot
	local client = svr.clients[slot]
	client.sendUnreliable = function(data: buffer)
		unreliable:FireClient(player, data)
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

Players.PlayerAdded:Connect(connectPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(connectPlayer, player)
end

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
	local slot = slotByPlayer[player]
	if not slot or typeof(data) ~= "buffer" then
		return
	end
	local client = svr.clients[slot]
	if client.active then
		table.insert(client.inbox, data :: buffer)
	end
end
reliable.OnServerEvent:Connect(onInbound)
unreliable.OnServerEvent:Connect(onInbound)

-- frame loop: Quake host frames clamped like host.c (max 0.1s per tick)
RunService.Heartbeat:Connect(function(dt: number)
	if not svr.active then
		return
	end
	host.frame(svr, math.clamp(dt, 0.001, 0.1))

	-- level change requested by QC (trigger_changelevel)
	local nextLevel = svr.changelevelTo
	if nextLevel then
		svr.changelevelTo = nil
		print(`[robloquake] changelevel to {nextLevel}`)
		host.spawnServer(svr, nextLevel)
		for _, slot in slotByPlayer do
			host.connectClient(svr, slot)
		end
	end
end)

print("[robloquake] server running: " .. START_MAP)
