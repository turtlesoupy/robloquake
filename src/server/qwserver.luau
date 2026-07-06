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
local vmlib = require(engine.progs.vm)

local assetchunks = require(script.Parent.assetchunks)
local clientbundle = require(script.Parent.clientbundle)
local directorlib = require(script.Parent.director)

export type Ctx = {
	fsys: vfs.Vfs,
	assets: Instance,
	gameFolder: Instance,
	gameDir: string,
	modDir: string?,
	modFolder: Instance?,
	startMap: string,
	reliable: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
}

return function(ctx: Ctx)
	-- qwprogs.dat: the authentic path is COM_LoadFile through the searchpath
	-- stack (a mod gamedir's pak wins over the base game). The base games
	-- ship it OUTSIDE their paks as a chunked asset instead
	-- (tools/build_assets.py --file <path-to>/qwprogs.dat), so fall back to
	-- the chunk folders: mod dir first, then base game, then the assets root.
	local qwprogsBuf = vfs.loadFile(ctx.fsys, "qwprogs.dat")
	if not qwprogsBuf then
		local qwprogsFolder = (ctx.modFolder and ctx.modFolder:FindFirstChild("qwprogs"))
			or ctx.gameFolder:FindFirstChild("qwprogs")
			or ctx.assets:FindFirstChild("qwprogs")
		assert(
			qwprogsFolder,
			"engine=qw needs qwprogs.dat in a searchpath pak or as a chunked asset"
				.. " (tools/build_assets.py --file qwprogs.dat)"
		)
		qwprogsBuf = assetchunks.loadRaw(qwprogsFolder)
	end

	local svr = qwsv.newGame(ctx.fsys, qwprogsBuf)
	svr.print = function(s: string)
		print("[qwsv] " .. s)
	end
	-- player speech must pass Roblox text filtering: clients speak through
	-- TextChatService, and the server refuses raw wire say from anyone
	svr.suppressSay = true

	-- game-rule cvars from asset-folder attributes, applied before the
	-- world spawns so qwprogs sees them
	for _, name in { "deathmatch", "teamplay", "fraglimit", "timelimit", "samelevel" } do
		local v = ctx.assets:GetAttribute(name)
		if typeof(v) == "number" then
			cvarlib.setValue(svr.cvars, name, v)
			-- these are CVAR_SERVERINFO cvars in C (sv_main.c SV_InitLocal):
			-- setting one mirrors into the serverinfo string the clients
			-- read (teamplay gates Sbar_TeamOverlay client-side)
			svr.serverinfo[name] = tostring(v)
			print(`[robloquake] {name} = {v}`)
		end
	end

	qwsv.spawnServer(svr, ctx.startMap)
	assert(svr.active, "QW server failed to spawn")
	_G.RQ_SERVER = svr -- studio debugging access

	local bundle = clientbundle.new(ctx.fsys, ctx.gameDir, ctx.gameFolder, ctx.modDir, ctx.modFolder)
	bundle.clientFS:SetAttribute("engine", "qw")
	bundle.publishAll(svr)

	-- ===== match director (PRODUCT layer) — twin of the NQ block; see
	-- src/server/director.luau for the REMOVAL note =====
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
	end
	local dir = directorlib.attach({
		assets = ctx.assets,
		net = ctx.reliable.Parent :: Instance,
		isHost = playerIsHost,
		getCurrentMap = function()
			return svr.name
		end,
		getIntermission = function()
			local d = svr.vm.progs.globaldefsByName["intermission_running"]
			return d ~= nil and vmlib.globalFloat(svr.vm, d.ofs) ~= 0
		end,
		forceChangelevel = function(m: string)
			svr.changelevelTo = m
		end,
		setRule = function(name: string, v: number)
			cvarlib.setValue(svr.cvars, name, v)
		end,
		getRule = function(name: string)
			return cvarlib.value(svr.cvars, name)
		end,
	})
	-- ===== end match director =====

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

		-- level change requested by qwprogs (fraglimit/timelimit/
		-- changelevel): respawn the server, republish the bundle, and
		-- send every connected client a fresh serverdata — they redo
		-- the soundlist/modellist/prespawn/spawn/begin handshake
		dir.step() -- match director: vote lifecycle + idle expiry

		local nextLevel = svr.changelevelTo
		if nextLevel then
			svr.changelevelTo = nil
			nextLevel = dir.resolveChangelevel(nextLevel) -- rotation/vote seam
			print(`[robloquake] qw changelevel to {nextLevel}`)
			qwsv.saveSpawnparms(svr) -- inventory carries across levels
			qwsv.spawnServer(svr, nextLevel)
			bundle.publishAll(svr)
			for i = 1, svr.maxclients do
				local client = svr.clients[i]
				if client.active and client.send then
					client.spawned = false
					qwsv.newF(svr, client)
					client.send_message = true
					qwsv.replyToClient(svr, client)
				end
			end
		end

		-- host commands from Studio / the owner UI: "kick <uid>",
		-- "say <text>", "changelevel <map>" (SV_ConSay_f / SV_Kick_f)
		local ServerStorage = game:GetService("ServerStorage")
		local hostCmd = ServerStorage:GetAttribute("QW_HostCmd")
		if typeof(hostCmd) == "string" and hostCmd ~= "" then
			ServerStorage:SetAttribute("QW_HostCmd", "")
			local verb, rest = hostCmd:match("^(%S+)%s*(.*)$")
			if verb == "kick" then
				qwsv.kick(svr, tonumber(rest) or -1)
			elseif verb == "say" then
				qwsv.conSay(svr, rest)
			elseif verb == "changelevel" and rest ~= "" then
				svr.changelevelTo = rest
			elseif verb == "localinfo" then
				-- SV_Localinfo_f: "localinfo key value" ("" clears)
				local k, v = rest:match("^(%S+)%s*(.*)$")
				if k then
					svr.localinfo[k] = if v ~= "" then v else nil
				end
			end
		end

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

				-- debug teleport (same contract as the NQ boot's
				-- SVDBG_SetOrigin): probe the exact spot then nearby
				-- offsets, keep the first non-solid placement
				local tp = ServerStorage:GetAttribute("SVDBG_SetOrigin")
				if typeof(tp) == "Vector3" then
					ServerStorage:SetAttribute("SVDBG_SetOrigin", nil)
					local qwworld = require(engine.qw.qwworld)
					local ent = svr.qdefs.ent
					local before = vmlib.edVector(c1.edict, ent.origin)
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
						vmlib.edSetVector(c1.edict, ent.origin, cand)
						vmlib.edSetVector(c1.edict, ent.velocity, vector.zero)
						qwworld.linkEdict(svr.world, c1.edict, false)
						if not qwworld.testEntityPosition(svr.world, c1.edict) then
							placed = true
							print("[svdbg] qw teleported player to", cand)
							break
						end
					end
					if not placed then
						vmlib.edSetVector(c1.edict, ent.origin, before)
						qwworld.linkEdict(svr.world, c1.edict, false)
						print("[svdbg] qw teleport failed: all candidates solid")
					end
				end
			end
		end
	end)
end
