# RobloQuake

A port of the original 1996 Quake engine to Luau on Roblox.

https://github.com/user-attachments/assets/2ba6229f-9826-49f8-8965-2ca19b3d7fd4

## What works

- **Both original engines.** **NetQuake** (campaign/coop) and
  **QuakeWorld** (competitive) are ported to Luau and boot from the same
  codebase, selected per place. Both are verified function-by-function
  against the original C sources (see [Fidelity](#fidelity) below).
- **Assets from Quake shareware, full Quake, or
  [LibreQuake](https://github.com/lavenderdotpet/LibreQuake).** Publishing
  to Roblox is limited to LibreQuake assets.
- **Full mod support.** Unmodified third-party QuakeC mods run as gamedirs
  stacked over the base game, exactly like `-game` in DOS Quake. Working
  configurations ship for **Rocket Arena**, **Threewave CTF**, and **Team
  Fortress** (each needs its original mod files), plus an in-house instagib
  overlay. See [docs/MODS.md](docs/MODS.md).

## Layout

```
default.project.json     Rojo map for the code (daily sync)
assets.project.json      Rojo map for all asset bundles (occasional sync)
assets-current.project.json  generated per-mode asset map (gitignored)
src/shared/engine/       The engine (platform-independent Luau)
  common/                buffers, math, tokenizer, net messages, cvars
  bsp/ models/ gfx/      BSP29, MDL/SPR, WAD2 + palette loaders
  progs/                 progs.dat loader + QuakeC VM + ABI defs
  server/                world collision, physics, monster move, host loop
  client/                cl_parse/cl_main port (state machine, lerp)
src/server/              Roblox server bootstrap (remotes, heartbeat)
src/client/              Roblox client (renderer, input, view, HUD)
docs/coverage/           function-by-function coverage manifests
external_assets/         game + mod data (gitignored)
assets/                  built base64 chunks (gitignored build artifact)
reference/               WinQuake + QuakeC sources (gitignored, GPL)
```

`tools/build_assets.py` splits pak files into base64 chunks under
`assets/`; at runtime the server holds them in
`ServerStorage.QuakeAssets` and streams a per-map bundle to clients. The
repo ships the tools, not the data.

## Getting started

You need [Rokit](https://github.com/rojo-rbx/rokit), Python 3, and Roblox
Studio.

**1. Put game files in place** (everything under `external_assets/` is
gitignored):

| Content | Where it goes |
|---|---|
| Quake shareware / full | `external_assets/quake106/extracted/id1/pak0.pak` (+ `pak1.pak` from the full game) |
| LibreQuake | `external_assets/librequake/full/id1/` |
| Threewave CTF | `external_assets/threewave/` |
| Rocket Arena | `external_assets/rocketarena/` |
| Team Fortress 2.9 | `external_assets/fortress/` |

Mod dirs hold the files exactly as the mod was distributed (paks and/or
loose `qwprogs.dat`, `maps/`, `sound/`, ...). Before adding a new mod,
read [docs/MODS.md](docs/MODS.md) — step one is recording its license in
[docs/mods-licenses.md](docs/mods-licenses.md).

**2. Build and import the assets:**

```sh
rokit install                              # toolchain
tools/sync_assets.sh id1                   # or: tools/sync_assets.sh lq1
python3 tools/build_soundbank.py --game id1
# mods: python3 tools/build_assets.py --game threewave --source external_assets/threewave

lune run tools/mode assets ctf             # asset import project for a preset
rojo serve assets-current.project.json     # connect in Studio, accept, disconnect
```

In Studio, enable **Allow Mesh & Image APIs** (Game Settings → Security;
the place must be published once). Without it you get untextured
wedge-part rendering instead of textured EditableMesh geometry.

**3. Run it:**

```sh
rojo serve                                 # day-to-day: code only
```

then hit Play in Studio.

**4. Switch configurations.** A configuration ("mode") is just a set of
attributes on `ServerStorage.QuakeAssets`, read at boot: engine, base
game, gamedir, rules, map rotation. Named presets set all of them at
once. In development, switch from the terminal:

```sh
lune run tools/mode                        # show active preset + all presets
lune run tools/mode off                    # stop overriding; place attributes rule

lune run tools/mode campaign               # id1 singleplayer (needs quake106 assets)
lune run tools/mode coop                   # id1 campaign, coop rules
lune run tools/mode qw-dm                  # QuakeWorld deathmatch on dm1-dm6
lune run tools/mode ctf                    # Threewave CTF (needs threewave assets)
lune run tools/mode arena                  # Rocket Arena (needs rocketarena assets)
lune run tools/mode tf                     # Team Fortress (needs fortress assets; dev only)
lune run tools/mode lq-dm                  # LibreQuake deathmatch (needs librequake assets)
```

Restart Play after switching. The full preset list is `campaign`, `coop`,
`nq-dm`, `qw-dm`, `ctf`, `arena`, `tf`, `instagib`, `lq-dm`, and `lq-ctf`;
modifiers compose as `preset+modifier`, e.g. `qw-dm+original` for the
untouched 1996 presentation.

Two things to know:

- A preset only boots if the place's `QuakeAssets` folder actually holds
  the game folders it needs (a mismatch is a boot error naming both
  sides). `lune run tools/mode assets <preset>` builds the import project
  with exactly those folders — that's the step 2 import above.
- While a dev preset is active it **overrides** the place's attributes.
  For a shipped place, run `lune run tools/mode off` and set the
  attributes permanently instead: `lune run tools/mode stamp <preset>`
  prints a snippet to paste into the Studio command bar, then save the
  place. Never hand-type attributes — a missing `fraglimit`/`timelimit`
  silently boots a server with no round-end limits.

Details in [docs/MODES.md](docs/MODES.md); the full publish flow (build
`lq1`, strip id1, stamp, publish) is
[docs/PUBLISHING.md](docs/PUBLISHING.md).

## Tests

Every subsystem has offline tests ([Lune](https://lune-org.github.io/docs))
that run against the real game data. One script runs `luau-lsp analyze`
strict-mode checking plus the full sweep:

```sh
tools/check.sh            # analyze + all tests
tools/check.sh --analyze  # static analysis only
```

Analysis is baselined against `tools/analyze_baseline.txt` so pre-existing
debt doesn't re-flag; `tools/check.sh --update-baseline` grandfathers new
debt in. To run tests by hand: `for f in tests/test_*.luau; do lune run
"$f"; done`.

The heavyweights: `tests/test_trace.luau` compares hull traces against
ground truth from compiling the verbatim WinQuake collision code,
`tests/test_server.luau` boots e1m1 headless and plays it with a fake
client, `tests/test_loopback.luau` runs the real client state machine
against the real server in one process, and the `test_scenario_*.luau`
files play full CTF / Rocket Arena / Team Fortress rounds against each
mod's shipped progs.

## Fidelity

The port is accounted for function by function against the original C.
[docs/coverage/](docs/coverage/README.md) holds four manifests — NQ
server, NQ client, QW server, QW client — where every C function is
**VERIFIED** (a test or compiled-C ground-truth harness proves the
behavior, evidence cited per row), **SUBSTITUTED** (replaced by a platform
mechanism, justification stated), or **N/A** (dead code, DOS-era
machinery, or flows Roblox owns). 825 functions verified, zero rows open.

Behavioral ground truth comes from compiling the actual WinQuake code:
hull collision is bit-exact against `tools/trace_truth.c`, the player
movement chain is within 0.0002 units over 300 scripted ticks, and QW
view/weapon feel is frame-traced against verbatim `view.c`. Known
divergences live in [FIDELITY.md](FIDELITY.md) — every one is verified,
fixed, open, or a justified substitution.

## Roblox changes

The big deliberate departures from stock Quake, all product-layer —
engine files aren't involved, and each is removable:

- **Roblox avatars** (`roblox_avatars`, default on): players render as
  their own Roblox avatar rig instead of player.mdl, and the HUD status
  bar face becomes your avatar head (tinted and pained like the
  bitmaps). Set the attribute `false` for classic models.
- **Roblox-native menus**: the original DrawPic menu is replaced with a
  touch-friendly pause menu, settings, and an about screen. Mobile gets
  on-screen controls.
- **Match director**: optional map rotation with intermission voting
  (`maplist` attribute enables it; absent = authentic exit chain),
  mid-round callvotes, and a host admin menu for live rule changes.
- **Stats and leaderboards**: per-player kill/death/win tracking in
  DataStores with global, weekly, and friends leaderboards.
- **Mild mode** (`mildmode`, default on): render-only content softening —
  white gibs/blood, corpses fade out. The sim, wire protocol, and QC are
  untouched; `+original` restores the 1996 presentation.
- **Platform substitutions**: the software rasterizer is replaced by
  EditableMesh world geometry with lightmap vertex lighting, and
  UDP/WinSock networking by RemoteEvents carrying the original protocol.

## Licensing

The engine port is a derivative work of id Software's
[Quake sources](https://github.com/id-Software/Quake), released under
**GPL-2.0** — so this repository's code is GPL-2.0 (see
[LICENSE](LICENSE)). Game content is separate: published places use
[LibreQuake](https://github.com/lavenderdotpet/LibreQuake) assets
(separately licensed, build-time dependency, not part of this repo).
Original id Software assets are proprietary and never ship; per-mod
provenance and ship gates are in
[docs/mods-licenses.md](docs/mods-licenses.md).
