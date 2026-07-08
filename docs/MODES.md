# Modes, match parameters, and the director

A **mode is a place** in the Roblox universe. Every knob that defines a
mode is an attribute on `ServerStorage.QuakeAssets`, read at boot by
whichever engine the place runs. Nothing here lives in engine code.

## The parameter set

| Attribute | Type | Engines | Live-editable | Meaning |
|---|---|---|---|---|
| `engine` | `"nq"` / `"qw"` | — | no (boot) | engine selection for this place |
| `game` | string | both | no (boot) | base gamedir (`id1`, `lq1`) |
| `gamedir` | string | both | no (boot) | overlay mod dir stacked over `game` (`threewave`, `arena`, …); missing files fall through to the base game |
| `startmap` | string | both | no (boot) | first map |
| `deathmatch` | number | both | yes | QC rules: DM spawns/items, no monsters |
| `coop` | number | NQ | yes | coop rules |
| `skill` | number | NQ | yes | 0–3 |
| `teamplay` | number | both | yes | team rules (CTF needs it) |
| `fraglimit` / `timelimit` | number | both | yes | round end conditions |
| `samelevel` / `noexit` | number | both | yes | exit behavior rules |
| `maplist` | string | both | yes | space-separated rotation, e.g. `"dm1 dm2 dm3 dm4 dm5 dm6"`. **Presence enables rotation + intermission voting.** Absent = authentic exit chain (campaign untouched). |
| `votetime` | number | both | yes | vote window seconds before auto-advance (default 30) |
| `roblox_avatars` | bool | both | yes | avatar rigs for players — **default on when absent**; set `false` to opt out |
| `avatar_face` | bool | both | yes | sbar face = the local player's avatar head (tinted/pained/dying like the bitmaps) — **absent = follows `roblox_avatars`**; explicit `false` keeps the original gfx.wad faces even in avatars mode, `true` forces it on classic models |
| `mildmode` | bool | both | no (boot) | content softening for classification: gib models render untextured white, blood particles display white, player (bodyque) corpses fade out 10s after death. Render-only — the engine sim, wire protocol, and QC are untouched. **Default on when absent**; set `false` for the original presentation. See `src/client/render/mildmode.luau`. |
| `modekey` | string | both | no (boot) | stats/leaderboard scope label (`dm`, `ctf`, …); absent = derived from the other attributes (`statscore.deriveModeKey`) |
| `test_avatar_userid` | number | dev | yes | guest-rig look override in Studio tests |

Example places: FFA = `{deathmatch=1, fraglimit=15, timelimit=10,
maplist="dm1 dm2 dm3 dm4 dm5 dm6"}` · Threewave CTF = `{gamedir="threewave",
teamplay=1, deathmatch=1, maplist="ctf1 ctf2 ctf3"}` · Campaign = no
`deathmatch`, no `maplist` — nothing below activates.

## Dev mode presets (state as code)

Dev state is NOT hand-edited in Roblox: `src/server/modepresets.luau`
defines complete named states (campaign, coop, nq-dm, qw-dm, ctf, arena,
instagib) plus composable **modifiers** that overlay any preset as
`<preset>+<modifier>` — e.g. `qw-dm+original` or `campaign+original`
(the `original` modifier sets `mildmode=false` for the untouched engine
presentation). `src/server/modeconfig.luau` selects the active one. The
server boot applies the preset onto QuakeAssets attributes before
anything reads them — every key written, absent keys cleared, so the
running state always equals the file. Switch/inspect from the terminal:

    lune run tools/mode              # show active + all states
    lune run tools/mode ctf          # switch (rojo syncs; restart Play)
    lune run tools/mode off          # place attributes rule (ship mode)

Shipped places run with presets off and own their attributes per-place.
To set a place's attributes, stamp a preset instead of hand-typing them:

    lune run tools/mode stamp qw-dm  # prints a command-bar snippet

A preset only boots if the place's `QuakeAssets` folder actually holds the
game folders it reads (`game` + optional `gamedir`; the switch output lists
them). A mismatch — e.g. a dev preset wanting `id1` in a place stripped to
`lq1` — is a boot error naming both sides. To import exactly the folders a
preset needs, use `lune run tools/mode assets <preset>`
(docs/PUBLISHING.md walks through it).

Paste the snippet into the Studio command bar and save the place. The
snippet writes every KEY (absent keys cleared), so the place state equals
the preset exactly. A place missing `fraglimit`/`timelimit` silently boots
with no round-end limits — the rule cvars default to 0 and QC `CheckRules`
never fires.

## The director (rotation · voting · admin control)

Product layer, engine-agnostic, four files/blocks total:

- `src/server/director.luau` — vote lifecycle, rotation, admin command
  validation. Pure logic is lune-tested (`tests/test_director.luau`).
- `src/client/directorui.luau` — Roblox-native UI: intermission vote
  panel + admin match-control menu. Touch-first sizing.
- Marked `===== match director =====` blocks in `init.server.luau`,
  `qwserver.luau`, `init.client.luau`, `qwclient.luau`.

**REMOVAL**: delete the two files and the four marked blocks. The
engines revert to authentic behavior (dm maps loop forever, params
fixed at boot). No engine file is involved.

### Behavior

- Intermission starts (read from the `intermission_running` QC global —
  works identically on NQ progs and qwprogs) and `maplist` is set →
  vote opens: 3 candidates in rotation order after the current map.
- Players vote with keys 1–3 or by tapping the cards; live counts; one
  changeable vote per player.
- Vote resolves when the engine consumes the changelevel (someone
  pressed fire) **or** when `votetime` expires with everyone idling —
  the director then force-advances. Most votes wins; tie → rotation
  order; no votes → next in rotation.
- If QC requested a *different* map (real exit trigger, or a mod's own
  rotation such as Rocket Arena's localinfo cycling), **the mod wins**
  and the vote is discarded. The director only replaces the stock DM
  same-map loop.

## Stats & leaderboards

Product layer, engine-agnostic, same removal contract as the director
(delete `src/server/stats.luau` + `statscore.luau` + `statstore.luau` +
`src/client/leaderboardui.luau` and the marked `===== stats =====`
blocks in the four boot files).

- `src/server/statscore.luau` — pure counters/period/bucket math,
  lune-tested (`tests/test_stats.luau`).
- `src/server/stats.luau` — capture adapter: reads each client edict's
  `frags/health/deadflag/weapon` per heartbeat. Frag increases = kills
  (attributed to the killer's current weapon), decreases = suicides,
  `deadflag` edges = deaths, intermission snapshot = wins/matches
  (competitive places only), map change = round end. No engine edits.
- `src/server/statstore.luau` — persistence. Profiles in DataStore
  `rq-stats-1` (key `u<UserId>`), written as add-only delta merges via
  `UpdateAsync` (no session locks needed; safe across servers).
  Counters land in buckets `(all | day | week) × (global | m:<modekey>)`;
  stale period buckets are pruned. Leaderboards are OrderedDataStores
  `lb1:<stat>:<scope>:<period>` re-written from bucket totals on each
  flush (autosave ~120 s staggered, plus leave + server close); a
  period's stores freeze naturally when its day/week passes. A
  `leaderstats` folder feeds the native playerlist (Frags/Deaths), and
  the `Leaderboards` RemoteFunction serves top-50 pages (cached 45 s,
  per-player rate-limited) to the client UI. A `friends` scope ranks
  the requester's friends (self included) by reading their profiles
  directly (friend list cached 5 min, profiles 90 s, never-played
  misses 10 min, ≤100 reads per fetch) against the period's global
  bucket — OrderedDataStores can't be filtered by user.
- Tracked per scope: kills, deaths, suicides, net frags, wins, matches,
  rounds, playtime, joins, per-weapon kills, best round frags, best
  kill streak. Profile-level activity: `firstSeen`/`lastSeen` unix
  timestamps plus `daysActive`, `streakDays` (consecutive UTC days,
  updated on every write — stored eagerly because a streak cannot be
  reconstructed later), `bestStreakDays`, `lastActiveDay`.
- Studio without DataStore API access: writes disable themselves after
  the characteristic access error and the session runs in-memory.

### Callvote (mid-round player votes)

Any player can propose a change mid-round from the ballot button
(below the trophy) — one active vote at a time, yes/no via **F1/F2**
or the banner buttons, `votetime` window. The proposer auto-votes yes.
Resolution: passes early once yes alone is a strict majority of
*present* players (a lone player's vote passes instantly); fails early
once no has made that impossible; at expiry the majority of votes
*cast* decides — ties and zero participation fail. Round end or any
map change cancels the vote. Announcements are server console prints
(the engine notify surface), not UI.

The vote engine is generic — a proposal is any (key, value) the apply
layer understands. `director.VOTABLE` is the **view layer** deciding
what non-hosts may propose: map (rotation entries only), `fraglimit`,
`timelimit`, `samelevel`, `roblox_avatars`. Game-defining rules
(`deathmatch`/`teamplay`/`coop`/`skill`) are deliberately absent —
host-only via the admin menu. Guards: 60 s per-player proposal
cooldown, 15 s global cooldown after any vote, and map votes are
denied within 45 s of a changelevel (EditableMesh-budget spacing).

### Admin menu

Hosts (Studio, private-server owner, place creator — same policy as the
host-command gate) get a gear button (top-right) and the **P** key.
On connect, a host is told so through the engine's own notify surface —
a MOTD-style server console print (`src/server/hostgreeting.luau`, no
new UI, no engine edits; suppressed in Studio unless the
`RQDBG_HostGreeting` ServerStorage attribute is set). The
menu edits every live parameter: force-load any map, ±steppers for all
rule cvars (applied immediately; also written back to attributes so
they survive restarts), the rotation list, and the avatars toggle.
Boot-time params (`engine`/`game`/`mod`) display read-only.
