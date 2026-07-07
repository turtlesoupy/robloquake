--!strict
-- Stats core pure logic: period keys, bucket merge, sessions, winners.

local t = require("./testutil")
local statscore = require("../src/server/statscore")

-- period keys. 2026-07-07 00:00 UTC = 1783382400 (a Tuesday).
local TUE = 1783382400
t.eq(statscore.dayKey(TUE), "d20641", "day index from unix")
t.eq(statscore.dayKey(TUE + 86399), "d20641", "same day until midnight")
t.eq(statscore.dayKey(TUE + 86400), "d20642", "next day at midnight")
-- Monday 2026-07-06 starts the week; Sunday 2026-07-12 23:59 ends it
local MON = TUE - 86400
t.eq(statscore.weekKey(MON), statscore.weekKey(MON + 7 * 86400 - 1), "monday..sunday share a week")
t.eq(statscore.weekKey(MON - 1) ~= statscore.weekKey(MON), true, "week rolls at monday midnight")
local pk = statscore.periodKeys(TUE)
t.eq(#pk, 3, "three period keys")
t.eq(pk[1], "all", "all-time first")

-- weapon names
t.eq(statscore.weaponName(32), "rocket", "rocket bit")
t.eq(statscore.weaponName(4096), "axe", "axe bit")
t.eq(statscore.weaponName(999), "other", "unknown bit -> other")

-- session: frag deltas, streaks, deaths
local s = statscore.newSession()
t.eq(s.delta.joins, 1, "join counted at session start")
statscore.applyFragDelta(s, 2, 32) -- double rocket frag in one tick
statscore.applyFragDelta(s, 1, 1)
t.eq(s.delta.kills, 3, "kills accumulate")
t.eq(s.delta.frags, 3, "net frags accumulate")
t.eq((s.delta.weaponKills :: any).rocket, 2, "weapon attribution")
t.eq((s.delta.weaponKills :: any).shotgun, 1, "weapon attribution 2")
t.eq(s.delta.bestStreak, 3, "streak high-water")
statscore.applyDeath(s)
t.eq(s.delta.deaths, 1, "death counted")
t.eq(s.streak, 0, "death resets streak")
statscore.applyFragDelta(s, -1, 0) -- lava suicide
t.eq(s.delta.suicides, 1, "suicide counted")
t.eq(s.delta.frags, 2, "suicide lowers net frags")
t.eq(s.delta.kills, 3, "suicide is not a kill")
statscore.applyPlaytime(s, 90)
t.eq(s.delta.playtime, 90, "playtime accumulates")

-- round end: match/win credit only at real intermissions
t.eq(s.roundFrags, 2, "round frags track net")
statscore.applyRoundEnd(s, true, true)
t.eq(s.delta.rounds, 1, "round counted")
t.eq(s.delta.matches, 1, "match counted at intermission")
t.eq(s.delta.wins, 1, "win counted")
t.eq(s.delta.bestRoundFrags, 2, "best round frags recorded")
t.eq(s.roundFrags, 0, "round frags reset")
statscore.applyRoundEnd(s, false, false) -- admin force-change
t.eq(s.delta.rounds, 2, "forced change still counts the round")
t.eq(s.delta.matches, 1, "forced change is not a match")

-- takeDelta drains, session keeps running
local d1 = statscore.takeDelta(s)
t.eq((d1 :: any).kills, 3, "takeDelta hands over counters")
t.eq(statscore.takeDelta(s), nil, "drained session yields nil")
statscore.applyFragDelta(s, 1, 64)
local d2 = statscore.takeDelta(s)
t.eq((d2 :: any).kills, 1, "post-flush kills start fresh")
t.eq((d2 :: any).bestStreak, 1, "streak survives flush boundary")

-- mergeCounters: adds, maxes, weapon tables
local tot = { kills = 10, bestStreak = 5, weaponKills = { rocket = 4 } }
statscore.mergeCounters(tot, { kills = 3, bestStreak = 2, weaponKills = { rocket = 1, axe = 2 } })
t.eq(tot.kills, 13, "additive merge")
t.eq(tot.bestStreak, 5, "max merge keeps high water")
statscore.mergeCounters(tot, { bestStreak = 9 })
t.eq(tot.bestStreak, 9, "max merge takes new high water")
t.eq((tot.weaponKills :: any).rocket, 5, "weapon table merges")
t.eq((tot.weaponKills :: any).axe, 2, "weapon table extends")

-- profile buckets: 6 per merge (3 periods x global+mode)
local profile: statscore.Counters = {}
statscore.mergeIntoProfile(profile, { kills = 2 }, TUE, "dm")
local nb = 0
for _ in profile.buckets :: { [string]: any } do
	nb += 1
end
t.eq(nb, 6, "merge touches 6 buckets")
t.eq((profile.buckets :: any)["all|global"].kills, 2, "all-time global bucket")
t.eq((profile.buckets :: any)["d20641|m:dm"].kills, 2, "daily mode bucket")
statscore.mergeIntoProfile(profile, { kills = 1 }, TUE, "ctf")
t.eq((profile.buckets :: any)["all|global"].kills, 3, "global spans modes")
t.eq((profile.buckets :: any)["all|m:ctf"].kills, 1, "mode buckets stay separate")

-- prune: stale day/week buckets drop, "all" stays
statscore.mergeIntoProfile(profile, { kills = 1 }, TUE + 14 * 86400, "dm")
statscore.pruneProfile(profile, TUE + 14 * 86400)
t.eq((profile.buckets :: any)["d20641|m:dm"], nil, "stale daily bucket pruned")
t.eq((profile.buckets :: any)["all|m:dm"].kills, 3, "all-time bucket survives prune")
t.eq((profile.buckets :: any)[statscore.dayKey(TUE + 14 * 86400) .. "|m:dm"].kills, 1, "current daily kept")

-- activity: distinct days + consecutive-day streak
local act: statscore.Counters = {}
statscore.touchActivity(act, TUE)
t.eq(act.daysActive, 1, "first day counted")
t.eq(act.streakDays, 1, "first day starts streak")
statscore.touchActivity(act, TUE + 3600)
t.eq(act.daysActive, 1, "same day idempotent")
statscore.touchActivity(act, TUE + 86400)
t.eq(act.daysActive, 2, "next day counted")
t.eq(act.streakDays, 2, "consecutive day extends streak")
statscore.touchActivity(act, TUE + 2 * 86400)
t.eq(act.streakDays, 3, "streak keeps extending")
statscore.touchActivity(act, TUE + 10 * 86400)
t.eq(act.daysActive, 4, "gap day still counts as active day")
t.eq(act.streakDays, 1, "gap resets streak")
t.eq(act.bestStreakDays, 3, "best streak is a high-water mark")
t.eq(act.lastActiveDay, statscore.dayIndex(TUE + 10 * 86400), "last active day recorded")
local D10 = TUE + 10 * 86400
t.eq(statscore.effectiveStreak(act, D10), 1, "effective streak: same day shows stored")
t.eq(statscore.effectiveStreak(act, D10 + 86400), 1, "effective streak: yesterday still counts")
t.eq(statscore.effectiveStreak(act, D10 + 2 * 86400), 0, "effective streak: full missed day breaks it")
t.eq(statscore.effectiveStreak({}, D10), 0, "effective streak: no activity -> 0")

-- board naming
t.eq(statscore.boardName("kills", "global", "all"), "lb1:kills:global:all", "board name shape")
local targets = statscore.boardTargets(TUE, "ctf")
t.eq(#targets, 6, "six board targets")
t.eq(targets[2].scope, "m:ctf", "mode scope present")

-- winners: ties share the win
local w = statscore.winners({ [1] = 5, [3] = 7, [4] = 7, [9] = -1 })
t.eq(w[3], true, "top fragger wins")
t.eq(w[4], true, "tie shares the win")
t.eq(w[1], nil, "runner-up does not win")
local none = statscore.winners({})
t.eq(next(none), nil, "no players, no winners")

-- mode key derivation
t.eq(statscore.deriveModeKey({ modekey = "duel" }), "duel", "explicit modekey wins")
t.eq(statscore.deriveModeKey({ gamedir = "threewave", deathmatch = 1, teamplay = 419 }), "ctf", "threewave -> ctf")
t.eq(statscore.deriveModeKey({ gamedir = "arena", deathmatch = 1 }), "arena", "mod gamedir names the mode")
t.eq(statscore.deriveModeKey({ deathmatch = 1 }), "dm", "plain dm")
t.eq(statscore.deriveModeKey({ deathmatch = 1, teamplay = 1 }), "tdm", "teamplay dm -> tdm")
t.eq(statscore.deriveModeKey({ coop = 1 }), "coop", "coop")
t.eq(statscore.deriveModeKey({}), "campaign", "default campaign")

t.finish("stats")
