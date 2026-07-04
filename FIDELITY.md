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

1. **Per-texel lightmaps** (`d_surf.c` surface cache). Vertex lighting drags
   whole faces dark when a vertex sits in shadow. Plan: bake
   texture × lightmap into EditableImage surface atlases exactly like the
   software surface cache, with lightstyle re-bake.
2. **Per-pixel fullbrights** (palette 224–255). The software colormap keeps
   these bright regardless of light; vertex multiply darkens them (torch
   flames, runes, lava baked into wall textures). Solved naturally by the
   surface-cache bake; interim overlay pass possible.
3. **Dynamic lights** (`cl_dlight.c` / `R_MarkLights`): muzzle flash,
   explosion flash, quad/pent glow, rocket glow. Depends on the surface
   cache for faithful surface lighting; entity-light approximation earlier.
4. **Loading flow** (`SCR_BeginLoadingPlaque`): console over load,
   gfx/loading.lmp plaque, sound stop, then reveal.
5. **Lightning beams**: real bolt models (`progs/bolt*.mdl`) segmented every
   30 units with random roll (`CL_UpdateTEnts`); currently placeholder neon
   rods.
6. **Intermission / finale overlays**: rankings screen, finale text plaque
   (`Sbar_IntermissionOverlay`, `SCR_CheckDrawCenterString`).
7. **Pause plaque** (`SCR_DrawPause`).
8. **Underwater screen warp** (`D_WarpScreen`).
9. **Console slide animation** (`scr_conspeed`).
10. **Host timing**: WinQuake caps synchronized host frames at 72fps; we
    tick on Heartbeat (~60Hz). Audit feel + consider fixed-timestep.
11. **config.cfg / quake.rc execution**: `bind`/`unbind`/`alias`, cvar
    persistence, autoexec. None implemented; keys are hardcoded defaults.
12. **Chase cam** (`chase_active`).
13. **EF_BRIGHTFIELD entity particles** (`R_EntityParticles`): unused by
    id1 QC; port for completeness with the real anorms table.
14. **Demo playback/recording** (`cl_demo.c`).
15. **Save/load** (`host_cmd.c` savegames).

## Platform substitutions (cannot be direct ports)

- **Network transport**: sockets → RemoteEvents. The svc/clc byte stream on
  top is exact; delivery/ordering semantics differ (reliable channel is
  genuinely reliable; unreliable drops >~900B payloads, worked around).
- **Audio output**: no PCM access. The software mixer (`snd_mix.c`) is
  replaced by a soundbank asset + PlaybackRegion slices; spatialization is
  Roblox's rolloff approximating `SND_Spatialize`'s linear curve.
- **Raw input**: Win32 message pump → UserInputService. Escape is reserved
  by Roblox (menu moved to M); Studio eats I/O in play-test.
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
