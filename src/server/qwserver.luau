--!strict
-- QuakeWorld server boot: selected when QuakeAssets has attribute
-- engine="qw". Runs qwsv over both remotes: per-frame datagrams ride
-- the UnreliableRemoteEvent (netchan sequencing absorbs drops and
-- reorders, as over UDP), while packets carrying netchan-reliable
-- content — and anything over the ~900-byte unreliable payload cap —
-- ride the reliable RemoteEvent so the content-driven handshake
-- lockstep can never lose a packet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local engine = Shared.engine

local cvarlib = require(engine.common.cvar)
local qwsv = require(engine.qw.qwsv)
local vfs = require(engine.common.vfs)
local vmlib = require(engine.progs.vm)
local prdebug = require(engine.progs.prdebug)

local assetchunks = require(script.Parent.assetchunks)
local clientbundle = require(script.Parent.clientbundle)
local directorlib = require(script.Parent.director)
local bsplib = require(engine.bsp.bsp)

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
			print(`[fragparty] {name} = {v}`)
		end
	end

	-- Rocket Arena-style rotation: the mod ships rotate.cfg ("localinfo
	-- <map> <nextmap>" lines) that real servers +exec at boot; apply the
	-- pairs so the progs' PF_infokey rotation lookup sees the chain
	local rotateCfg = vfs.loadFile(ctx.fsys, "rotate.cfg")
	if rotateCfg then
		local n = 0
		for k, v in buffer.tostring(rotateCfg):gmatch("localinfo%s+(%S+)%s+(%S+)") do
			svr.localinfo[k] = v
			n += 1
		end
		print(`[fragparty] rotate.cfg: {n} localinfo rotation entries applied`)
	end

	qwsv.spawnServer(svr, ctx.startMap)
	assert(svr.active, "QW server failed to spawn")
	_G.RQ_SERVER = svr -- studio debugging access

	local bundle = clientbundle.new(ctx.fsys, ctx.gameDir, ctx.gameFolder, ctx.modDir, ctx.modFolder)
	bundle.clientFS:SetAttribute("engine", "qw")
	bundle.publishAll(svr)

	-- Roblox avatars mode (product layer, SHARED module with the NQ boot):
	-- publishes rigs + mirrors the roblox_avatars toggle; this boot also
	-- sets RQSlot on connect and mirrors RQWeaponModel in the heartbeat
	local publishAvatarRig = require(script.Parent.avatarrigs)(ctx.assets, bundle.clientFS)

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
	-- replicated GLOBAL-admin flag: clients gate dev surfaces (tweaks menu,
	-- engine menu, console) on this. Deliberately NOT playerIsHost — a
	-- private-server owner gets match control, not dev tooling. RQHost is
	-- the separate host flag (pausemenu reserves the director-gear slot
	-- next to its plaques only when it's set).
	local isGlobalAdmin = require(script.Parent.globaladmins)
	local function stampAdmin(p: Player)
		p:SetAttribute("RQAdmin", isGlobalAdmin(p))
		p:SetAttribute("RQHost", playerIsHost(p))
	end
	Players.PlayerAdded:Connect(stampAdmin)
	for _, p in Players:GetPlayers() do
		stampAdmin(p)
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
		getMapTitle = function(name: string): string?
			-- worldspawn "message" from the map's BSP (entity lump only)
			local buf = vfs.loadFile(ctx.fsys, `maps/{name}.bsp`)
			return if buf then bsplib.readTitle(buf) else nil
		end,
		broadcastPrint = function(text: string)
			-- callvote announcements ride the engine notify surface
			svr.broadcastPrint(svr, 2, text .. "\n") -- PRINT_HIGH
		end,
		adminCommand = function(cmd: string, arg: string): string?
			-- SV_Status-style report / pings / SV_Kick_f for the admin menu
			if cmd == "status" then
				local lines = { `map:     {svr.name}\n`, "userid frags name\n------ ----- ----\n" }
				for i = 1, svr.maxclients do
					local c2 = svr.clients[i]
					if c2.active then
						table.insert(lines, ("%6i %5i %s\n"):format(c2.userid or 0, (c2 :: any).old_frags or 0, c2.name))
					end
				end
				return table.concat(lines)
			elseif cmd == "ping" then
				local lines = { "Client ping times:\n" }
				for i = 1, svr.maxclients do
					local c2 = svr.clients[i]
					if c2.active then
						local total, n = 0, 0
						for _, fr in c2.frames do
							if fr.ping_time and fr.ping_time >= 0 then
								total += fr.ping_time
								n += 1
							end
						end
						table.insert(lines, ("%4i %s\n"):format(if n > 0 then math.floor(total / n * 1000) else 0, c2.name))
					end
				end
				return table.concat(lines)
			elseif cmd == "kick" and arg ~= "" then
				for i = 1, svr.maxclients do
					local c2 = svr.clients[i]
					if c2.active and c2.name:lower() == arg:lower() then
						qwsv.kick(svr, c2.userid)
						return `kicked {arg}\n`
					end
				end
				return `can't kick {arg}\n`
			end
			return nil
		end,
	})
	-- ===== end match director =====

	-- player <-> client slot bridging
	local slotByPlayer: { [Player]: number } = {}

	-- ===== stats pipeline (PRODUCT layer) — twin of the NQ block; see
	-- src/server/stats.luau for the REMOVAL note =====
	local statscorelib = require(script.Parent.statscore)
	local statstorelib = require(script.Parent.statstore)
	local statslib = require(script.Parent.stats)
	local statsRead: statslib.SlotRead = { frags = 0, health = 0, deadflag = 0, weapon = 0 }
	-- hoisted out of the attach call: the shop + prefstore blocks below need
	-- the store (Frag Coins wallet + owned skins live on it)
	local statsStore = statstorelib.new({
		modekey = statscorelib.deriveModeKey({
			modekey = ctx.assets:GetAttribute("modekey") :: any,
			engine = ctx.assets:GetAttribute("engine") :: any,
			gamedir = ctx.assets:GetAttribute("gamedir") :: any,
			deathmatch = ctx.assets:GetAttribute("deathmatch") :: any,
			coop = ctx.assets:GetAttribute("coop") :: any,
			teamplay = ctx.assets:GetAttribute("teamplay") :: any,
		}),
		net = ctx.reliable.Parent :: Instance,
	})
	local statsApi = statslib.attach({
		store = statsStore,
		maxclients = svr.maxclients,
		playerBySlot = function(slot: number): Player?
			for p, s in slotByPlayer do
				if s == slot then
					return p
				end
			end
			return nil
		end,
		readSlot = function(slot: number): statslib.SlotRead?
			local cl = svr.clients[slot]
			if not (cl and cl.active and cl.edict) or cl.spectator then
				return nil
			end
			local ent = svr.qdefs.ent
			statsRead.frags = vmlib.edFloat(cl.edict, ent.frags)
			statsRead.health = vmlib.edFloat(cl.edict, ent.health)
			statsRead.deadflag = vmlib.edFloat(cl.edict, ent.deadflag)
			statsRead.weapon = vmlib.edFloat(cl.edict, ent.weapon)
			return statsRead
		end,
		getIntermission = function()
			local d = svr.vm.progs.globaldefsByName["intermission_running"]
			return d ~= nil and vmlib.globalFloat(svr.vm, d.ofs) ~= 0
		end,
		getCurrentMap = function()
			return svr.name
		end,
		competitive = (tonumber(ctx.assets:GetAttribute("deathmatch")) or 1) ~= 0,
	})
	-- ===== end stats pipeline =====

	-- ===== prefs persistence (PRODUCT layer) — twin of the NQ block; see
	-- src/server/prefstore.luau for the REMOVAL note =====
	require(script.Parent.prefstore)(ctx.reliable.Parent :: Instance, statsStore.isOwned)
	-- ===== end prefs persistence =====

	-- ===== shop (PRODUCT layer) — twin of the NQ block; Frag Coin + Robux
	-- skin purchases against the statstore wallet; see src/server/shop.luau
	-- for the REMOVAL note =====
	require(script.Parent.shop)({ net = ctx.reliable.Parent :: Instance, store = statsStore })
	-- ===== end shop =====

	-- ===== host greeting (PRODUCT layer) — twin of the NQ block; see
	-- src/server/hostgreeting.luau for the REMOVAL note =====
	local greetHost = require(script.Parent.hostgreeting)({
		isHost = playerIsHost,
		sendPrint = function(player: Player, text: string)
			local slot = slotByPlayer[player]
			local client = slot and svr.clients[slot]
			if client and client.active then
				local qwp = require(engine.qw.qwprotocol)
				svr.clientPrint(svr, client, qwp.PRINT_HIGH, text)
			end
		end,
	})
	-- ===== end host greeting =====

	-- per-client cmd arrival diagnostics: upstream burstiness is where
	-- remote-player render artifacts originate — one line per client
	-- every 30s in the server log (owner-visible via F9 → Server)
	local arrival: { [number]: { n: number, last: number, maxGap: number, t0: number } } = {}

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
		arrival[slot] = nil -- fresh diagnostics window for a reused slot
		local client = qwsv.wireConnect(svr, slot, { name = player.Name }, function(packet: buffer, hasReliable: boolean?)
			-- per-frame datagrams go unreliable so loss/batching on real
			-- networks can't head-of-line stall the movement stream;
			-- netchan-reliable content also rides the reliable remote as
			-- the delivery guarantee (the second copy to arrive is
			-- discarded as a stale sequence). Payloads over ~900 bytes
			-- are silently dropped by unreliable remotes: reliable-only.
			local fits = buffer.len(packet) <= 850
			if fits then
				ctx.unreliable:FireClient(player, packet)
			end
			if hasReliable or not fits then
				ctx.reliable:FireClient(player, packet)
			end
		end)
		-- PF_infokey("ip"): stable transport identity in place of a
		-- remote address (mods use it for ban/identity logic)
		client.address = tostring(player.UserId)
		-- avatars mode plumbing: clients map QW player number -> Player by
		-- slot (wire playernum = slot - 1)
		player:SetAttribute("RQSlot", slot)
		publishAvatarRig(player)
		greetHost(player) -- host greeting (PRODUCT layer)
		print(`[fragparty] {player.Name} connected as qw client {slot}`)
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
		local now = os.clock()
		local a = arrival[slot]
		if not a then
			a = { n = 0, last = now, maxGap = 0, t0 = now }
			arrival[slot] = a
		end
		if a.n > 0 then
			a.maxGap = math.max(a.maxGap, now - a.last)
		end
		a.n += 1
		a.last = now
		if now - a.t0 >= 30 then
			local rate = a.n / (now - a.t0)
			print(
				`[qwsv net] c{slot} {player.Name}: {math.floor(rate + 0.5)} pkts/s`
					.. ` maxgap={math.floor(a.maxGap * 1000 + 0.5)}ms PL={svr.clients[slot].lossage}%`
			)
			a.n, a.maxGap, a.t0 = 0, 0, now
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
		-- stuff "changing"/"reconnect" like SV_Map_f — the client answers
		-- with "new" and redoes the soundlist/modellist/prespawn/spawn/
		-- begin handshake. The serverdata must be the paired reply to
		-- that "new" packet: an unsolicited push here skews the strict
		-- 1:1 sequence exchange the delta-frame lookup is keyed by
		dir.step() -- match director: vote lifecycle + idle expiry
		statsApi.step(dt) -- stats pipeline: frag/death capture + autosave

		local nextLevel = svr.changelevelTo
		if nextLevel then
			svr.changelevelTo = nil
			nextLevel = dir.resolveChangelevel(nextLevel) -- rotation/vote seam
			print(`[fragparty] qw changelevel to {nextLevel}`)
			qwsv.saveSpawnparms(svr) -- inventory carries across levels
			qwsv.spawnServer(svr, nextLevel)
			bundle.publishAll(svr)
			for i = 1, svr.maxclients do
				local client = svr.clients[i]
				if client.active then
					client.spawned = false
				end
			end
			qwsv.broadcastCommand(svr, "changing\n")
			qwsv.broadcastCommand(svr, "reconnect\n")
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
			elseif verb == "god" or verb == "noclip" or verb == "give" then
				-- SV_God_f / SV_Noclip_f / SV_Give_f: host-gated cheats by
				-- userid (the host gate replaces C's -cheats launch flag);
				-- "god <uid>", "noclip <uid>", "give <uid> <what> [amount]"
				local uid, tail = rest:match("^(%d+)%s*(.*)$")
				if uid then
					if verb == "god" then
						qwsv.godF(svr, tonumber(uid) :: number)
					elseif verb == "noclip" then
						qwsv.noclipF(svr, tonumber(uid) :: number)
					else
						local what, amount = tail:match("^(%S+)%s*(%d*)$")
						qwsv.giveF(svr, tonumber(uid) :: number, what or "", tonumber(amount or "") or 0)
					end
				end
			elseif verb == "serverinfo" then
				-- SV_Serverinfo_f: bare prints the table, "key value" sets
				-- + broadcasts svc_serverinfo
				local k, v = rest:match("^(%S+)%s*(.*)$")
				if k then
					qwsv.setServerinfo(svr, k, v)
				else
					svr.print("Server info settings:\n" .. qwsv.infoPrint(svr.serverinfo))
				end
			elseif verb == "edicts" then
				svr.print(prdebug.edPrintEdicts(svr.vm)) -- ED_PrintEdicts
			elseif verb == "edict" then
				svr.print(prdebug.edPrintNum(svr.vm, tonumber(rest) or 0)) -- ED_PrintEdict_f
			elseif verb == "edictcount" then
				svr.print(prdebug.edCount(svr.vm)) -- ED_Count
			elseif verb == "profile" then
				svr.print(prdebug.profileReport(svr.vm)) -- PR_Profile_f
			end
		end

		diagAccum += dt
		if diagAccum > 0.5 then
			diagAccum = 0
			-- avatars mode: mirror each player's held weapon (v_ viewmodel
			-- name) so clients can attach the matching world model to rigs
			for player, slot in slotByPlayer do
				local cl = svr.clients[slot]
				if cl and cl.spawned and cl.edict then
					local wm = vmlib.edString(svr.vm, cl.edict, svr.qdefs.ent.weaponmodel)
					if player:GetAttribute("RQWeaponModel") ~= wm then
						player:SetAttribute("RQWeaponModel", wm)
					end
				end
			end
			-- SV_*/SVDBG_* diagnostics are debug-only, gated behind RQDBG
			-- like the NQ boot (audit H9); verify tools set RQDBG first
			local ServerStorage = game:GetService("ServerStorage")
			local dbg = ServerStorage:GetAttribute("RQDBG") and true or false
			if dbg then
				ServerStorage:SetAttribute("SV_Time", svr.time)
				ServerStorage:SetAttribute("SV_Edicts", svr.vm.num_edicts)
				ServerStorage:SetAttribute("SV_Engine", "qw")
			end
			local c1 = svr.clients[1]
			if dbg and c1 and c1.spawned then
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
