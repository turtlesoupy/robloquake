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
| `maplist` | string | both | yes | space-separated rotation, e.g. `"dm3 dm4 dm6 dm2"`. **Presence enables rotation + intermission voting.** Absent = authentic exit chain (campaign untouched). |
| `votetime` | number | both | yes | vote window seconds before auto-advance (default 30) |
| `roblox_avatars` | bool | NQ (QW pending) | yes | avatar rigs for players |
| `test_avatar_userid` | number | dev | yes | guest-rig look override in Studio tests |

Example places: FFA = `{deathmatch=1, fraglimit=15, timelimit=20,
maplist="dm3 dm4 dm6 dm2 dm5"}` · Threewave CTF = `{gamedir="threewave",
teamplay=1, deathmatch=1, maplist="ctf1 ctf2 ctf3"}` · Campaign = no
`deathmatch`, no `maplist` — nothing below activates.

## Dev mode presets (state as code)

Dev state is NOT hand-edited in Roblox: `src/server/modepresets.luau`
defines complete named states (campaign, nq-dm, qw-dm, ctf, arena,
instagib) and `src/server/modeconfig.luau` selects the active one. The
server boot applies the preset onto QuakeAssets attributes before
anything reads them — every key written, absent keys cleared, so the
running state always equals the file. Switch/inspect from the terminal:

    lune run tools/mode              # show active + all states
    lune run tools/mode ctf          # switch (rojo syncs; restart Play)
    lune run tools/mode off          # place attributes rule (ship mode)

Shipped places run with presets off and own their attributes per-place.

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

### Admin menu

Hosts (Studio, private-server owner, place creator — same policy as the
host-command gate) get a gear button (top-right) and the **P** key. The
menu edits every live parameter: force-load any map, ±steppers for all
rule cvars (applied immediately; also written back to attributes so
they survive restarts), the rotation list, and the avatars toggle.
Boot-time params (`engine`/`game`/`mod`) display read-only.
