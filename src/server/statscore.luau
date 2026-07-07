--!strict
-- Stats core (PRODUCT layer, NOT engine): pure bookkeeping for the
-- persistent player-stats pipeline. Everything here is plain data +
-- math so it runs (and is tested) under lune; Roblox services live in
-- statstore.luau, capture wiring in stats.luau.
--
-- Model: play produces per-player DELTA tables; deltas merge into
-- period BUCKETS ("all"/current day/current week, each split
-- global/per-mode) inside the DataStore profile; OrderedDataStore
-- leaderboards are re-written from the merged bucket totals.

local statscore = {}

--------------------------------------------------------------------------
-- counters

-- additive counters carried by every bucket and every delta
statscore.ADD_KEYS = {
	"kills", -- frag increases (enemy kills)
	"deaths", -- own deadflag edges
	"suicides", -- frag decreases (world/self/teamkill penalties)
	"frags", -- net QC frags (kills - suicides), the classic score
	"wins", -- top of the scoreboard at intermission
	"matches", -- present at an intermission
	"rounds", -- maps played (any map end, incl. admin force-changes)
	"playtime", -- whole seconds connected while the server is active
	"joins", -- connects
}

-- high-water counters: merge takes max(), not sum
statscore.MAX_KEYS = {
	"bestRoundFrags", -- most net frags in one map
	"bestStreak", -- longest kill streak without dying
}

-- weapon attribution: QC .weapon IT_ bit of the killer at frag time
local WEAPON_NAMES: { [number]: string } = {
	[4096] = "axe",
	[1] = "shotgun",
	[2] = "supershotgun",
	[4] = "nailgun",
	[8] = "supernailgun",
	[16] = "grenade",
	[32] = "rocket",
	[64] = "lightning",
}

function statscore.weaponName(itBit: number): string
	return WEAPON_NAMES[itBit] or "other"
end

--------------------------------------------------------------------------
-- period keys
--
-- Day and week indexes are pure integer math on unix time (UTC) so the
-- same instant maps to the same board name on every server. Weeks start
-- Monday: 1970-01-01 was a Thursday, so day 0 belongs to the week that
-- started 3 days earlier.

function statscore.dayIndex(unix: number): number
	return math.floor(unix / 86400)
end

function statscore.dayKey(unix: number): string
	return "d" .. statscore.dayIndex(unix)
end

function statscore.weekKey(unix: number): string
	return "w" .. math.floor((statscore.dayIndex(unix) + 3) / 7)
end

-- the three period keys a moment lives in
function statscore.periodKeys(unix: number): { string }
	return { "all", statscore.dayKey(unix), statscore.weekKey(unix) }
end

--------------------------------------------------------------------------
-- buckets
--
-- A profile stores counters under bucket keys "<period>|<scope>" where
-- scope is "global" or "m:<modekey>". 3 periods x 2 scopes = 6 buckets
-- touched per merge.

function statscore.bucketKey(period: string, scope: string): string
	return period .. "|" .. scope
end

function statscore.bucketKeys(unix: number, modekey: string): { string }
	local out = {}
	for _, period in statscore.periodKeys(unix) do
		table.insert(out, statscore.bucketKey(period, "global"))
		table.insert(out, statscore.bucketKey(period, "m:" .. modekey))
	end
	return out
end

export type Counters = { [string]: any } -- numbers + weaponKills subtable

-- merge one delta into one counters table (in place)
function statscore.mergeCounters(into: Counters, delta: Counters)
	for _, k in statscore.ADD_KEYS do
		local d = delta[k]
		if type(d) == "number" and d ~= 0 then
			into[k] = (tonumber(into[k]) or 0) + d
		end
	end
	for _, k in statscore.MAX_KEYS do
		local d = delta[k]
		if type(d) == "number" then
			into[k] = math.max(tonumber(into[k]) or 0, d)
		end
	end
	local wk = delta.weaponKills
	if type(wk) == "table" then
		local t = into.weaponKills
		if type(t) ~= "table" then
			t = {}
			into.weaponKills = t
		end
		for name, n in wk :: { [string]: number } do
			if type(n) == "number" and n > 0 then
				t[name] = (tonumber(t[name]) or 0) + n
			end
		end
	end
end

-- merge a delta into a profile's buckets for every (period, scope) the
-- moment `unix` belongs to; creates buckets as needed
function statscore.mergeIntoProfile(profile: Counters, delta: Counters, unix: number, modekey: string)
	local buckets = profile.buckets
	if type(buckets) ~= "table" then
		buckets = {}
		profile.buckets = buckets
	end
	for _, bk in statscore.bucketKeys(unix, modekey) do
		local b = buckets[bk]
		if type(b) ~= "table" then
			b = {}
			buckets[bk] = b
		end
		statscore.mergeCounters(b, delta)
	end
end

-- drop day/week buckets that are no longer current ("all" is permanent).
-- Stale-period leaderboard stores freeze on their own (their name embeds
-- the period key); pruning just keeps profiles small.
function statscore.pruneProfile(profile: Counters, unix: number)
	local buckets = profile.buckets
	if type(buckets) ~= "table" then
		return
	end
	local keep: { [string]: boolean } = {}
	for _, period in statscore.periodKeys(unix) do
		keep[period] = true
	end
	for bk in buckets :: { [string]: any } do
		local period = bk:match("^([^|]+)|")
		if period and not keep[period] then
			buckets[bk] = nil
		end
	end
end

--------------------------------------------------------------------------
-- activity (profile-level, not bucketed)
--
-- Distinct days played + consecutive-day streak, updated on every
-- profile write. Stored eagerly because a consecutive streak cannot be
-- reconstructed later from counts alone. Days are UTC (dayIndex).

function statscore.touchActivity(profile: Counters, unix: number)
	local today = statscore.dayIndex(unix)
	local last = tonumber(profile.lastActiveDay)
	if last == today then
		return -- same day: idempotent
	end
	profile.daysActive = (tonumber(profile.daysActive) or 0) + 1
	if last == today - 1 then
		profile.streakDays = (tonumber(profile.streakDays) or 0) + 1
	else
		profile.streakDays = 1
	end
	profile.bestStreakDays = math.max(tonumber(profile.bestStreakDays) or 0, profile.streakDays :: number)
	profile.lastActiveDay = today
end

-- the streak as it should DISPLAY right now: the stored value goes
-- stale between sessions (a Monday streak still reads 5 on Thursday
-- until the next write), so readers check the gap. Yesterday still
-- shows the streak — it isn't broken until a full day is missed.
function statscore.effectiveStreak(profile: Counters, unix: number): number
	local last = tonumber(profile.lastActiveDay)
	if last == nil or statscore.dayIndex(unix) - last > 1 then
		return 0
	end
	return tonumber(profile.streakDays) or 0
end

--------------------------------------------------------------------------
-- leaderboard store names
--
-- One OrderedDataStore per (stat, scope, period). Period-keyed stores
-- naturally freeze when their day/week passes.

function statscore.boardName(stat: string, scope: string, period: string): string
	return `lb1:{stat}:{scope}:{period}`
end

-- every (scope, period) pair current at `unix` for this mode
function statscore.boardTargets(unix: number, modekey: string): { { scope: string, period: string } }
	local out = {}
	for _, period in statscore.periodKeys(unix) do
		table.insert(out, { scope = "global", period = period })
		table.insert(out, { scope = "m:" .. modekey, period = period })
	end
	return out
end

--------------------------------------------------------------------------
-- live session tracking

export type Session = {
	delta: Counters, -- accumulates until statstore takes it
	streak: number, -- current kill streak (survives flushes, not death)
	roundFrags: number, -- net frags this map
}

function statscore.newSession(): Session
	return { delta = { joins = 1 }, streak = 0, roundFrags = 0 }
end

local function bump(c: Counters, k: string, n: number)
	c[k] = (tonumber(c[k]) or 0) + n
end

-- QC frags moved by `d` (can be +/- several in one tick); weaponBit =
-- the killer's .weapon at observation time (attribution approximation)
function statscore.applyFragDelta(s: Session, d: number, weaponBit: number)
	if d == 0 then
		return
	end
	bump(s.delta, "frags", d)
	s.roundFrags += d
	if d > 0 then
		bump(s.delta, "kills", d)
		local wk = s.delta.weaponKills
		if type(wk) ~= "table" then
			wk = {}
			s.delta.weaponKills = wk
		end
		local name = statscore.weaponName(weaponBit)
		wk[name] = (tonumber(wk[name]) or 0) + d
		s.streak += d
		local best = tonumber(s.delta.bestStreak) or 0
		if s.streak > best then
			s.delta.bestStreak = s.streak
		end
	else
		bump(s.delta, "suicides", -d)
	end
end

function statscore.applyDeath(s: Session)
	bump(s.delta, "deaths", 1)
	s.streak = 0
end

function statscore.applyPlaytime(s: Session, seconds: number)
	if seconds > 0 then
		bump(s.delta, "playtime", seconds)
	end
end

-- a map ended for this player. `won` only when it ended in a real
-- intermission (admin force-changes count the round, not a match)
function statscore.applyRoundEnd(s: Session, intermission: boolean, won: boolean)
	bump(s.delta, "rounds", 1)
	if intermission then
		bump(s.delta, "matches", 1)
		if won then
			bump(s.delta, "wins", 1)
		end
	end
	local best = tonumber(s.delta.bestRoundFrags) or 0
	if s.roundFrags > best then
		s.delta.bestRoundFrags = s.roundFrags
	end
	s.roundFrags = 0
	s.streak = 0
end

-- take the accumulated delta for flushing; the session keeps running
function statscore.takeDelta(s: Session): Counters?
	local d = s.delta
	if next(d) == nil then
		return nil
	end
	-- s.streak survives the flush, so a still-running streak re-enters
	-- the fresh delta's bestStreak on its next kill (max-merge dedupes)
	s.delta = {}
	return d
end

-- scoreboard winners: indexes of the top net-frag entries (ties share)
function statscore.winners(frags: { [number]: number }): { [number]: boolean }
	local best: number? = nil
	for _, f in frags do
		if best == nil or f > best then
			best = f
		end
	end
	local out: { [number]: boolean } = {}
	if best ~= nil then
		for slot, f in frags do
			if f == best then
				out[slot] = true
			end
		end
	end
	return out
end

--------------------------------------------------------------------------
-- mode key

-- shipped places set an explicit `modekey` attribute; this derives a
-- sensible one from the boot attributes when it is absent
function statscore.deriveModeKey(attrs: {
	modekey: string?,
	engine: string?,
	gamedir: string?,
	deathmatch: number?,
	coop: number?,
	teamplay: number?,
}): string
	if type(attrs.modekey) == "string" and attrs.modekey ~= "" then
		return attrs.modekey
	end
	local gamedir = attrs.gamedir
	if gamedir == "threewave" then
		return "ctf"
	elseif type(gamedir) == "string" and gamedir ~= "" then
		return gamedir -- arena, instagib, future mods
	end
	if (attrs.deathmatch or 0) ~= 0 then
		return if (attrs.teamplay or 0) ~= 0 then "tdm" else "dm"
	end
	if (attrs.coop or 0) ~= 0 then
		return "coop"
	end
	return "campaign"
end

return statscore
