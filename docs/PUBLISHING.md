# Publishing a LibreQuake place

The published Roblox place must ship **only cleared content** — id Software
assets (`id1`) and the `arena` mod are proprietary and must never reach a
published place (see [Licensing](../README.md#licensing)). Development runs
against the id1 shareware data for correctness; publishing is a deliberate
swap to `lq1`. Two publishable shapes exist:

- **`lq-dm`** — LibreQuake only (`lq1`).
- **`lq-ctf`** — LibreQuake + Threewave CTF (`lq1` + `threewave`): cleared
  2026-07-07 with Zoid's permission (see docs/mods-licenses.md, Threewave
  ship gate).

The steps below are written for `lq-dm`; for CTF substitute `lq-ctf`
everywhere — `lune run tools/mode assets lq-ctf` scopes the import to
`lq1` + `threewave` and its strip snippet keeps both. The threewave
soundbank (`assets/threewave/soundbank.wav`) imports alongside the lq1 one.

This is the end-to-end runbook. It exists because two steps trip people up:
getting 250 MB of asset instances into the place, and switching the place's
mode attributes without hand-typing them.

## What can and can't be scripted

- **Building the asset chunks** — scripted (`tools/sync_assets.sh lq1`).
- **Getting them into the place** — *not* scriptable from the filesystem.
  The chunks are Roblox instances; only Studio can hold them. Rojo (or a
  manual copy) is the bridge. Lune/Python cannot push instances into a place.
- **Setting the mode attributes** — the `tools/mode` script only *prints*
  the snippet for the same reason: a filesystem script can't write into a
  Studio place. Apply it in Studio (command bar, or the Studio MCP).

## 1. Build the lq1 asset bundle

```sh
tools/sync_assets.sh lq1                     # chunks pak0/pak1 + loose files + qwprogs
python3 tools/build_soundbank.py --game lq1  # 18 MB soundbank.wav (imported separately)
```

This writes `assets/lq1/` (gitignored build output). Sanity-check the chunk
counts — a stale/partial LibreQuake download shows up as a short pak1:

```
pak0=645  pak1=685  pak2=389  qwprogs=2 chunks   # current full set
```

## 2. Import lq1 into the place via a filtered Rojo serve

Do **not** serve `assets.project.json` for a publish — it maps *all* games
(`id1`, `arena`, `threewave`, `lq1`), so connecting would push id1 back into
the place. Generate a project scoped to exactly what the target mode needs:

```sh
lune run tools/mode assets lq-dm             # writes assets-current.project.json (lq1 only)
# free the normal port first: the daily code serve also uses 34872
pkill -f "rojo serve"
rojo serve assets-current.project.json       # serves ONLY assets/lq1 on :34872
```

In Studio's Rojo plugin: **Connect** to `localhost:34872`, accept the patch
(refreshes `ServerStorage.QuakeAssets.lq1`), then **Disconnect**.

- Because the project declares only `lq1`, the sync touches nothing else —
  it will not re-create folders you deleted in step 3, and it will not
  disturb the mode attributes on the `QuakeAssets` folder (Rojo doesn't
  manage attributes it isn't given).
- The `soundbank.wav` is **not** a Rojo-syncable type; it goes through the
  audio-upload path, not this serve.

When done, restore the code serve: `pkill -f "rojo serve" && rojo serve`.

## 3. Strip non-lq1 games from the place

Delete every game folder except `lq1` from `ServerStorage.QuakeAssets` —
the `tools/mode assets` run above prints this exact snippet. Via the Studio
command bar (or the Studio MCP `execute_luau`):

```lua
local keep={["lq1"]=true} local qa=game:GetService("ServerStorage").QuakeAssets for _,c in qa:GetChildren() do if not keep[c.Name] then c:Destroy() end end print("QuakeAssets stripped to: lq1")
```

Confirm the only child left is `lq1`.

> **⚠️ Align the dev preset with the stripped place.** The dev preset in
> `src/server/modeconfig.luau` is *code*: the code serve syncs it into the
> place, and at boot it **overrides** the stamped attributes. If it names a
> preset whose `game` you just deleted (e.g. `qw-dm` → `id1`), the next Play
> session fails at boot with a "QuakeAssets only holds […]" error. Either
> switch it to a matching preset (`lune run tools/mode "qw-dm+librequake"`)
> to keep play-testing, or turn presets off for the final publish state:
>
> ```sh
> lune run tools/mode off
> ```
>
> and let the code serve sync that before saving.

## 4. Stamp the mode attributes

Published places run with dev presets **off**, so the attributes live in the
place file. Generate the snippet and apply it — never hand-type it (a missing
`fraglimit`/`timelimit` silently boots a no-limit server):

```sh
lune run tools/mode stamp lq-dm
```

Paste the printed line into the Studio command bar (or run it through the
Studio MCP). `lq-dm` = NetQuake DM, `game=lq1`, starts on `lqdm1`, full
`lqdm1..13` rotation, Roblox avatars on. For the QuakeWorld variant use
`lune run tools/mode stamp "nq-dm+librequake"` etc. — the `+librequake`
modifier carries the lq1 game + lqdm rotation over any base preset.

## 5. Play-test, then publish

- **Play through the heavy maps** (`lqdm3`, `lqdm6`, `lqdm13`, and to a
  lesser extent `lqdm5`/`lqdm9`) in a Studio Play session before publishing.
  They carry 2–3× the geometry of the light maps and can starve Studio's
  EditableMesh budget. If one renders broken, drop it from the `maplist`
  attribute and re-save. (Face counts: `lqdm11` ≈ 2.1k … `lqdm3` ≈ 12.1k.)
- **Save** the place, then **Publish**.

## Quick reference

| Step | Command / action | Where |
|---|---|---|
| Build chunks | `tools/sync_assets.sh lq1` | shell |
| Build audio | `python3 tools/build_soundbank.py --game lq1` | shell |
| Scope + serve lq1 only | `lune run tools/mode assets lq-dm` → `rojo serve assets-current.project.json` | shell (port 34872) |
| Import | Rojo plugin → Connect → accept → Disconnect | Studio |
| Strip id1 etc. | run the strip snippet printed by `tools/mode assets` | Studio |
| Align dev preset | `lune run tools/mode off` (or a matching `+librequake` preset) | shell |
| Stamp mode | `lune run tools/mode stamp lq-dm` → apply | shell → Studio |
| Restore code serve | `rojo serve` | shell |
| Publish | play-test heavy maps → Save → Publish | Studio |
