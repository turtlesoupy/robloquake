# RobloQuake

A port of the Quake engine to Roblox.

## Intent

The goal is a **full engine port**, not a Quake-themed remake: the original data
formats and game logic running inside Roblox, in Luau. That means:

- **Levels** — load real `.bsp` maps (world geometry, lightmaps, entities,
  brush collision), rendered with native Roblox instances.
- **Mods** — support the Quake modding ecosystem: QuakeC game logic, custom
  maps, models (`.mdl`), sounds, and eventually full mod directories, so
  existing community content runs with little or no conversion.
- **Game feel** — faithful movement physics (air control, bunny hopping,
  rocket jumps), weapons, monsters, and network play built on Roblox's
  client/server model.

## Assets

Development happens against the **original Quake assets** (`id1/pak0.pak`,
`pak1.pak` from a legally owned copy) because they are the ground truth for
correctness. Those assets are proprietary and are **never committed to this
repo or shipped**.

Before anything is published to Roblox, all id Software content is replaced
with [LibreQuake](https://github.com/lavenderdotpet/LibreQuake), a free,
BSD-licensed content replacement that works with the same engine and formats.

Local asset distributions live in `external_assets/` (gitignored). Currently
that's the Quake 1.06 shareware release, extracted from `quake106.zip` — the
DOS installer whose `resource.dat` contains the shareware `pak0.pak`.

## Tooling

- [Rojo](https://rojo.space/) syncs the code in `src/` into Roblox Studio.
- [Rokit](https://github.com/rojo-rbx/rokit) manages the toolchain
  (`rokit.toml` pins the Rojo version).

### Getting started

```sh
rokit install   # install the pinned toolchain
rojo serve      # start the sync server
```

Then in Roblox Studio, open the Rojo plugin and hit **Connect**
(defaults to `localhost:34872`).

## Layout

```
default.project.json   Rojo project map
src/
  shared/              Engine code shared by client and server (ReplicatedStorage)
  server/              Server entry points (ServerScriptService)
  client/              Client entry points (StarterPlayerScripts)
```
