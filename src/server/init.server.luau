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

-- start map: attribute override, else per-game default

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
local gameDir = assets:GetAttribute("game")
if typeof(gameDir) ~= "string" then
	gameDir = "id1"
end
local gameFolder = assets:WaitForChild(gameDir)

local startAttr = assets:GetAttribute("startmap")
local START_MAP = if typeof(startAttr) == "string" then startAttr else "start"

local fsys = vfs.new()
for _, pakName in { "pak0", "pak1" } do
	local pack = loadPak(gameFolder, pakName)
	if pack then
		vfs.addPack(fsys, pack)
		print(`[robloquake] loaded {gameDir}/{pakName}.pak ({pack.numfiles} files)`)
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
