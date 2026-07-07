--!strict
-- Stats store (PRODUCT layer, NOT engine): persistence + leaderboards
-- for the stats pipeline. statscore.luau is the pure math; stats.luau
-- (the capture adapter) drives sessions from engine state and calls
-- flush points here.
--
-- Persistence model: sessions accumulate DELTAS (pure counters), and a
-- flush merges them into the player's profile with UpdateAsync — an
-- add-only merge, so concurrent servers never need session locks and a
-- retried write after an error cannot double-count more than the one
-- contested delta. Leaderboards are OrderedDataStores named per
-- (stat, scope, period); day/week stores freeze naturally when their
-- period passes because the period key is part of the store name.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local statscore = require(script.Parent.statscore)

local statstore = {}

local PROFILE_STORE = "rq-stats-1"
local PROFILE_VERSION = 1
local FLUSH_INTERVAL = 120 -- seconds between autosaves per player
local BOARD_STATS = { "kills" } -- ranking metric(s) written per scope/period
local BOARD_PAGE = 50 -- rows returned to clients
local BOARD_CACHE_SECS = 45 -- server-side cache of fetched pages
local FETCH_COOLDOWN = 2 -- per-player rate limit on the RemoteFunction

export type Options = {
	modekey: string,
	net: Instance, -- Leaderboards RemoteFunction parents here
}

function statstore.new(opts: Options)
	local st = {}
	st.modekey = opts.modekey
	st.disabled = false -- flips on when DataStores are unreachable (Studio)

	-- disable permanently only for the "no API access" class of error
	-- (unpublished place / Studio access off); transient throttles and
	-- outages keep deltas pending and retry on the next flush
	local function noteWriteError(err: any)
		local s = tostring(err):lower()
		if s:find("access") or s:find("publish") then
			if not st.disabled then
				st.disabled = true
				warn(`[stats] DataStores unavailable — stats run in-memory only ({err})`)
			end
		else
			warn(`[stats] profile write failed (will retry): {err}`)
		end
	end

	local profiles: DataStore? = nil
	if RunService:IsRunning() then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(PROFILE_STORE)
		end)
		if ok then
			profiles = store
		else
			noteWriteError(store)
		end
	end

	-- per-player live state
	type Entry = {
		session: statscore.Session,
		pending: statscore.Counters?, -- deltas taken but not yet written
		lastFlush: number,
		lastBoardValue: { [string]: number }, -- boardName -> last written
		leaderstats: Folder?,
	}
	local entries: { [Player]: Entry } = {}
	local nameCache: { [number]: string } = {}

	-- friends-scope caches (used by the friends board below and seeded
	-- by flush; declared here so flush can reference them — Luau locals
	-- referenced before their declaration silently resolve as globals)
	local FRIENDS_CACHE_SECS = 300
	local FRIEND_PROFILE_CACHE_SECS = 90
	local FRIEND_PROFILE_MISS_SECS = 600 -- friends who never played
	local MAX_FRIEND_READS = 100
	local friendsCache: { [number]: { at: number, ids: { number } } } = {}
	local friendProfileCache: { [number]: { at: number, profile: statscore.Counters? } } = {}

	local function boardStore(name: string): OrderedDataStore?
		if st.disabled then
			return nil
		end
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(name)
		end)
		return if ok then store else nil
	end

	--------------------------------------------------------------------
	-- sessions

	function st.session(player: Player): statscore.Session
		local e = entries[player]
		if not e then
			e = {
				session = statscore.newSession(),
				pending = nil,
				lastFlush = os.clock() + math.random() * FLUSH_INTERVAL, -- stagger
				lastBoardValue = {},
				leaderstats = nil,
			}
			entries[player] = e
			nameCache[player.UserId] = player.Name
			-- native playerlist integration
			local ls = Instance.new("Folder")
			ls.Name = "leaderstats"
			local frags = Instance.new("IntValue")
			frags.Name = "Frags"
			frags.Parent = ls
			local deaths = Instance.new("IntValue")
			deaths.Name = "Deaths"
			deaths.Parent = ls
			ls.Parent = player
			e.leaderstats = ls
		end
		return e.session
	end

	-- live playerlist values (session-scope, mirrors the Quake scoreboard)
	function st.setLeaderstats(player: Player, frags: number, deaths: number)
		local e = entries[player]
		local ls = e and e.leaderstats
		if ls then
			local f = ls:FindFirstChild("Frags") :: IntValue?
			local d = ls:FindFirstChild("Deaths") :: IntValue?
			if f then
				f.Value = frags
			end
			if d then
				d.Value = deaths
			end
		end
	end

	--------------------------------------------------------------------
	-- persistence

	local function writeProfile(userId: number, name: string, delta: statscore.Counters): statscore.Counters?
		if not profiles or st.disabled then
			return nil
		end
		local now = os.time()
		local ok, merged = pcall(function()
			local result: statscore.Counters?
			profiles:UpdateAsync("u" .. userId, function(old: any)
				local p: statscore.Counters = if type(old) == "table" then old else { v = PROFILE_VERSION, firstSeen = now }
				p.name = name
				p.lastSeen = now
				statscore.touchActivity(p, now) -- daysActive / day-streak
				statscore.mergeIntoProfile(p, delta, now, st.modekey)
				statscore.pruneProfile(p, now)
				result = p
				return p
			end)
			return result
		end)
		if not ok then
			noteWriteError(merged)
			return nil
		end
		return merged
	end

	local function writeBoards(e: Entry, userId: number, profile: statscore.Counters)
		local buckets = profile.buckets
		if type(buckets) ~= "table" then
			return
		end
		local now = os.time()
		for _, target in statscore.boardTargets(now, st.modekey) do
			local bucket = buckets[statscore.bucketKey(target.period, target.scope)]
			if type(bucket) ~= "table" then
				continue
			end
			for _, stat in BOARD_STATS do
				local value = math.floor(tonumber(bucket[stat]) or 0)
				if value <= 0 then
					continue
				end
				local name = statscore.boardName(stat, target.scope, target.period)
				if e.lastBoardValue[name] == value then
					continue
				end
				local store = boardStore(name)
				if store then
					local ok, err = pcall(function()
						store:SetAsync(tostring(userId), value)
					end)
					if ok then
						e.lastBoardValue[name] = value
					else
						warn(`[stats] board write failed ({name}): {err}`)
					end
				end
			end
		end
	end

	-- take the session's accumulated delta and persist it (plus anything
	-- a previously failed write left pending)
	function st.flush(player: Player)
		local e = entries[player]
		if not e then
			return
		end
		e.lastFlush = os.clock()
		local d = statscore.takeDelta(e.session)
		if d then
			if e.pending then
				statscore.mergeCounters(e.pending, d)
			else
				e.pending = d
			end
		end
		if not e.pending then
			return
		end
		local profile = writeProfile(player.UserId, player.Name, e.pending)
		if profile then
			e.pending = nil
			writeBoards(e, player.UserId, profile)
			-- keep the friends-scope view of ourselves current
			friendProfileCache[player.UserId] = { at = os.clock(), profile = profile }
		end
	end

	function st.remove(player: Player)
		st.flush(player)
		entries[player] = nil
	end

	-- autosave sweep; call from the boot heartbeat (cheap: one clock
	-- compare per player per tick, flushes are staggered)
	function st.step()
		local now = os.clock()
		for player, e in entries do
			if now - e.lastFlush >= FLUSH_INTERVAL then
				task.spawn(st.flush, player)
			end
		end
	end

	game:BindToClose(function()
		for player in entries do
			st.flush(player)
		end
	end)

	--------------------------------------------------------------------
	-- leaderboard reads

	local function displayName(userId: number): string
		local cached = nameCache[userId]
		if cached then
			return cached
		end
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		nameCache[userId] = if ok then name else tostring(userId)
		return nameCache[userId]
	end

	type BoardPage = { at: number, entries: { { userId: number, name: string, value: number } } }
	local pageCache: { [string]: BoardPage } = {}

	local function fetchBoard(name: string): BoardPage?
		local cached = pageCache[name]
		if cached and os.clock() - cached.at < BOARD_CACHE_SECS then
			return cached
		end
		local store = boardStore(name)
		if not store then
			return nil
		end
		local ok, page = pcall(function()
			return store:GetSortedAsync(false, BOARD_PAGE):GetCurrentPage()
		end)
		if not ok then
			warn(`[stats] board read failed ({name}): {page}`)
			return cached
		end
		local out: BoardPage = { at = os.clock(), entries = {} }
		for _, row in page :: { { key: string, value: number } } do
			local userId = tonumber(row.key)
			if userId then
				table.insert(out.entries, { userId = userId, name = displayName(userId), value = row.value })
			end
		end
		pageCache[name] = out
		return out
	end

	--------------------------------------------------------------------
	-- friends boards
	--
	-- OrderedDataStores cannot be filtered by user, so the friends scope
	-- reads each friend's PROFILE directly and ranks the requested
	-- period's global bucket. Only friends who have ever played (i.e.
	-- have a profile) appear. Reads are capped and cached: friend lists
	-- change rarely, and a friend with no profile stays absent for a
	-- while rather than costing a fresh read per fetch.

	local function friendIds(player: Player): { number }
		local cached = friendsCache[player.UserId]
		if cached and os.clock() - cached.at < FRIENDS_CACHE_SECS then
			return cached.ids
		end
		local ids: { number } = {}
		local ok = pcall(function()
			local pages = Players:GetFriendsAsync(player.UserId)
			while true do
				for _, item in pages:GetCurrentPage() :: { any } do
					table.insert(ids, item.Id)
					if item.Username and item.Id then
						nameCache[item.Id] = item.Username
					end
				end
				if pages.IsFinished or #ids >= MAX_FRIEND_READS then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
		end)
		if not ok and cached then
			return cached.ids -- stale beats empty on a transient failure
		end
		friendsCache[player.UserId] = { at = os.clock(), ids = ids }
		return ids
	end

	local function readFriendProfile(userId: number): statscore.Counters?
		local cached = friendProfileCache[userId]
		if cached then
			local ttl = if cached.profile then FRIEND_PROFILE_CACHE_SECS else FRIEND_PROFILE_MISS_SECS
			if os.clock() - cached.at < ttl then
				return cached.profile
			end
		end
		if not profiles or st.disabled then
			return nil
		end
		local ok, profile = pcall(function()
			return profiles:GetAsync("u" .. userId)
		end)
		if not ok then
			return if cached then cached.profile else nil
		end
		local p = if type(profile) == "table" then profile :: statscore.Counters else nil
		friendProfileCache[userId] = { at = os.clock(), profile = p }
		return p
	end

	-- ranked friends (self included) by the period's GLOBAL bucket
	local function fetchFriendsBoard(player: Player, period: string, stat: string)
		local ids = friendIds(player)
		local out: { { userId: number, name: string, value: number } } = {}
		local bucketKey = statscore.bucketKey(period, "global")
		local function addUser(userId: number)
			local profile = readFriendProfile(userId)
			local buckets = profile and profile.buckets
			local bucket = if type(buckets) == "table" then buckets[bucketKey] else nil
			local value = if type(bucket) == "table" then math.floor(tonumber(bucket[stat]) or 0) else nil
			if value and value > 0 then
				local name = (profile and profile.name) or nameCache[userId] or tostring(userId)
				nameCache[userId] = name
				table.insert(out, { userId = userId, name = name, value = value })
			end
		end
		addUser(player.UserId)
		for i, id in ids do
			if i > MAX_FRIEND_READS then
				break
			end
			addUser(id)
		end
		table.sort(out, function(x, y)
			return x.value > y.value
		end)
		return out
	end

	Players.PlayerRemoving:Connect(function(p)
		friendsCache[p.UserId] = nil
	end)

	local remote = Instance.new("RemoteFunction")
	remote.Name = "Leaderboards"
	remote.Parent = opts.net
	local lastFetch: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(p)
		lastFetch[p] = nil
	end)

	-- request: { scope: "global"|"mode", period: "all"|"day"|"week", stat: string? }
	remote.OnServerInvoke = function(player: Player, req: any)
		local now = os.clock()
		if now - (lastFetch[player] or -math.huge) < FETCH_COOLDOWN then
			return nil
		end
		lastFetch[player] = now
		if typeof(req) ~= "table" then
			return nil
		end
		local stat = if table.find(BOARD_STATS, req.stat) then req.stat :: string else BOARD_STATS[1]
		local unix = os.time()
		local period = if req.period == "day"
			then statscore.dayKey(unix)
			elseif req.period == "week" then statscore.weekKey(unix)
			else "all"
		local entries2: { { userId: number, name: string, value: number } }
		if req.scope == "friends" then
			entries2 = fetchFriendsBoard(player, period, stat)
		else
			local scope = if req.scope == "mode" then "m:" .. st.modekey else "global"
			local page = fetchBoard(statscore.boardName(stat, scope, period))
			entries2 = if page then page.entries else {}
		end
		-- caller's own row (rank within the fetched page, if present)
		local you: { rank: number, value: number }? = nil
		for i, row in entries2 do
			if row.userId == player.UserId then
				you = { rank = i, value = row.value }
				break
			end
		end
		return {
			modekey = st.modekey,
			stat = stat,
			scope = req.scope,
			period = req.period,
			entries = entries2,
			you = you,
			disabled = st.disabled,
		}
	end

	return st
end

return statstore
