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
(also gitignored) which sync to `ReplicatedStorage.QuakeAssets` and are
reassembled at runtime.

## Tooling

- [Rojo](https://rojo.space/) syncs `src/` into Studio (`rojo serve`).
- [Rokit](https://github.com/rojo-rbx/rokit) manages the toolchain.
- [Lune](https://lune-org.github.io/docs) runs the offline test suite.

```sh
rokit install                    # toolchain
python3 tools/build_assets.py    # chunk the pak for syncing
rojo serve                       # then Connect from the Rojo plugin
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
default.project.json     Rojo project map
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

## Licensing note

The engine port is derived from the GPL-2.0 WinQuake sources; treat this
repository's engine code as GPL-2.0. LibreQuake content is BSD-licensed.
Original id Software assets are proprietary and never ship.
