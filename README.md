# RobloQuake

A port of the Quake engine to Roblox — the real thing: original data formats,
the QuakeC virtual machine, and WinQuake's exact collision and physics,
running in Luau on Roblox's client/server model.

## What works

- **Full engine port**: PAK/BSP29/WAD2/MDL/SPR loaders, the complete QuakeC
  bytecode interpreter (progs.dat), world.c hull collision (verified
  bit-for-bit against compiled C), all movetypes, monster AI movement,
  player movement (air control, friction, stairs), and the protocol-15
  network layer over RemoteEvents.
- **Verified live in Studio**: signon → world render → running at authentic
  speed → shotgun at the exact 0.5s fire rate → grunts hunting the player
  ("was shot by a Grunt") → death → QuakeC-driven level restart.
- Server frames cost ~0.16ms (1% of a 60Hz tick) with a full e1m1.

## Requirements

- **Enable "Allow Mesh & Image APIs"** (Game Settings → Security; the place
  must be published once). Without it the client falls back to untextured
  wedge-part rendering; with it you get textured EditableMesh world geometry
  with lightmap vertex lighting and animated alias models.

## Intent

The goal is a **full engine port**, not a Quake-themed remake. Levels are
real `.bsp` files, game logic is the real `progs.dat` (so mods work),
movement physics match WinQuake, and multiplayer rides Quake's own
svc/clc protocol over Roblox remotes.

## Assets

Development happens against the **original Quake shareware assets**
(`external_assets/quake106/`, gitignored) because they are the ground truth
for correctness. Before anything is published to Roblox, id Software content
must be replaced with [LibreQuake](https://github.com/lavenderdotpet/LibreQuake).

`tools/build_assets.py` splits pak files into base64 chunks under `assets/`
and `tools/build_soundbank.py` builds the concatenated audio bank. All of
`assets/` is a **build artifact** (gitignored) — the repo ships the tools,
not the data. At runtime the server holds the chunks in
`ServerStorage.QuakeAssets` and streams a per-map bundle to clients.

## Tooling

- [Rojo](https://rojo.space/) — two project files:
  - `default.project.json` syncs `src/` (the code) — this is your daily
    `rojo serve`.
  - `assets.project.json` syncs `assets/` into `ServerStorage.QuakeAssets` —
    run only when the pak data changes (`rojo serve assets.project.json`).
- [Rokit](https://github.com/rojo-rbx/rokit) manages the toolchain.
- [Lune](https://lune-org.github.io/docs) runs the offline test suite.

```sh
rokit install                              # toolchain

# regenerate the (gitignored) asset bundle from LibreQuake, then sync it once
python3 tools/build_assets.py    --game lq1
python3 tools/build_soundbank.py --game lq1
rojo build assets.project.json -o assets.rbxm   # or: rojo serve assets.project.json

rojo serve                                 # day-to-day: code only
```

### Tests

Every subsystem has offline tests that run against the real shareware data:

```sh
for f in tests/test_*.luau; do lune run "$f"; done
```

`tests/test_trace.luau` compares hull traces against ground truth produced
by compiling the verbatim WinQuake collision code (`tools/trace_truth.c`).
`tests/test_server.luau` boots e1m1 headless and plays it with a fake
client. `tests/test_loopback.luau` runs the real client state machine
against the real server in one process.

## Layout

```
default.project.json     Rojo map for the code (daily sync)
assets.project.json      Rojo map for the asset bundle (occasional sync)
src/shared/engine/       The engine (platform-independent Luau)
  common/                buffers, math, tokenizer, net messages, cvars
  bsp/ models/ gfx/      BSP29, MDL/SPR, WAD2 + palette loaders
  progs/                 progs.dat loader + QuakeC VM + ABI defs
  server/                world collision, physics, monster move, host loop
  client/                cl_parse/cl_main port (state machine, lerp)
src/server/              Roblox server bootstrap (remotes, heartbeat)
src/client/              Roblox client (renderer, input, view, HUD)
reference/               WinQuake + QuakeC sources (gitignored, GPL)
```

## Licensing

The engine port is a derivative work of id Software's WinQuake sources,
released under **GPL-2.0** — so this repository's code is GPL-2.0 (see
[`LICENSE`](LICENSE)). LibreQuake content is separately licensed and is a
build-time dependency, not part of this repo. Original id Software assets
are proprietary and never ship.
