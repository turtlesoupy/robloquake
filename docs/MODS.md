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

Proven by `tests/test_scenario_ctf.luau`: Threewave CTF 4.21's shipped
`qwprogs.dat` (a foreign 217-field ABI) plays a full CTF loop — team
assignment, flag grab/capture/return, grapple, runes — over the loopback
wire with zero mod edits.

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

## Known limits

- Compiled progs only: there is no in-repo QC compiler step yet, so
  source-only mods must be compiled elsewhere (fteqcc in vanilla mode or id
  qcc) before staging. (Planned as a `tools/` step.)
- One gamedir at a time (`gamedir` attribute is a single name — matching
  vanilla Quake's `-game`).
- Audio banks are per-place uploads with the usual grant dance (asset →
  Permissions → add the experience) and the ~7 min cap.
