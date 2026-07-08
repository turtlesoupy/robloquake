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
local HttpService = game:GetService("HttpService")
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

	-- Frag Coins wallet + owned skins (shop economy; prices/rates live in
	-- src/shared/shopcatalog.luau). coins/owned mirror the DataStore profile
	-- (profile-level `coins`/`owned`/`receipts` keys, NOT bucketed); pending
	-- is coins earned since the last flush. Balance shown to the player is
	-- coins + pending.
	type Wallet = {
		coins: number,
		owned: { [string]: boolean },
		pending: number,
		loaded: boolean, -- initial profile read finished (spends wait on it)
	}

	-- per-player live state
	type Entry = {
		session: statscore.Session,
		pending: statscore.Counters?, -- deltas taken but not yet written
		lastFlush: number,
		lastBoardValue: { [string]: number }, -- boardName -> last written
		leaderstats: Folder?,
		wallet: Wallet,
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

	-- wallet boot read; assigned below readFriendProfile (which it needs) and
	-- hoisted here so st.session can reference it (same locals-before-
	-- declaration hazard as the friends caches above)
	local walletLoad: (Player, Wallet) -> ()

	-- the client shop UI reads the wallet off player attributes: RQCoins (a
	-- number, includes unflushed pending) and RQOwnedSkins (JSON array of
	-- owned skinforge kinds)
	local function publishWallet(player: Player?, w: Wallet)
		if not player or not player.Parent then
			return
		end
		player:SetAttribute("RQCoins", math.max(0, w.coins + w.pending))
		local kinds = {}
		for kind in w.owned do
			table.insert(kinds, kind)
		end
		table.sort(kinds)
		player:SetAttribute("RQOwnedSkins", HttpService:JSONEncode(kinds))
	end

	-- adopt the profile's persisted wallet fields into the live mirror
	local function walletFromProfile(w: Wallet, profile: statscore.Counters)
		w.coins = math.floor(tonumber(profile.coins) or 0)
		table.clear(w.owned)
		if type(profile.owned) == "table" then
			for kind, v in profile.owned :: { [string]: any } do
				if type(kind) == "string" and v == true then
					w.owned[kind] = true
				end
			end
		end
	end

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
			-- concrete-typed local (not the `e` rebind): the old solver drops
			-- ?-refinements, so `e.wallet` below would read off Entry?
			local fresh: Entry = {
				session = statscore.newSession(),
				pending = nil,
				lastFlush = os.clock() + math.random() * FLUSH_INTERVAL, -- stagger
				lastBoardValue = {},
				leaderstats = nil,
				wallet = { coins = 0, owned = {}, pending = 0, loaded = false },
			}
			e = fresh
			entries[player] = fresh
			nameCache[player.UserId] = player.Name
			task.spawn(function()
				walletLoad(player, fresh.wallet)
			end)
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

	local function writeProfile(userId: number, name: string, delta: statscore.Counters, coinsAdd: number?): statscore.Counters?
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
				-- Frag Coins earned since the last flush: additive like the
				-- counter deltas, so a retried write can't double-credit more
				-- than the one contested batch
				if coinsAdd and coinsAdd > 0 then
					p.coins = math.floor((tonumber(p.coins) or 0) + coinsAdd)
				end
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
		-- earned coins ride the same write; only banked once the wallet's
		-- boot read is done, so a slow load can't be overwritten by it
		local coinsTake = if e.wallet.loaded then e.wallet.pending else 0
		if not e.pending and coinsTake <= 0 then
			return
		end
		local profile = writeProfile(player.UserId, player.Name, e.pending or {}, coinsTake)
		if profile then
			e.pending = nil
			e.wallet.pending -= coinsTake
			walletFromProfile(e.wallet, profile)
			publishWallet(player, e.wallet)
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

	--------------------------------------------------------------------
	-- Frag Coins wallet (shop economy; see src/shared/shopcatalog.luau).
	-- Earning is add-only and rides the delta flush; spending and Robux
	-- grants are their own guarded UpdateAsync transforms — a spend checks
	-- the balance and CANCELS the write when short, so concurrent servers
	-- can never double-spend. With DataStores unavailable (Studio) the
	-- wallet runs in-memory so the whole shop flow stays testable.

	walletLoad = function(player: Player, w: Wallet)
		local profile = readFriendProfile(player.UserId)
		if profile then
			walletFromProfile(w, profile)
		end
		w.loaded = true
		publishWallet(player, w)
	end

	-- kill/win earnings from the stats capture adapter (stats.luau)
	function st.awardCoins(player: Player, n: number)
		local e = entries[player]
		if not e or n <= 0 then
			return
		end
		e.wallet.pending += n
		publishWallet(player, e.wallet)
	end

	-- prefstore's equip gate. Grace-allows while the wallet is still
	-- loading: dropping a legit skin beats briefly trusting the client on
	-- a cosmetic.
	function st.isOwned(player: Player, kind: string): boolean
		local e = entries[player]
		if not e or not e.wallet.loaded then
			return true
		end
		return e.wallet.owned[kind] == true
	end

	-- buy `kind` for `price` coins; returns ok plus an error code the shop
	-- UI maps to a message ("LOADING" | "POOR" | "ERROR")
	function st.trySpend(player: Player, price: number, kind: string): (boolean, string?)
		local e = entries[player]
		if not e or not e.wallet.loaded then
			return false, "LOADING"
		end
		local w = e.wallet
		if w.owned[kind] then
			return true, nil -- already owned: idempotent success
		end
		if w.coins + w.pending < price then
			return false, "POOR"
		end
		-- in-memory mode: coins may go negative here while pending covers
		-- the rest; the published balance is the sum, which stays right
		local function spendInMemory(): (boolean, string?)
			w.coins -= price
			w.owned[kind] = true
			publishWallet(player, w)
			return true, nil
		end
		if not profiles or st.disabled then
			return spendInMemory()
		end
		st.flush(player) -- bank pending earnings so they count toward the price
		if st.disabled then
			-- that flush just discovered writes are forbidden (fresh Studio
			-- server): fall back in-memory instead of failing the first buy
			return spendInMemory()
		end
		local granted = false
		local ok, merged = pcall(function()
			local result: statscore.Counters?
			profiles:UpdateAsync("u" .. player.UserId, function(old: any)
				local p: statscore.Counters = if type(old) == "table"
					then old
					else { v = PROFILE_VERSION, firstSeen = os.time() }
				local owned = p.owned
				if type(owned) ~= "table" then
					owned = {}
					p.owned = owned
				end
				if owned[kind] == true then
					granted = true
					result = p
					return p
				end
				local coins = math.floor(tonumber(p.coins) or 0)
				if coins < price then
					return nil -- cancel: not enough banked coins
				end
				p.coins = coins - price
				owned[kind] = true
				granted = true
				result = p
				return p
			end)
			return result
		end)
		if not ok then
			noteWriteError(merged)
			return false, "ERROR"
		end
		if not granted then
			return false, "POOR"
		end
		local profile = merged :: statscore.Counters?
		if profile then
			walletFromProfile(w, profile)
			friendProfileCache[player.UserId] = { at = os.clock(), profile = profile }
		end
		publishWallet(player, w)
		return true, nil
	end

	-- Robux receipt fulfilment (shop.luau's ProcessReceipt): grant a skin
	-- kind, or coins on the no-intent fallback. Idempotent — the purchase
	-- id is recorded in the profile, so Roblox redelivering the receipt
	-- after a crash can't double-grant. Returns "granted" | "retry".
	function st.grantProduct(userId: number, grant: { kind: string?, coins: number?, purchaseId: string }): string
		local player = Players:GetPlayerByUserId(userId)
		local e = if player then entries[player] else nil
		if not profiles or st.disabled then
			-- Studio test purchases: in-memory grant, needs the player here
			if not (player and e) then
				return "retry"
			end
			if grant.kind then
				e.wallet.owned[grant.kind] = true
			end
			e.wallet.coins += grant.coins or 0
			publishWallet(player, e.wallet)
			return "granted"
		end
		local ok, merged = pcall(function()
			local result: statscore.Counters?
			profiles:UpdateAsync("u" .. userId, function(old: any)
				local p: statscore.Counters = if type(old) == "table"
					then old
					else { v = PROFILE_VERSION, firstSeen = os.time() }
				local receipts = p.receipts
				if type(receipts) ~= "table" then
					receipts = {}
					p.receipts = receipts
				end
				if receipts[grant.purchaseId] then
					result = p -- redelivery of an already-granted purchase
					return p
				end
				-- receipts only matter within Roblox's redelivery window;
				-- cap the set so profiles don't grow forever
				local n = 0
				for _ in receipts do
					n += 1
				end
				if n >= 128 then
					receipts = {}
					p.receipts = receipts
				end
				receipts[grant.purchaseId] = true
				if grant.kind then
					local owned = p.owned
					if type(owned) ~= "table" then
						owned = {}
						p.owned = owned
					end
					owned[grant.kind] = true
				end
				if grant.coins then
					p.coins = math.floor((tonumber(p.coins) or 0) + grant.coins)
				end
				result = p
				return p
			end)
			return result
		end)
		if not ok then
			noteWriteError(merged)
			return "retry"
		end
		local profile = merged :: statscore.Counters?
		if profile then
			friendProfileCache[userId] = { at = os.clock(), profile = profile }
			if player and e then
				walletFromProfile(e.wallet, profile)
				publishWallet(player, e.wallet)
			end
		end
		return "granted"
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

	--------------------------------------------------------------------
	-- the caller's own card (pause-menu MAIN page): all-time frags/wins
	-- from their persisted profile, plus their rank on the GLOBAL kill
	-- boards for today and all-time. Ranks are present only when the
	-- player sits inside the fetched top page (BOARD_PAGE) — the same
	-- top-N limit as the `you` field below; nil means unranked/too-low.
	local function fetchMyStats(player: Player)
		local userId = player.UserId
		local profile = readFriendProfile(userId)
		local buckets = profile and profile.buckets
		local allBucket = if type(buckets) == "table" then (buckets :: any)[statscore.bucketKey("all", "global")] else nil
		local function num(k: string): number
			return if type(allBucket) == "table" then math.floor(tonumber(allBucket[k]) or 0) else 0
		end
		local stat = BOARD_STATS[1] -- "kills": the ranking metric
		local unix = os.time()
		local function rankOn(period: string): number?
			local page = fetchBoard(statscore.boardName(stat, "global", period))
			if not page then
				return nil
			end
			for i, row in page.entries do
				if row.userId == userId then
					return i
				end
			end
			return nil
		end
		return {
			frags = num("frags"),
			wins = num("wins"),
			rankDay = rankOn(statscore.dayKey(unix)),
			rankAll = rankOn("all"),
			disabled = st.disabled,
		}
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = "Leaderboards"
	remote.Parent = opts.net
	local lastFetch: { [Player]: number } = {}
	local lastMe: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(p)
		lastFetch[p] = nil
		lastMe[p] = nil
	end)

	-- request: { scope: "global"|"mode", period: "all"|"day"|"week", stat: string? }
	--   or { kind = "me" } for the caller's own card (fetchMyStats above)
	remote.OnServerInvoke = function(player: Player, req: any)
		if typeof(req) ~= "table" then
			return nil
		end
		local now = os.clock()
		-- the personal card gets its own cooldown so opening the menu (a "me"
		-- fetch) never eats the RANKINGS page's board-fetch budget
		if req.kind == "me" then
			if now - (lastMe[player] or -math.huge) < FETCH_COOLDOWN then
				return nil
			end
			lastMe[player] = now
			return fetchMyStats(player)
		end
		if now - (lastFetch[player] or -math.huge) < FETCH_COOLDOWN then
			return nil
		end
		lastFetch[player] = now
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
