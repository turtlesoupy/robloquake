# moderateMode spec (not yet implemented)

## Rating rationale (Roblox Maturity & Compliance questionnaire, checked 2026-07)

- **Dismemberment is the Restricted (17+) trigger.** Violence "Restricted"
  explicitly lists "beheadings/decapitation, dismemberment, severed/severing
  body parts, presence of organs". Red meat gibs + thrown heads are exactly
  this — they, not corpses, are what forces the high rating.
- **Heads are special even when white.** A white-textured `h_player.mdl` is
  still a recognizable severed head (= decapitation depiction). In moderate
  mode, render all `progs/h_*.mdl` as the *gib1 chunk geometry* (substitute
  modelindex at link time — both models are precached together on every
  map), so nothing head-shaped ever appears.
- **White particles ≠ blood.** With no red blood anywhere, the blood
  disclosure can be answered "none". (Red-but-pixelated could arguably pass
  as "unrealistic blood", but white is unambiguous.)
- **Persistent non-bloody corpses are fine at Moderate.** Moderate violence
  = "non-graphic, realistic-looking depictions of violence and/or death".
  Only "Mild" requires bodies to vanish instantly — and a realistic-weapon
  FPS is Moderate-floor regardless, so chasing Mild isn't worth radical
  changes. Corpse fading is therefore *sufficient, even conservative* for
  Moderate; it's polish + performance, not a rating requirement.
- **Residual risk lives in map/monster content, not this switch** (campaign
  zombies' gore textures, gothic map imagery). Irrelevant for DM/CTF places;
  revisit only if shipping the campaign place at Moderate.


Goal: a live-flippable switch that removes the content most likely to push the
Roblox maturity rating up — gore gibs and permanent corpses — while keeping
gameplay byte-identical (all changes are client-side *rendering*; the QW/NQ
sim, QuakeC, and the wire protocol are untouched, so servers with the flag in
either state stay compatible and demos/replays are unaffected).

In moderate mode:
- Gib chunks (meat + heads) render as plain **white** untextured chunks with
  **white** particle trails instead of blood trails.
- Blood impact particles (TE_BLOOD / svc_particle blood, lightning blood)
  become white sparks.
- Corpses and settled gibs linger briefly, then **fade out** client-side
  (server bodyque still exists; the client just stops drawing it).

## 1. The switch

Follows the `roblox_avatars` pattern exactly (the one proven live-flippable):

- `src/server/modepresets.luau` — add `"moderate"` to `modepresets.KEYS`.
  Presets may set it (e.g. `moderate = false` on dev/demo presets).
- `src/server/avatarrigs.luau` (the shared NQ+QW product-layer setup that
  already mirrors `roblox_avatars` QuakeAssets → QuakeClientFS with a live
  `GetAttributeChangedSignal` re-mirror) — mirror `moderate` the same way,
  ~6 lines next to the existing block at the top of the returned function.
- Client: `moderateOn()` helper in both `src/client/qwclient.luau` and
  `src/client/init.client.luau`, modeled on `avatarsOn()`
  (qwclient.luau:400): `clientAssets:GetAttribute("moderate")`. Read every
  frame — no caching — so flipping the QuakeAssets attribute in Studio (or
  via `lune run tools/mode`) takes effect instantly, mid-match.

**DECISION NEEDED — default when the attribute is absent.** Two options:
- (a) absent = ON (safe by default, matches the roblox_avatars "product
  default ON" philosophy; shipped places get the low-rating behavior without
  remembering to opt in; dev presets / the tweet-demo preset set
  `moderate = false` to get real Quake). **Recommended.**
- (b) absent = OFF (no visual change until explicitly enabled).
The mirror line encodes it: `assets:GetAttribute("moderate") ~= false` for
(a), `== true` for (b).

## 2. Gibs → white chunks, white trails

### Which models are "gib" (matched by precache name)
`progs/gib1.mdl`, `progs/gib2.mdl`, `progs/gib3.mdl`, `progs/zom_gib.mdl`,
and every head: `progs/h_*.mdl` prefix (h_player, h_ogre, h_zombie, …).
Define one `GIB_MODELS`/`isGibModel(name)` helper per client (or share it).

**Heads get geometry substitution, not just a white skin** (see rating
rationale): when moderate and the name matches `progs/h_*`, resolve the
model index of `progs/gib1.mdl` from `cl.model_name` (it is precached on
every map alongside the heads) and call `linkEnt` with that index instead.
The white-texture path below then applies to the substituted chunk. The
existing `renderDefs[key] ~= def` check in `linkEnt` already handles the
def swap when the flag flips live.

### White body (no EditableImage churn)
- `src/client/render/entrender.luau`: alias parts get their texture via
  `part.TextureContent = Content.fromObject(img)` at create (line ~195) and
  in the skin-swap block of `updateAlias` (lines ~257–282). Add a
  `white: boolean?` parameter to `updateAlias` (threaded from the caller so a
  live flip needs no model-def cache invalidation — `getModelDef` caches by
  modelindex, don't bake the flag into the def). When `white`:
  - clear `part.TextureContent` (assign empty `Content.none`) and skip the
    skin-key logic; fold `white` into `wantSkinKey` (e.g. negate the key) so
    flipping back re-applies the real skin through the existing swap path.
  - The untextured MeshPart then renders as its `Color`, which
    `entrender.setLight` already drives grayscale (`part.Color =
    Color3.new(l,l,l)`, line ~405) — i.e. a lit white chunk, for free, no new
    EditableImage (respects the editable-memory budget discipline).
- Callers: qwclient `linkEnt` (line ~716/740) computes
  `local white = moderateOn() and isGibModel(cl.model_name[modelindex])` and
  passes it; NQ init.client does the same at its `updateAlias` call
  (line ~2024, name from `c.model_precache[e.modelindex + 1]`).

### White trails
- `src/client/render/particlesim.luau` — `rocketTrail` types **2** (blood)
  and **4** (slight blood) set `p.color = 67 + rand&3`; when moderate use
  fullbright white palette index **254** instead. Least-invasive plumbing: a
  `moderate` field on `System` (set every frame by both clients:
  `psys.moderate = moderateOn()`), branch on `sys.moderate` inside
  `rocketTrail`. Trail *emitters* need no change — qwclient.luau:821/823 and
  init.client.luau:2038/2040 keep calling type 2/4; only the color changes.

### White impact blood
- QW (`src/client/qwclient.luau`): `TE_BLOOD` → `runEffect(..., 73, ...)`
  (line 656) and `TE_LIGHTNINGBLOOD` → color 225 (line 658): substitute 254
  when moderate. (`runEffect` randomizes the low 3 bits; 254 stays in the
  white ramp 248–254 — fine.)
- NQ (`src/client/init.client.luau`): blood arrives as generic
  `svc_particle` → `runEffect(psys, org, dir, color, count, …)` (line 1216).
  Remap exactly `color == 73` (SpawnBlood) and `color == 225`
  (lightning blood) → 254 when moderate; leave all other wire colors alone
  (wizard spit, teleport splash etc. aren't gore).
- Leave `blobExplosion` (tarbaby, colors 66–71/150–156) alone — purple goo,
  not blood.

## 3. Corpse (and settled-gib) fade-out

Constants (shared): `CORPSE_LINGER = 8` s untouched, `CORPSE_FADE = 2` s
transparency ramp, then invisible until the entity disappears server-side.
Fade is **client-side only** — bodyque/gib edicts persist on the server
(vanilla gibs never remove themselves), the client just stops rendering.

Three render paths carry corpses:

### a) Avatar rigs (the shipping default) — `src/client/render/avatarlayer.luau`
`updatePlayer` already knows death: `dead = forceDead or isDeathFrame(frame)`
(line 383). Slots: live players (die → respawn quickly; fading optional but
harmless) and bodyque corpses (QW: key `1000 + es.number`, qwclient.luau:779;
NQ: `num > maxclients`, init.client.luau ~1997) — these are the permanent ones.
- Track `deadSince[slot]`: set on the alive→dead transition; **reset when the
  corpse identity changes** — bodyque slots are recycled, so if `dead` is
  already true but the origin jumps > ~4 quake units, treat it as a new
  corpse and restart the timer.
- When `now - deadSince > LINGER`, compute `alpha = min(1, (elapsed-LINGER)/FADE)`
  and call a new `avatarrender.setFade(ae, alpha)`; at `alpha == 1`,
  `setVisible(ae, false)` **but keep returning `true`** from `updatePlayer` —
  returning false would drop the caller back to the alias player.mdl
  renderer and resurrect the corpse.
- `src/client/render/avatarrender.luau`: `setFade(ae, alpha)` — record each
  BasePart/Decal's base transparency once at rig build, then set
  `Transparency = base + (1-base)*alpha` across the rig (accessories
  included). Clear on `alpha == 0` / rig reuse (respawn must arrive opaque).

### b) Alias corpses, avatars off — qwclient `relinkEntities` / NQ relink
Eligible per frame: (model is the player model AND frame in the death band —
use `avatarLayer.isDeathFrame`, which is pure frame math) OR `isGibModel`
(covers heads + meat chunks + zombie gibs, which also never despawn).
- Per-key table `fadeState[key] = { since: number, org: vector }` in each
  client. Timer only runs while `es.origin` is unchanged frame-to-frame
  (gibs bounce for a moment; motion resets `since`, so they fade only after
  settling — and a recycled bodyque ent auto-resets via the origin jump).
- Apply via new `entrender.setFade(re, alpha)` (sets `part.Transparency` on
  the alias MeshPart; `setLight` touches only `Color`, no conflict). At
  alpha 1 keep the key alive (skip `linkEnt` work, keep `liveKeys[key]`)
  rather than destroying — avoids create/destroy churn if the ent stays in
  the PVS, and state drops naturally when the server ends the entity.
- Sweep `fadeState` alongside the existing `liveKeys` cleanup on entity
  disappearance / level change (trailOrigins already does this pattern).

### c) Self view when dead
Unchanged — the death-cam (qwclient.luau:1780–1789, corpse view at −16, gib
head view) is gameplay feedback, not gore. `PF_GIB` handling stays.

## 4. Explicitly out of scope / optional later
- Gib **sounds** (player/gib.wav, udeath.wav squelches) — keep; revisit only
  if the rating questionnaire flags audio gore.
- Damage screen flash (red cshift) — brief abstract flash, keep.
- HUD pain faces, map textures with skulls, zombie pain gibs — out of scope.

## 5. Files touched (estimate ~200 lines total)
| File | Change |
|---|---|
| `src/server/modepresets.luau` | +`"moderate"` key; set `false` on dev/demo presets if default-ON chosen |
| `src/server/avatarrigs.luau` | mirror `moderate` → QuakeClientFS (live), next to roblox_avatars |
| `src/client/qwclient.luau` | `moderateOn()`, gib-name check → `white` arg, TE color remap (656/658), fade table for alias corpses/gibs, `psys.moderate` per frame |
| `src/client/init.client.luau` | same for NQ: white arg at updateAlias (~2024), svc_particle 73/225 remap (~1216), fade table |
| `src/client/render/entrender.luau` | `white` skin override in create/updateAlias skin-swap; `setFade(re, alpha)` |
| `src/client/render/particlesim.luau` | `sys.moderate`; white (254) for trail types 2/4 |
| `src/client/render/avatarlayer.luau` | `deadSince` timers, origin-jump reset, fade→hide while still returning true |
| `src/client/render/avatarrender.luau` | `setFade(ae, alpha)` with per-part base transparency |

## 5b. What gibbing an avatar does TODAY (code trace, unverified live)

Traced 2026-07-06 — current behavior appears to already match Quake; no
lingering avatar corpse alongside gibs:
- On gib death, QuakeC `GibPlayer → ThrowHead` swaps the player edict's
  model to `progs/h_player.mdl`. The QW avatar path is gated on
  `ps.modelindex == cl.playerindex` (qwclient.luau:871), so the rig is NOT
  updated that frame, the slot never enters `seenAvatars`, and
  `avatarLayer.hideExcept(seenAvatars)` (qwclient.luau:953) hides the rig
  immediately. The head renders via the alias fallback
  (`linkEnt("p{num}", ...)`, qwclient.luau:899). NQ path likewise: the
  `model == "progs/player.mdl"` check fails → `avatarLayer.hide(num)`
  (init.client.luau:2016).
- Bodyque after a gib death copies the *head* model, so the corpse-rig
  detection (`es.modelindex == cl.playerindex`, qwclient.luau:762) correctly
  doesn't fire — the bodyque entry renders as a head mdl, not a standing rig.
  (Vanilla quirk faithfully reproduced: you can end up with two heads — the
  thrown one and the bodyque copy.)
- What DOES persist forever after a gib is vanilla behavior: the head(s) +
  3 gib chunks never despawn. The moderate-mode fade in §3 covers all of
  them via `isGibModel`.
- Verify live when resuming (test plan step 9): rocket-suicide with
  `RQDBG_QWSelfAvatar` on, confirm the rig vanishes at the gib moment on
  both QW and NQ.

## 6. Test plan (when resumed)
1. `lune run tools/mode ctf`, start server + 2 Studio clients.
2. Flip `moderate` on QuakeAssets live mid-match — gibs turn white and
   trails whiten on the very next kill, no reconnect.
3. Rocket-kill a player: white chunks + white trails, no red anywhere
   (impact + trail + lightning-discharge-in-water checks).
4. Corpse (non-gib death): body lies 8 s, fades over 2 s, gone; respawned
   player's rig arrives fully opaque (fade-state reset check).
5. Bodyque recycle: die 5+ times in place — each new corpse restarts its own
   timer (origin-jump reset check).
6. Avatars OFF (`roblox_avatars = false`): repeat 3–4 on the player.mdl path.
7. NQ path (`lune run tools/mode campaign` or nq-dm): shoot a zombie/ogre —
   white gibs, white trails, monster heads white, corpses fade.
8. Flip moderate OFF live: next gibs are red again, real skins re-apply
   (skin-key un-white swap check).
9. Gib an avatar (rocket suicide, `RQDBG_QWSelfAvatar` on): rig disappears
   at the gib moment (no standing corpse), chunk-substituted heads render
   (never head-shaped in moderate), all chunks fade after settling. Repeat
   on the NQ boot.
