# Fidelity audit — divergences from WinQuake

The P0 goal is a port that is 100% faithful to WinQuake 1.09 before any
Roblox-native features. This is the canonical list of known divergences,
kept honest: every item is either **verified**, **fixed**, **open**, or a
**platform substitution** that cannot be direct.

## Verified against compiled C (mechanical ground truth)

- Hull collision (`world.c`): bit-exact vs `tools/trace_truth.c` (1503 checks)
- Player movement chain (`sv_user.c`/`sv_phys.c`): max error 0.000184 units
  over 300 scripted ticks vs `tools/move_truth.c`
- QuakeC VM: executes the shipped `progs.dat` (CRC 5927), all 150 VM checks
- Protocol 15 message layer: byte-exact reader/writer round-trips
- File formats: PAK/BSP29/WAD2/MDL/SPR/LMP parsed against real data

## Fixed during the audit

- **Per-texel lightmaps + dynamic lights** (the former #1/#2/#3 opens):
  lightatlas.luau ports R_BuildLightMap / R_AddDynamicLights /
  R_MarkLights into EditableImage pages; black alpha-overlay meshes
  multiply over fullbright base textures (epsilon part transparency
  forces per-texel alpha blending). cl_dlights ported: muzzle flashes,
  bright/dim entity lights, rocket glow, explosion flash, with entity
  lighting picking up dlight falloff like R_AliasSetupLighting.
  Palette 224-255 fullbrights reassert via an unlit cutout pass.
- Loading plaque (SCR_BeginLoadingPlaque: notify/centerprint clear, plaque
  holds until the first rendered frame), pause plaque (SCR_DrawPause)
- Console slide animation (scr_conspeed 300)
- Lightning beams: CL_ParseBeam/CL_UpdateTEnts ported — bolt/bolt2/bolt3
  model chains, one segment per 30 units, random roll, player-tracked
  start position, 0.2s lifetime (pooled render entities)
- Solo TAB scoreboard (Sbar_SoloScoreboard: monsters/secrets/time/level
  over the status row, shown when dead too; scorebar.lmp backdrop swap
  still pending)
- Chase cam (chase.c verbatim: back 100/up 16, traced look-point pitch,
  no camera wall clip — authentic quirk; chase_active console cvar)
- EF_BRIGHTFIELD entity particles (R_EntityParticles with the real
  anorms.h table)
- Atlas page writes batched through CPU mirrors (one upload per page at
  load; region rewrites stream afterwards) — map-load stall fixed
- Static entity framegroup animation (torch flames): alias statics re-pose
  every frame like R_DrawEntitiesOnList, so flame.mdl/flame2.mdl group
  frames advance by time (user-reported frozen torches)
- Intermission overlays: Sbar_IntermissionOverlay (complete.lmp/inter.lmp,
  big-digit time/secrets/monsters at the exact C coordinates),
  Sbar_DeathmatchOverlay rankings (ranking.lmp, shirt/pants colour bars,
  frags, self marker char 12), Sbar_FinaleOverlay, and TAB +showscores
  (also console commands +showscores/-showscores)

- Impact sounds (`cl_tent.c R_ParseTEnt`): TE explosions play r_exp3,
  spikes play tink1/ric1-3, wiz/knight hits — the QC r_exp3 call is
  commented out in shipped progs; these are client-side (fd28443)
- Rocket/grenade/gib/tracer/voor particle trails (`R_RocketTrail` +
  `CL_RelinkEntities` model-flag dispatch)
- Leaf ambient sounds (`S_UpdateAmbientSounds`): water1/wind2 loops driven
  by the view leaf's ambient levels, ambient_level 0.3 / ambient_fade 100
- Powerup cshift priority now matches `V_CalcPowerupCshift` (quad > suit >
  ring > pent)
- View weapon light floor 24 (`R_DrawViewModel`)
- Centerprints/notify in conchars with faithful metrics (`SCR_DrawCenterString`,
  `Con_DrawNotify`), finale typewriter at scr_printspeed
- Channel override semantics on entity sounds (`S_StartSound` allocator)
- Console: semicolon splitting (`Cbuf_Execute`), lowercase typing

## Open — ordered by visibility

3. **Underwater screen warp** (`D_WarpScreen`) — likely platform-limited
   (no screen-space shader access); best-effort approximation TBD.
4. **Host timing**: WinQuake caps synchronized host frames at 72fps; we
   tick on Heartbeat (~60Hz). Audit feel + consider fixed-timestep.
5. **config.cfg / quake.rc execution**: `bind`/`unbind`/`alias`, cvar
   persistence, autoexec. None implemented; keys are hardcoded defaults.
8. **Demo playback/recording** (`cl_demo.c`).
9. **Save/load** (`host_cmd.c` savegames).

## Platform substitutions (cannot be direct ports)

- **Network transport**: sockets → RemoteEvents. The svc/clc byte stream on
  top is exact; delivery/ordering semantics differ (reliable channel is
  genuinely reliable; unreliable drops >~900B payloads, worked around).
- **Audio output**: no PCM access. The software mixer (`snd_mix.c`) is
  replaced by a soundbank asset + PlaybackRegion slices; spatialization is
  Roblox's rolloff approximating `SND_Spatialize`'s linear curve.
- **Raw input**: Win32 message pump → UserInputService. Escape is reserved
  by Roblox (menu moved to M); Studio eats I/O in play-test.
- **Alias-model fullbright pixels**: per-pixel colormap fullbrights can't
  be expressed on a tinted MeshPart; mostly-fullbright skins (flames,
  candles) render unlit as an approximation, mixed skins tint normally.
- **Rendering backend**: software rasterizer → EditableMesh geometry (a
  GLQuake-style approach). The surface-cache work above recovers the
  software renderer's lighting semantics; the rasterizer itself (span
  drawing, mip selection, 8-bit dither) is not reproduced.
- **CD music**: tracks were never in the paks; absent. LibreQuake ships
  music files that could be banked later.

## Deliberate default changes (one-line divergences, revisit at ship)

- `crosshair` defaults 1 (WinQuake: 0)
- Always-mouselook (WinQuake default: +mlook off)
- Notify text sits below the Roblox topbar inset rather than y=0
- TAB also toggles Roblox's own player list (CoreGui overlays kept by
  request), so both UIs appear on TAB
