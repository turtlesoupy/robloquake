# Publishing a LibreQuake place

The published Roblox place must ship **only LibreQuake** (`lq1`) content —
id Software assets (`id1`) and id1-based mods (`threewave`, `arena`) are
proprietary and must never reach a published place (see
[Licensing](../README.md#licensing)). Development runs against the id1
shareware data for correctness; publishing is a deliberate swap to `lq1`.

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
the place. Use the lq1-only project instead:

```sh
# free the normal port first: the daily code serve also uses 34872
pkill -f "rojo serve"
rojo serve assets-lq1.project.json           # serves ONLY assets/lq1 on :34872
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

Delete every game folder except `lq1` from `ServerStorage.QuakeAssets`.
Via the Studio command bar (or the Studio MCP `execute_luau`):

```lua
local qa = game:GetService("ServerStorage").QuakeAssets
for _, c in qa:GetChildren() do
    if c.Name ~= "lq1" then c:Destroy() end
end
```

Confirm the only child left is `lq1`.

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
| Serve lq1 only | `rojo serve assets-lq1.project.json` | shell (port 34872) |
| Import | Rojo plugin → Connect → accept → Disconnect | Studio |
| Strip id1 etc. | destroy non-`lq1` children of `QuakeAssets` | Studio |
| Stamp mode | `lune run tools/mode stamp lq-dm` → apply | shell → Studio |
| Restore code serve | `rojo serve` | shell |
| Publish | play-test heavy maps → Save → Publish | Studio |
