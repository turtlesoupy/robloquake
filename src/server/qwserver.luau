--!strict
-- QuakeWorld server boot: selected when QuakeAssets has attribute
-- engine="qw". Runs qwsv over the reliable RemoteEvent (netchan-lite
-- carries its reliable stream in-band; a single ordered channel keeps
-- the stale-packet guard race-free — splitting datagrams onto the
-- unreliable remote needs real reliable-retransmit netchan first).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local cvarlib = require(engine.common.cvar)
local qwsv = require(engine.qw.qwsv)
local vfs = require(engine.common.vfs)

local assetchunks = require(script.Parent.assetchunks)
local clientbundle = require(script.Parent.clientbundle)

export type Ctx = {
	fsys: vfs.Vfs,
	assets: Instance,
	gameFolder: Instance,
	gameDir: string,
	startMap: string,
	reliable: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
}

return function(ctx: Ctx)
	-- qwprogs.dat ships as a chunked asset (it is not inside the paks):
	-- tools/build_assets.py --file <path-to>/qwprogs.dat
	local qwprogsFolder = ctx.gameFolder:FindFirstChild("qwprogs") or ctx.assets:FindFirstChild("qwprogs")
	assert(qwprogsFolder, "engine=qw needs a qwprogs asset (tools/build_assets.py --file qwprogs.dat)")
	local qwprogsBuf = assetchunks.loadRaw(qwprogsFolder)

	local svr = qwsv.newGame(ctx.fsys, qwprogsBuf)
	svr.print = function(s: string)
		print("[qwsv] " .. s)
	end

	-- game-rule cvars from asset-folder attributes, applied before the
	-- world spawns so qwprogs sees them
	for _, name in { "deathmatch", "teamplay", "fraglimit", "timelimit", "samelevel" } do
		local v = ctx.assets:GetAttribute(name)
		if typeof(v) == "number" then
			cvarlib.setValue(svr.cvars, name, v)
			print(`[robloquake] {name} = {v}`)
		end
	end

	qwsv.spawnServer(svr, ctx.startMap)
	assert(svr.active, "QW server failed to spawn")
	_G.RQ_SERVER = svr -- studio debugging access

	local bundle = clientbundle.new(ctx.fsys, ctx.gameDir, ctx.gameFolder)
	bundle.clientFS:SetAttribute("engine", "qw")
	bundle.publishAll(svr)

	-- player <-> client slot bridging
	local slotByPlayer: { [Player]: number } = {}

	local function connectPlayer(player: Player): number?
		local slot: number? = nil
		for i = 1, svr.maxclients do
			if not svr.clients[i].active then
				slot = i
				break
			end
		end
		if not slot then
			player:Kick("Server is full")
			return nil
		end
		slotByPlayer[player] = slot
		qwsv.wireConnect(svr, slot, { name = player.Name }, function(packet: buffer)
			ctx.reliable:FireClient(player, packet)
		end)
		print(`[robloquake] {player.Name} connected as qw client {slot}`)
		return slot
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		local slot = slotByPlayer[player]
		if slot then
			slotByPlayer[player] = nil
			local client = svr.clients[slot]
			if client.active then
				qwsv.dropClient(svr, client)
			end
		end
	end)

	-- clients announce themselves with their first packet (remote
	-- handlers must be live before the handshake replies are sent)
	local function onInbound(player: Player, data: unknown)
		if typeof(data) ~= "buffer" then
			return
		end
		local slot = slotByPlayer[player] or connectPlayer(player)
		if not slot then
			return
		end
		local client = svr.clients[slot]
		if client.active then
			-- QW processes client packets on arrival (SV_ReadPackets)
			-- and replies immediately — exactly one reply per packet,
			-- which the delta/prediction sequence lockstep requires
			qwsv.executeClientMessage(svr, client, data :: buffer)
			qwsv.replyToClient(svr, client)
		end
	end
	ctx.reliable.OnServerEvent:Connect(onInbound)
	ctx.unreliable.OnServerEvent:Connect(onInbound)

	-- SV_Frame: physics tick + one reply per client packet received
	local diagAccum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if not svr.active then
			return
		end
		qwsv.frame(svr, math.clamp(dt, 0.001, 0.1))

		diagAccum += dt
		if diagAccum > 0.5 then
			diagAccum = 0
			local ServerStorage = game:GetService("ServerStorage")
			ServerStorage:SetAttribute("SV_Time", svr.time)
			ServerStorage:SetAttribute("SV_Edicts", svr.vm.num_edicts)
			ServerStorage:SetAttribute("SV_Engine", "qw")
			local c1 = svr.clients[1]
			if c1 and c1.spawned then
				local vmlib = require(engine.progs.vm)
				local o = vmlib.edVector(c1.edict, svr.qdefs.ent.origin)
				ServerStorage:SetAttribute("SV_Origin", Vector3.new(o.x, o.y, o.z))
			end
		end
	end)
end
