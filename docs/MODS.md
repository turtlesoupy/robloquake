# Running QuakeC mods (gamedir support)

RobloQuake runs unmodified third-party QuakeC mods the same way Quake does:
a mod is a *gamedir* stacked on top of the base game in the virtual
filesystem. Files the mod ships win; anything it doesn't ship falls through
to the base game (`lq1`/`id1`). The server loads the mod's own compiled
progs — `progs.dat` on the NetQuake boot, `qwprogs.dat` on the QuakeWorld
boot — through the same searchpath, and the VM resolves the mod's ABI
(globals/fields/functions) by name from the progs file itself. No engine
special-casing per mod, and **mod progs/QC are never edited**. If a mod
trips an engine gap, fix the engine generically.

Proven three times, with zero per-mod engine changes:
- `tests/test_scenario_ctf.luau` — Threewave CTF 4.21's shipped
  `qwprogs.dat` (a foreign 217-field ABI) plays a full CTF loop: team
  assignment, flag grab/capture/return, grapple, runes. Also verified live
  in Studio (docs/coverage/evidence/qw-ctf2m3-*.jpg).
- `tests/test_scenario_ra.luau` — Rocket Arena "Final Arena" 1.20 runs its
  round/queue loop: challenger queue, 10..1 countdown, arena loadout,
  winner-stays cycling, and fraglimit map rotation through QW localinfo
  (the mod's own rotate.cfg mechanism).
- `tests/test_scenario_tf.luau` — Team Fortress 2.9's shipped `qwprogs.dat`
  plays the 2fort loop on 2fort5: observer mode, team join (impulse
  140/141), class selection (impulse 100+class) with per-class speeds and
  loadouts, enemy flag grab and capture at the dropoff. Note: TF verifies
  serverinfo `*gamedir` == "fortress" at worldspawn, so its gamedir MUST be
  named `fortress` (the engine stamps `*gamedir` from the searchpath, like
  COM_Gamedir). LOCAL/DEV ONLY — see docs/mods-licenses.md.

## Add a mod in 6 steps

1. **Record the license first.** Add a provenance + license entry to
   [mods-licenses.md](mods-licenses.md) — source URLs, hashes if you have
   them, the verbatim permission language, and a ship gate note. Staged mod
   content stays gitignored and out of published places until that entry
   says otherwise.

2. **Stage the mod's gamedir** under `external_assets/<mod>/` (gitignored):
   its paks and/or loose files (`qwprogs.dat`/`progs.dat`, `maps/`,
   `sound/`, `progs/`, configs) in the mod's own layout, exactly as
   distributed.

3. **Build the asset chunks:**

   ```sh
   python3 tools/build_assets.py --game <mod> --source external_assets/<mod>
   ```

   Shipped paks are chunked as-is; loose game files are packed into one
   synthetic pak appended after them (docs, executables, QuakeC source, and
   `files.dat`/`*.src` are excluded; names are lowercased and
   slash-normalized because DOS-era mods relied on case-insensitive
   filesystems and our pak lookups are exact like Q_strcmp).

4. **Optional — sounds.** Mods run silent without a bank (missing regions
   just don't play). To bank base+mod sounds together:

   ```sh
   python3 tools/build_soundbank.py --game <mod> \
       --source external_assets/<base> external_assets/<mod>
   ```

   Later sources override earlier ones. Uploading the bank to Roblox is a
   USER action (moderation risk — and never upload a bank built from id1
   audio). Paste the uploaded asset id into `assets/<mod>/soundmap.txt`;
   rebuilds preserve it. The bundle publisher prefers the mod's soundmap
   over the base game's. Watch the ~7 minute Roblox audio cap.

5. **Import into Studio:** `rojo build assets.project.json -o
   build/QuakeAssets.rbxl`, open it, copy `ServerStorage.QuakeAssets.<mod>`
   into the place's existing `ServerStorage.QuakeAssets` (same flow as
   `tools/sync_assets.sh` for base games).

6. **Set place attributes** on `ServerStorage.QuakeAssets`:
   - `gamedir = "<mod>"` — stacks the mod over the base `game`
     (falls back to the base game with a warning if the folder is missing)
   - `engine = "qw"` for QuakeWorld mods (mod ships `qwprogs.dat`); leave
     unset for NetQuake mods (mod ships `progs.dat`)
   - `startmap` — a map the mod ships or supports
   - game rules the mod expects (`deathmatch`, `teamplay`, `fraglimit`,
     `timelimit`, `skill`, …) — check the mod's own `server.cfg` /
     `autoexec.cfg`; e.g. Threewave QW wants `teamplay 419`.

## Verifying offline (before Studio)

Prefer a lune scenario test over Studio: stack the gamedir in a test the
same way (`testutil.writePak` packs loose files exactly like
`build_assets.py`), boot the server, and drive real loopback clients. Use
`tests/test_gamedir.luau` (mechanics: override, fallthrough, foreign progs
on both boots) and `tests/test_scenario_ctf.luau` (a full mod acceptance
scenario) as templates. Mod internals are reachable generically:
`svr.progs.fielddefsByName["<mod field>"].ofs` reads any mod-added entity
field by name.

## What the engine guarantees

- **Searchpath fallthrough:** mod paks are searched before base-game paks
  (`COM_AddGameDirectory` order); precaches, gfx, configs, and progs all
  resolve through the same stack on both server and client (the client
  bundle publisher feeds from the stacked vfs).
- **Foreign ABIs:** progs are validated on load — wrong version or a
  modified system-vars header CRC errors out with a clear message, and an
  unknown builtin errors as `bad builtin call number N (<function>)` naming
  the QC function, not a crash.
- **No monsters in QW:** qwprogs-based mods are deathmatch-only by design;
  campaign-style mods need the NetQuake boot.

## Compiling source-only or in-house mods

Third-party mods that ship compiled progs need none of this (and their
progs/QC are never edited or recompiled). For a mod you own the source to
(or a source-only mod), compile offline:

```sh
tools/build_progs.sh <qc-source-dir> <output-dir>
# e.g. an in-house mod based on the GPL id QW QuakeC:
tools/build_progs.sh reference/quake-c/qw-qc build/inhouse
```

The script builds gmqcc on first use (into `build/gmqcc`) and compiles in
`-std=qcc` (vanilla) mode; the output keeps the standard progdefs header
CRC so the engine accepts it, and `tests/test_gamedir.luau` boots the
result as its toolchain leg. Stage the output like any other mod file
(loose in the mod's gamedir; the asset build packs it). fteqcc in vanilla
mode works too. CAUTION: gmqcc's progs.src auto-mode writes its output
into the current directory — the script compiles in a temp copy for that
reason; don't run compilers by hand inside a source tree you care about.

In-house mods are OVERLAYS: keep only the changed `.qc` files in
`mods/<name>/` and pass the GPL base as the third argument. The worked
example is [mods/instagib](../mods/instagib/README.md) — one modified
`weapons.qc` over qw-qc:

```sh
tools/build_progs.sh mods/instagib build/instagib reference/quake-c/qw-qc
```

`tests/test_gamedir.luau` proves it end to end (boots, one blast kills
through 200 armor, no ammo consumed).

## Known limits

- One gamedir at a time (`gamedir` attribute is a single name — matching
  vanilla Quake's `-game`).
- Audio banks are per-place uploads with the usual grant dance (asset →
  Permissions → add the experience) and the ~7 min cap.
