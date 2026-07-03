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
_G.RQ_SERVER = svr -- studio debugging access

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
		end
	end

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
