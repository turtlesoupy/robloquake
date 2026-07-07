--!strict
-- Match director (PRODUCT layer, NOT engine). Owns map rotation,
-- intermission map voting, and live admin control of the match
-- parameter set, for BOTH engine boots via a small adapter.
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

-- Kid-friendly menu names for the handful of LibreQuake levels whose
-- worldspawn "message" isn't right for a young audience (mostly violence
-- / occult wording). Keyed by BSP file name; the value replaces the real
-- title in the UI only — the shipped maps and assets are untouched.
local TITLE_OVERRIDES: { [string]: string } = {
	lqdm2 = "Grotto", -- "Torture Pit"
	lqdm10 = "Midnight Gambit", -- "Lucifer's Gambit"
	lqdm13 = "No Way Back", -- "Death Provides No Return"
}

-- Menu label for a map: the (possibly overridden) level title with the
-- codename appended, e.g. "Grotto (lqdm2)". Falls back to just the
-- codename when the map has no worldspawn title.
function director.mapLabel(name: string, rawTitle: string?): string
	local title = TITLE_OVERRIDES[name] or rawTitle
	if title and title ~= "" then
		return `{title} ({name})`
	end
	return name
end

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
-- callvote (mid-round player votes)
--
-- The vote ENGINE is generic — a proposal is any (key, value) pair the
-- apply layer understands (rules, maps, toggles). What players may
-- actually propose is the VOTABLE spec below: a view layer over the
-- full parameter set. Game-defining rules (deathmatch/teamplay/coop/
-- skill) are deliberately absent — those stay host-only.

export type Proposal = { key: string, kind: string, value: any, desc: string }

director.VOTABLE = {
	map = { kind = "map" },
	fraglimit = { kind = "rule", min = 5, max = 200 },
	timelimit = { kind = "rule", min = 5, max = 120 },
	samelevel = { kind = "rule", min = 0, max = 1 },
	roblox_avatars = { kind = "toggle" },
} :: { [string]: { kind: string, min: number?, max: number? } }

-- validate a raw (key, value) against the view layer; map proposals are
-- limited to the rotation list (hosts can still force any map)
function director.validateProposal(maplist: { string }, key: any, value: any): (Proposal?, string?)
	if typeof(key) ~= "string" then
		return nil, "bad proposal"
	end
	local spec = director.VOTABLE[key]
	if not spec then
		return nil, `{key} is not votable`
	end
	if spec.kind == "map" then
		local name = if typeof(value) == "string" then value:match("^[%w_%-]+$") else nil
		if not name then
			return nil, "bad map name"
		end
		if not table.find(maplist, name) then
			return nil, `{name} is not in the rotation`
		end
		return { key = key, kind = "map", value = name, desc = `map {name}` }
	elseif spec.kind == "rule" then
		local v = tonumber(value)
		if not v then
			return nil, "bad value"
		end
		v = math.floor(v)
		if v < (spec.min or 0) or v > (spec.max or math.huge) then
			return nil, `{key} must be {spec.min}..{spec.max}`
		end
		return { key = key, kind = "rule", value = v, desc = `{key} {v}` }
	elseif spec.kind == "toggle" then
		if typeof(value) ~= "boolean" then
			return nil, "bad value"
		end
		return { key = key, kind = "toggle", value = value, desc = `{key} {if value then "on" else "off"}` }
	end
	return nil, "bad proposal"
end

-- early resolution against everyone present: pass only once yes alone
-- is a strict majority; fail once no has made that impossible
function director.cvDecided(yes: number, no: number, present: number): string?
	if yes * 2 > present then
		return "pass"
	end
	if no * 2 >= present then
		return "fail"
	end
	return nil
end

-- expiry resolution: majority of the votes actually cast decides —
-- ties and zero participation fail
function director.cvExpired(yes: number, no: number): boolean
	return yes > no
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
	-- human-readable level name for a rotation map (worldspawn "message",
	-- read from the BSP by the boot); nil when unknown or unavailable, so
	-- clients fall back to the raw file name
	getMapTitle: ((name: string) -> string?)?,
	-- host admin tools (Host_Status_f/Host_Ping_f/Host_Kick_f per engine):
	-- returns a report string for "status"/"ping"; performs "kick <name>"
	adminCommand: ((cmd: string, arg: string) -> string?)?,
	-- one console line to every client (vote announcements ride the
	-- engine's own notify surface, not new UI)
	broadcastPrint: ((text: string) -> ())?,
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
-- callvote pacing (product tuning, not Quake constants)
local CV_PLAYER_COOLDOWN = 60 -- seconds between proposals per player
local CV_GLOBAL_COOLDOWN = 15 -- seconds after any vote before the next
local CV_MAP_SPACING = 45 -- min seconds after a changelevel before a map vote
-- (rapid changelevels exhaust the EditableMesh budget; see backlog)

function director.attach(a: Adapter)
	local Players = game:GetService("Players")

	local remote = Instance.new("RemoteEvent")
	remote.Name = "Director"
	remote.Parent = a.net

	local voteOpen = false
	local voteMaps: { string } = {}
	local voteDeadline = 0
	local votes: { [Player]: number } = {}
	local wasIntermission = false

	-- callvote state: at most one active proposal
	type ActiveCv = { prop: Proposal, byName: string, deadline: number, votes: { [Player]: boolean } }
	local cv: ActiveCv? = nil
	local cvLastProposal: { [Player]: number } = {}
	local cvLastEnd = -math.huge
	local lastMapChange = -math.huge

	local function announce(text: string)
		if a.broadcastPrint then
			a.broadcastPrint(text)
		end
		print("[director] " .. text)
	end

	local function maplist(): { string }
		return director.parseMaplist(a.assets:GetAttribute("maplist"))
	end

	-- level-name cache: BSP reads are cheap but not free, so remember each
	-- map's worldspawn "message" the first time we need it (keyed by file
	-- name; a name absent from the map means "looked up, has no title")
	local titleCache: { [string]: string } = {}
	local titleTried: { [string]: boolean } = {}
	local function mapTitles(list: { string }): { [string]: string }
		local out: { [string]: string } = {}
		local get = a.getMapTitle
		for _, name in list do
			if get and not titleTried[name] then
				titleTried[name] = true
				local t = get(name)
				if t and t ~= "" then
					titleCache[name] = t
				end
			end
			-- always emit a label so the codename shows even for maps with
			-- no BSP title; override table sanitizes unsuitable names
			out[name] = director.mapLabel(name, titleCache[name])
		end
		return out
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
			maptitles = mapTitles(maplist()),
			avatars = a.assets:GetAttribute("roblox_avatars") ~= false,
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
		table.clear(votes)
		voteMaps = {}
	end

	local function currentWinner(): string?
		local list = maplist()
		local fallback = director.rotationNext(list, a.getCurrentMap())
		return director.winner(voteMaps, director.tally(votes, #voteMaps), fallback)
	end

	------------------------------------------------------------------
	-- callvote lifecycle

	local function cvCounts(c: ActiveCv): (number, number)
		local yes, no = 0, 0
		for _, v in c.votes do
			if v then
				yes += 1
			else
				no += 1
			end
		end
		return yes, no
	end

	local function cvBroadcastCounts(c: ActiveCv)
		local yes, no = cvCounts(c)
		remote:FireAllClients({ t = "cvCounts", yes = yes, no = no })
	end

	local function applyProposal(prop: Proposal)
		if prop.kind == "map" then
			closeVote() -- an intermission vote cannot coexist anyway
			lastMapChange = os.clock()
			a.forceChangelevel(prop.value)
		elseif prop.kind == "rule" then
			a.setRule(prop.key, prop.value)
			a.assets:SetAttribute(prop.key, prop.value) -- survives restarts
			broadcastState()
		elseif prop.kind == "toggle" then
			a.assets:SetAttribute(prop.key, prop.value)
			broadcastState()
		end
	end

	local function resolveCv(passed: boolean, why: string?)
		local c = cv
		if not c then
			return
		end
		cv = nil
		cvLastEnd = os.clock()
		local yes, no = cvCounts(c)
		announce(if passed
			then `vote passed ({yes}-{no}): {c.prop.desc}`
			else `vote failed ({yes}-{no}): {c.prop.desc}{if why then " - " .. why else ""}`)
		remote:FireAllClients({ t = "cvEnd", passed = passed, desc = c.prop.desc })
		if passed then
			applyProposal(c.prop)
		end
	end

	-- early pass/fail once the present players make the outcome certain
	local function cvCheck()
		local c = cv
		if not c then
			return
		end
		local yes, no = cvCounts(c)
		local decided = director.cvDecided(yes, no, #Players:GetPlayers())
		if decided then
			resolveCv(decided == "pass")
		end
	end

	-- deny reasons for a callvote request; nil = allowed
	local function cvDenyReason(player: Player): string?
		if cv then
			return "a vote is already in progress"
		end
		if voteOpen then
			return "the next-map vote is open"
		end
		local now = os.clock()
		if now - cvLastEnd < CV_GLOBAL_COOLDOWN then
			return "too soon after the last vote"
		end
		if now - (cvLastProposal[player] or -math.huge) < CV_PLAYER_COOLDOWN then
			return "you called a vote recently"
		end
		return nil
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
			local c = cv
			if c then
				remote:FireClient(player, {
					t = "cvBegin",
					desc = c.prop.desc,
					by = c.byName,
					secondsLeft = math.max(0, c.deadline - os.clock()),
				})
				cvBroadcastCounts(c)
			end
		elseif msg.t == "vote" then
			local i = tonumber(msg.i)
			print(`[director] vote msg from {player.Name}: i={tostring(i)} open={tostring(voteOpen)} nmaps={#voteMaps}`)
			if voteOpen and i and i >= 1 and i <= #voteMaps then
				votes[player] = i
				broadcastCounts()
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
		elseif msg.t == "callvote" then
			local deny = cvDenyReason(player)
			local prop: Proposal?, err: string?
			if not deny then
				prop, err = director.validateProposal(maplist(), msg.key, msg.value)
				deny = err
				if prop and prop.kind == "map" and os.clock() - lastMapChange < CV_MAP_SPACING then
					deny = "the map just changed"
					prop = nil
				end
			end
			if deny or not prop then
				remote:FireClient(player, { t = "cvDeny", reason = deny or "bad proposal" })
				return
			end
			cvLastProposal[player] = os.clock()
			local vt = tonumber(a.assets:GetAttribute("votetime")) or DEFAULT_VOTETIME
			cv = { prop = prop, byName = player.Name, deadline = os.clock() + vt, votes = { [player] = true } }
			announce(`{player.Name} called a vote: {prop.desc}`)
			remote:FireAllClients({ t = "cvBegin", desc = prop.desc, by = player.Name, secondsLeft = vt })
			cvBroadcastCounts(cv :: ActiveCv)
			cvCheck() -- a lone player's vote passes immediately
		elseif msg.t == "castvote" then
			local c = cv
			if c and typeof(msg.v) == "boolean" then
				c.votes[player] = msg.v
				cvBroadcastCounts(c)
				cvCheck()
			end
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
		cvLastProposal[player] = nil
		local c = cv
		if c and c.votes[player] ~= nil then
			c.votes[player] = nil
			cvBroadcastCounts(c)
		end
		if c then
			cvCheck() -- fewer present players may decide the outcome
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
		-- callvote expiry: majority of the votes cast decides
		local c = cv
		if c and os.clock() > c.deadline then
			local yes, no = cvCounts(c)
			resolveCv(director.cvExpired(yes, no), "time expired")
		end

		local inter = a.getIntermission()
		if inter and not wasIntermission then
			-- the round ending supersedes any mid-round vote
			if cv then
				resolveCv(false, "round ended")
			end
			local list = maplist()
			if #list > 0 then
				voteMaps = director.candidates(list, a.getCurrentMap(), 3)
				if #voteMaps > 0 then
					table.clear(votes)
					voteOpen = true
					local vt = tonumber(a.assets:GetAttribute("votetime")) or DEFAULT_VOTETIME
					voteDeadline = os.clock() + vt
					print(`[director] vote open: {table.concat(voteMaps, ",")} for {vt}s`)
					remote:FireAllClients({ t = "voteBegin", maps = voteMaps, secondsLeft = vt })
					broadcastCounts()
				end
			end
		end
		wasIntermission = inter
		if voteOpen and os.clock() > voteDeadline then
			local counts = director.tally(votes, #voteMaps)
			local w = currentWinner()
			print(`[director] vote expired: {table.concat(voteMaps, ",")} counts={table.concat(counts, ",")} -> {w or "?"}`)
			closeVote()
			if w then
				a.forceChangelevel(w)
			end
		end
	end

	-- the single engine seam: the boot passes every QC changelevel target
	-- through here and loads what comes back
	function api.resolveChangelevel(qcTarget: string): string
		lastMapChange = os.clock() -- callvote map-spacing guard
		if cv then
			resolveCv(false, "map changed")
		end
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
