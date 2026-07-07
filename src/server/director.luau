--!strict
-- Match director (PRODUCT layer, NOT engine). Owns map rotation,
-- map voting (opened at intermission, or mid-game by any player via
-- "callvote"), and live admin control of the match parameter set, for
-- BOTH engine boots via a small adapter.
--
-- REMOVAL: delete this file, src/client/directorui.luau, and the
-- marked "match director" attach blocks in init.server.luau /
-- qwserver.luau / init.client.luau / qwclient.luau. The engines revert
-- to authentic behavior (dm maps loop forever, params fixed at boot).
--
-- The engine is touched at exactly one seam: the boot passes each
-- QC-requested changelevel target through resolveChangelevel(), and
-- the director may substitute a different map name. Everything else
-- rides attributes, cvar sets the boots already do, and one
-- RemoteEvent ("Director") that this module creates itself.

local director = {}

--------------------------------------------------------------------------
-- pure logic (lune-tested; no services touched)

function director.parseMaplist(s: any): { string }
	local list: { string } = {}
	if typeof(s) == "string" then
		for name in s:gmatch("%S+") do
			table.insert(list, name)
		end
	end
	return list
end

-- next entry after `current` in rotation order (wrap); first entry when
-- current is not in the list; nil for an empty list
function director.rotationNext(list: { string }, current: string): string?
	if #list == 0 then
		return nil
	end
	for i, name in list do
		if name == current then
			return list[i % #list + 1]
		end
	end
	return list[1]
end

-- up to n distinct vote candidates starting at the rotation successor,
-- excluding the current map
function director.candidates(list: { string }, current: string, n: number): { string }
	local out: { string } = {}
	local start = 1
	for i, name in list do
		if name == current then
			start = i + 1
			break
		end
	end
	for k = 0, #list - 1 do
		local name = list[(start + k - 1) % #list + 1]
		if name ~= current and not table.find(out, name) then
			table.insert(out, name)
			if #out >= n then
				break
			end
		end
	end
	return out
end

-- counts per candidate index from a votes map ({voterKey -> index})
function director.tally(votes: { [any]: number }, ncandidates: number): { number }
	local counts = table.create(ncandidates, 0)
	for _, i in votes do
		if i >= 1 and i <= ncandidates then
			counts[i] += 1
		end
	end
	return counts
end

-- winning candidate: most votes; ties break toward the earlier candidate
-- (rotation order); zero votes -> fallback
function director.winner(candidateMaps: { string }, counts: { number }, fallback: string?): string?
	local best, bestCount = nil, 0
	for i, name in candidateMaps do
		local n = counts[i] or 0
		if n > bestCount then
			best, bestCount = name, n
		end
	end
	return best or fallback
end

--------------------------------------------------------------------------
-- runtime

export type Adapter = {
	assets: Instance, -- attribute source of truth (QuakeAssets)
	net: Instance, -- folder to parent the Director RemoteEvent under
	isHost: (player: Player) -> boolean,
	getCurrentMap: () -> string,
	getIntermission: () -> boolean,
	forceChangelevel: (map: string) -> (),
	setRule: (name: string, value: number) -> (), -- live cvar set
	getRule: (name: string) -> number?,
	-- host admin tools (Host_Status_f/Host_Ping_f/Host_Kick_f per engine):
	-- returns a report string for "status"/"ping"; performs "kick <name>"
	adminCommand: ((cmd: string, arg: string) -> string?)?,
}

-- rules admins may change live (cvars both QC codebases re-read while
-- running); engine/game/mod/startmap are boot-time and shown read-only
local LIVE_RULES = {
	"deathmatch",
	"coop",
	"teamplay",
	"skill",
	"fraglimit",
	"timelimit",
	"samelevel",
	"noexit",
}
local DEFAULT_VOTETIME = 30
local CALLVOTE_COOLDOWN = 60 -- seconds after a player-called vote closes

function director.attach(a: Adapter)
	local Players = game:GetService("Players")

	local remote = Instance.new("RemoteEvent")
	remote.Name = "Director"
	remote.Parent = a.net

	local voteOpen = false
	local voteCalled = false -- current vote was player-called (mid-game)
	local nextCallvoteAt = 0
	local voteMaps: { string } = {}
	local voteDeadline = 0
	local votes: { [Player]: number } = {}
	local wasIntermission = false

	local function maplist(): { string }
		return director.parseMaplist(a.assets:GetAttribute("maplist"))
	end

	local function statePayload(player: Player)
		local rules: { [string]: number } = {}
		for _, name in LIVE_RULES do
			rules[name] = a.getRule(name) or 0
		end
		return {
			t = "state",
			isAdmin = a.isHost(player),
			map = a.getCurrentMap(),
			rules = rules,
			maplist = a.assets:GetAttribute("maplist") or "",
			avatars = a.assets:GetAttribute("roblox_avatars") == true,
			engine = a.assets:GetAttribute("engine") or "nq",
			game = a.assets:GetAttribute("game") or "id1",
			mod = a.assets:GetAttribute("gamedir") or "", -- boot attr is "gamedir"
		}
	end

	local function broadcastState()
		for _, p in Players:GetPlayers() do
			remote:FireClient(p, statePayload(p))
		end
	end

	local function broadcastCounts()
		remote:FireAllClients({ t = "voteCounts", counts = director.tally(votes, #voteMaps) })
	end

	local function closeVote()
		if voteOpen then
			voteOpen = false
			remote:FireAllClients({ t = "voteEnd" })
		end
		if voteCalled then
			nextCallvoteAt = os.clock() + CALLVOTE_COOLDOWN
		end
		voteCalled = false
		table.clear(votes)
		voteMaps = {}
	end

	-- open the 3-candidate map vote; false when the maplist yields none
	local function openVote(): boolean
		voteMaps = director.candidates(maplist(), a.getCurrentMap(), 3)
		if #voteMaps == 0 then
			return false
		end
		table.clear(votes)
		voteOpen = true
		local vt = tonumber(a.assets:GetAttribute("votetime")) or DEFAULT_VOTETIME
		voteDeadline = os.clock() + vt
		remote:FireAllClients({ t = "voteBegin", maps = voteMaps, secondsLeft = vt })
		broadcastCounts()
		return true
	end

	local function currentWinner(): string?
		local list = maplist()
		local fallback = director.rotationNext(list, a.getCurrentMap())
		return director.winner(voteMaps, director.tally(votes, #voteMaps), fallback)
	end

	remote.OnServerEvent:Connect(function(player: Player, msg: any)
		if typeof(msg) ~= "table" or typeof(msg.t) ~= "string" then
			return
		end
		if msg.t == "hello" then
			remote:FireClient(player, statePayload(player))
			if voteOpen then
				remote:FireClient(player, {
					t = "voteBegin",
					maps = voteMaps,
					secondsLeft = math.max(0, voteDeadline - os.clock()),
				})
				broadcastCounts()
			end
		elseif msg.t == "vote" then
			local i = tonumber(msg.i)
			print(`[director] vote msg from {player.Name}: i={tostring(i)} open={tostring(voteOpen)} nmaps={#voteMaps}`)
			if voteOpen and i and i >= 1 and i <= #voteMaps then
				votes[player] = i
				broadcastCounts()
			end
		elseif msg.t == "callvote" then
			-- rock-the-vote (top-right MAP plaque / M): anyone may open
			-- the map vote mid-game. An already-open vote is just re-sent
			-- to the caller; the cooldown blunts spam after one closes.
			if voteOpen then
				remote:FireClient(player, {
					t = "voteBegin",
					maps = voteMaps,
					secondsLeft = math.max(0, voteDeadline - os.clock()),
				})
				broadcastCounts()
			elseif os.clock() >= nextCallvoteAt then
				voteCalled = true
				if openVote() then
					print(`[director] vote called by {player.Name}: {table.concat(voteMaps, ",")}`)
				else
					voteCalled = false
				end
			end
		elseif msg.t == "set" then
			if not a.isHost(player) then
				return
			end
			local v = tonumber(msg.value)
			if typeof(msg.key) == "string" and v and table.find(LIVE_RULES, msg.key) then
				a.setRule(msg.key, v)
				a.assets:SetAttribute(msg.key, v) -- survives restarts
				broadcastState()
			end
		elseif msg.t == "maplist" then
			if not a.isHost(player) then
				return
			end
			if typeof(msg.value) == "string" then
				a.assets:SetAttribute("maplist", msg.value)
				broadcastState()
			end
		elseif msg.t == "map" then
			if not a.isHost(player) then
				return
			end
			local name = if typeof(msg.value) == "string" then msg.value:match("^[%w_%-]+$") else nil
			if name then
				closeVote()
				a.forceChangelevel(name)
			end
		elseif msg.t == "avatars" then
			if not a.isHost(player) then
				return
			end
			a.assets:SetAttribute("roblox_avatars", msg.value == true)
			broadcastState()
		elseif msg.t == "admin" then
			-- host tools: status/ping reports + kick (Host_*_f per engine)
			if not a.isHost(player) then
				return
			end
			local fn = a.adminCommand
			if fn and typeof(msg.cmd) == "string" then
				local report = fn(msg.cmd, if typeof(msg.arg) == "string" then msg.arg else "")
				if report then
					remote:FireClient(player, { t = "report", text = report })
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		if votes[player] then
			votes[player] = nil
			if voteOpen then
				broadcastCounts()
			end
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			remote:FireClient(player, statePayload(player))
		end)
	end)

	local api = {}

	-- call every server heartbeat: opens the vote on the intermission
	-- rising edge and force-advances when the vote expires (idle players
	-- would otherwise hold intermission forever)
	function api.step()
		local inter = a.getIntermission()
		if inter and not wasIntermission and openVote() then
			-- an open called vote is absorbed: fresh candidates + clock
			voteCalled = false
			print(`[director] vote open: {table.concat(voteMaps, ",")}`)
		end
		wasIntermission = inter
		if voteOpen and os.clock() > voteDeadline then
			local counts = director.tally(votes, #voteMaps)
			local total = 0
			for _, n in counts do
				total += n
			end
			local w = currentWinner()
			local fizzle = voteCalled and total == 0
			print(`[director] vote expired: {table.concat(voteMaps, ",")} counts={table.concat(counts, ",")} -> {if fizzle then "fizzled" else w or "?"}`)
			closeVote()
			-- a called vote nobody voted in fizzles; the intermission vote
			-- must always advance (idle players would hold it forever)
			if w and not fizzle then
				a.forceChangelevel(w)
			end
		end
	end

	-- the single engine seam: the boot passes every QC changelevel target
	-- through here and loads what comes back
	function api.resolveChangelevel(qcTarget: string): string
		local current = a.getCurrentMap()
		local list = maplist()
		local answer = qcTarget
		if #list > 0 and qcTarget == current then
			-- stock DM "loop the same map": rotation/vote takes over. A
			-- DIFFERENT target means a real exit or a mod's own rotation
			-- (e.g. Rocket Arena localinfo) — mods always win untouched.
			answer = currentWinner() or qcTarget
			print(`[director] rotation: {qcTarget} -> {answer} (votes={table.concat(director.tally(votes, #voteMaps), ",")})`)
		elseif #list > 0 then
			print(`[director] explicit target {qcTarget} respected (mod/exit/admin)`)
		end
		closeVote()
		task.defer(broadcastState)
		return answer
	end

	return api
end

return director
