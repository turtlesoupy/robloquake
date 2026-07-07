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
- QW view/refdef composition (`view.c`): 400 scripted frames vs the
  verbatim C in `tools/view_truth.c` (bob, lean, kicks, punch order,
  gib/dead heights, stair glide, spectator gate) — worst component
  error 6.1e-5, mutation-tested
- File formats: PAK/BSP29/WAD2/MDL/SPR/LMP parsed against real data

## Fixed during the audit

- **View/feel wiring batch (2026-07-07 call-site audit)**: QW gun bob
  (raw speed push with no sine — the gun extended and stuck; now
  oscillating calcBobQW with QW's on-ground bobtime + airborne hold);
  NQ powerup screen-tint and HUD-face item bits rotated
  (quad↔suit↔invuln — the test asserted the same wrong constants);
  QW gib view height (PF_GIB outranks PF_DEAD: +8, was -16);
  QW gun angles (computed pre-punchangle, roll forced 0 — the gun no
  longer pitches with kicks or rolls with lean); QW spectator bob gate;
  bob/kick/punch now apply while dead; 1/16 node-line nudge; NQ pause
  gate (`if (!cl.paused) V_CalcRefdef()`); QW muzzleflash dlight keyed
  positive like C. Full record:
  [docs/coverage/delta-triage-2026-07-07.md](docs/coverage/delta-triage-2026-07-07.md).

- **Demo playback + recording** (`cl_demo.c`): playdemo parses the exact
  .dem block format (cd-track line, then length/viewangles/payload
  blocks) and feeds the shipped attract demos through the full parse
  pipeline with CL_GetMessage's mtime pacing in a detached no-transmit
  mode — demo1.dem plays e1m3 end to end. record/stop capture inbound
  messages with viewangles into the same format (in-memory, replayable
  with playdemo). Demo maps' assets publish on demand via a tiny
  rq_need client->server file request. Fixed along the way: retained
  EditableMeshes now Destroy() on map teardown (the editable budget
  starved consecutive map builds — latent changelevel bug), atlas pages
  destroy on reset, and demo feeding guards against re-entry while a
  world build yields.

- **Save/load** (`Host_Savegame_f`/`Host_Loadgame_f`): exact .sav text
  format (version 5, comment with kills, 16 spawn parms, skill, map,
  time, 64 lightstyles, ED_WriteGlobals, ED_Write per edict with
  PR_UglyValueString round-tripping function/field/entity values).
  Deferred load respawns the server and reconnects clients; loadgame
  pauses until begin. Saves live in memory + ServerStorage.QuakeSaves
  (place-file persistence; DataStore later for published permanence).
  The default.cfg F6/F9 quicksave/quickload binds work end to end.
  Offline round-trip test: tests/test_savegame.luau (13 checks).

- **keys.c / cmd.c**: full bind system — Key_Event with quake key names
  (letters, arrows, modifiers, F-keys, mouse1-3), keyups fire the
  -command, bind/unbind/unbindall/alias/echo/exec/wait, Cbuf semantics
  with quote-protected semicolons and frame-deferred wait. The shipped
  default.cfg execs at boot (authentic 1996 binds: arrows/a/z), then a
  built-in autoexec layers the modern WASD expectations, then
  autoexec.cfg from the pak if present. CL_AdjustAngles keyboard turning
  (+left/+right/+lookup/+lookdown at cl_yawspeed/cl_pitchspeed with
  cl_anglespeedkey), +strafe/+klook/+speed semantics in CL_BaseMove,
  centerview, fov (horizontal-to-vertical for the aspect; zoom aliases
  work). Verified: W→forwardmove 200 over the wire, F11 zoom chain.

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
  over the status row, shown when dead too, scorebar.lmp backdrop)
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

Repopulated 2026-07-07 by the buried-delta triage
([docs/coverage/delta-triage-2026-07-07.md](docs/coverage/delta-triage-2026-07-07.md)):
every "Deltas: …" note inside a VERIFIED coverage row was classified; the
genuine still-open divergences now live here instead of buried prose. The
gun-bob bug (VERIFIED row note "gun bob simplified to forward push" hid a
missing oscillation for two days) is the precedent; fixed 2026-07-07.

1. **Underwater screen warp** (`D_WarpScreen`) — likely platform-limited
   (no screen-space shader access); best-effort approximation (camera
   FOV/roll oscillation) TBD. Highest-visibility absence in the port.
2. **Alias-model directional shading** (`r_alias.c` anorm dot table) —
   both boots light models with one scalar (entrender.luau setLight);
   C shades per-vertex via `r_avertexnormal_dots`, giving the bright/dark
   gradient across a model. Candidate: per-vertex colors on EditableMesh.
3. **NQ view-weapon damped lag** (`CalcGunAngle` angledelta smoothing) —
   gun locks rigidly to view angles; C lags yaw/pitch. Same feel class as
   the fixed bob bug. (QW boot exact by identity — its C lag terms are
   provably zero.) Existing SUBSTITUTED row w/ playtest expiry.
4. **Server RNG fixed seed** — `svr.randSeed = 12345` unconditionally
   (sv.luau:169): every production boot replays the identical
   monster-dice/nail-spread stream. One-line fix (reseed outside tests).
5. **PF_objerror aborts the QC program** (pr_cmds.luau:156-163) — C frees
   the offending edict and *continues*; the port unwinds like PF_error, so
   a map with one "walkmonster in wall" loses the whole spawn chain.
6. **soundLog/printLog unbounded growth** (qwsv.luau) — never trimmed;
   live QW server leaks memory for the session. Ship concern.
7. **Player entity angles not forced to view** (NQ, view.c:883-885) —
   port never writes ent yaw/pitch from viewangles; visible as wrong
   self-model facing in chase cam / avatars mode.
8. **NQ demo playback in Studio: frozen view entity** — journaled OPEN in
   nq-client.md (init.client demo glue); offline reader passes.
9. **PF_localcmd drops everything but changelevel/restart** (both boots)
   — silent no-op for other commands; mod progs commonly localcmd cvar
   sets. Mod-compat gap.
10. **Q_atof accepts exponents** (com.luau:73-79) — `tonumber` first, so
    "1e5" parses as 100000 where C stops at 'e' (returns 1); reaches
    cvar/QC parsing. C char constants (`'a'`) also unsupported (dead in
    id1 data).
11. **Cvar_Command is a fixed branch list** (NQ) — unlisted cvar names
    fall through to the server instead of get/set locally like C's
    registry walk. Console UX.
12. **Unknown user command: silent** (QW server, qwsv.luau:1504) — dprints
    where C Con_Printf's "Bad user command" back to the client.
13. **Console UX cluster** (NQ+QW): no pgup/pgdn scrollback, no
    horizontal scroll of long input lines, client-side `echo` skips the
    notify lines, unbound-key query prints `"x" = ""` vs C's
    `"x" is not bound`. (Tab completion EXISTS — console.luau:201.)
14. **Cosmetic/minor cluster**: beam angles kept float vs C int-truncation
    (chunky LG rotation); conback slides instead of cropping; CHAN_AUTO
    never steals a channel when full (dense firefights stack/drop sounds
    differently); skingroup + sprite-group intervals untimed; sky drift
    horizontal-only vs C's diagonal; keyboard +lookup stops pitch drift
    where C lets them fight; two keys bound to one +command release early
    (kbutton_t down[2] untracked); CL_EntityNum lacks the MAX_EDICTS
    Host_Error cap; QW held buttons not cleared on disconnect.

## Platform substitutions (cannot be direct ports)

- **Network transport**: sockets → RemoteEvents. The svc/clc byte stream on
  top is exact, and as of 2026-07-07 the QW boot runs the REAL netchan.c
  protocol (bit-31 reliable flag/ack, reliable_buf copy-out,
  retransmit-on-evidence, stale/duplicate discard — restored from the
  earlier "netchan-lite") so datagrams ride the UnreliableRemoteEvent like
  UDP; reliable RemoteEvent batching/head-of-line blocking was the root
  cause of chunky remote motion on real networks. Transport-forced
  deviations from netchan.c, each commented at the site: sequences start
  at 1 (C sacrifices each side's first packet to the stale guard and heals
  by retransmit; we cannot, because reliable-bearing packets are sent on
  BOTH remotes — the guaranteed copy is the delivery guarantee, the
  duplicate must always discard); packets >~850B go reliable-remote-only
  (unreliable payload cap); the server withholds pure-keepalive replies
  while a reliable is in flight (a keepalive's higher sequence racing the
  reliable-only signon packet across the two channels could starve the
  handshake — C's single socket has no such race). Client cmd packets flow
  in every state past disconnected, exactly as C's CL_SendCmd (an earlier
  port deviation gated them during the handshake); sv_user.c's
  reply-sequence alignment is ported (its omission skewed the frames ring
  permanently under any upstream loss).
- **Remote-player rendering**: 1996 QW extrapolates other players by
  replaying their last usercmd for half the elapsed move and snapping on
  each packet (CL_LinkPlayers + CL_SetUpPlayerPrediction — still ported,
  still driving the spectator cam and solid-player physents). For the
  RENDERED pose, big Roblox rigs at 60Hz make the snap-and-correct pattern
  read as warping, so remote players draw on a short delayed interpolated
  timeline instead (qwplerp — the ezQuake/FTE-style evolution). Segments
  are timed by displacement against the wire velocity (dt = dP·V̄/|V̄|²)
  rather than wire state_time: the reconstructed timestamps mix the
  viewer's cmd send clock with the server's msec byte, so viewer upstream
  jitter and sv.time frame quantization put ±1 frame of noise on them, and
  the two clients' unsynchronized cmd clocks alias (some replies duplicate
  the mover's position, some span two moves). Sim, prediction, camera and
  wire protocol are untouched; workspace attribute RQDBG_QWNoLerp reverts
  to the authentic extrapolate-and-snap live.
- **PL (packet loss) column**: C's CL_CalcNet counts still-in-flight cmds
  as dropped, diluted across a 256-slot ring (~1% on a clean LAN); over
  this port's 64-frame ring that artifact read 4% on a lossless link, so
  PL here counts only cmds the server's acks have passed by — true loss; a
  clean link reads 0.
- **Audio output**: no PCM access. The software mixer (`snd_mix.c`) is
  replaced by a soundbank asset + PlaybackRegion slices; spatialization is
  Roblox's rolloff approximating `SND_Spatialize`'s linear curve.
- **Host timing**: WinQuake runs synchronized host frames up to 72fps;
  Roblox Heartbeat ceilings at ~60Hz. The simulation is dt-driven and
  verified against compiled C at arbitrary dt, so the divergence is tick
  granularity, not physics behaviour.
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
- **config.cfg persistence**: no writable filesystem; binds/cvars reset
  each session (Host_WriteConfiguration cannot exist). A DataStore-backed
  substitute is possible later.

## Deliberate default changes (one-line divergences, revisit at ship)

- `crosshair` defaults 1 (WinQuake: 0)
- Always-mouselook (WinQuake default: +mlook off)
- Notify text sits below the Roblox topbar inset rather than y=0
- TAB also toggles Roblox's own player list (CoreGui overlays kept by
  request), so both UIs appear on TAB
