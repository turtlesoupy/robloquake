# Coverage manifest

Function-by-function accounting of the original Quake source against this
port. Every row was produced by reading the C and the Luau side by side —
no from-memory claims. Statuses:

- **VERIFIED** — an offline test or compiled-C ground-truth harness proves
  the behavior (evidence cited per row), or a recorded screenshot
  comparison confirms it. This is the only status that counts as done.
- **PENDING** — ported and structurally equivalent on reading, but no test
  or visual proof yet.
- **UNIMPLEMENTED** — no port counterpart exists.
- **SUBSTITUTED** — intentionally replaced by a platform mechanism; the row
  states what replaces it and why the platform requires it. A substitution
  without a stated justification is a defect.

Each manifest ends with a list of port-side additions that have no C
counterpart, each with its justification.

| Manifest | Rows | Verified | Pending | Unimplemented | Substituted | N/A |
|---|---|---|---|---|---|---|
| [nq-server.md](nq-server.md) — WinQuake sim/server/shared | 455 | 223 | 58 | 61 | 111 | 2 |
| [nq-client.md](nq-client.md) — WinQuake client/presentation | 267 | 22 | 114 | 62 | 66 | 3 |
| [qw-server.md](qw-server.md) — QuakeWorld server | 240 | 135 | 39 | 21 | 42 | 3 |
| [qw-client.md](qw-client.md) — QuakeWorld client | 230 | 52 | 69 | 60 | 49 | 0 |
| **Total** | **1192** | **432** | **280** | **204** | **268** | **8** |

Counts as of 2026-07-04 after the evidence reset (VERIFIED = re-runnable
evidence only) and the first burn-down passes; regenerate with
`grep -oE '\| (VERIFIED|PENDING|UNIMPLEMENTED|SUBSTITUTED|N/A) ' docs/coverage/*.md | sort | uniq -c`.

Notes on reading the numbers: 13 of the nq-server UNIMPLEMENTED rows are
dead code in the original build (QUAKE2/#if 0/PF_Fixme slots); the
SUBSTITUTED columns are dominated by the software rasterizer (d_*.c,
r_* span/edge internals, gl_*), UDP/WinSock networking, and Win32/DOS
platform files, replaced wholesale by the Roblox renderer, remotes, and
runtime.

Maintenance rule: when a PENDING row gains a test or screenshot proof,
move it to VERIFIED and cite the evidence. When new port code is written,
it enters here in the same commit.

## Scenarios

Interaction coverage the per-function grid cannot express (proven by the
vrect/view-weapon saga: every function was individually right and the
composite was wrong). These rows hold the same evidence bar as function
rows.

| # | Scenario | Status | Evidence | How to verify |
|---|---|---|---|---|
| S1 | QW two-client loopback: connect, duel, frag on BOTH scoreboards, death/respawn, changelevel inventory carry | VERIFIED | tests/test_scenario_qw.luau (25 checks): shotgun duel over the wire, frag rebroadcast to both clients, DEAD_DEAD→respawn at full health, SetChangeParms carry incl. the authentic shells-floor-25 | `lune run tests/test_scenario_qw.luau` |
| S2 | NQ campaign loop: spawn, pickup, damage, changelevel carry, save/load round-trip | VERIFIED | tests/test_scenario_nq.luau (30 checks): shells picked up by really walking over the box (SV_TouchLinks), a live grunt shoots the player (svc_damage pain flash on the client), earned inventory + damaged health carry to e1m2, then a save/load round-trip restores health/shells/origin/time and the game keeps running | `lune run tests/test_scenario_nq.luau` |
| S3 | NQ visual anchor: scripted fixed map + vantage screenshot committed under evidence/ | VERIFIED | [evidence/nq-e1m1-start.jpg](evidence/nq-e1m1-start.jpg) + [.txt capture context](evidence/nq-e1m1-start.txt): e1m1 start hall at the fixed anchor (480,-352,88 yaw 90, deathmatch 0, viewsize 100) — textured/lightmapped world, centered shotgun through the ViewportFrame projection, full sbar with live stats. | Stage via tools/verify_visual_anchor.luau, capture, diff against evidence/nq-e1m1-start.jpg |
| S4 | QW visual anchor: same vantage discipline, QW engine | VERIFIED | [evidence/qw-dm3-stairs.jpg](evidence/qw-dm3-stairs.jpg) + [.txt capture context](evidence/qw-dm3-stairs.txt): the QW boot at the fixed dm3 stair anchor (-64,470,44 yaw 90) — the truth-course risers visible, QW sbar via hudlib adapter, view weapon over the strip. | Stage via tools/verify_visual_anchor.luau, capture, diff against evidence/qw-dm3-stairs.jpg |

## Changelog

### 2026-07-04 (NQ console/keys/cmd evidence pass)
- Three committed captures drive 22 rows: nq-console-open.jpg (console
  + the full keys.c/cmd.c battery through the checked-in RQDBG_Console
  harness — echo/alias/quote-tokenize/bind/unbind/exec visible in the
  scrollback; boot-time default.cfg exec at the top), nq-pause-plaque.jpg
  (SCR_DrawPause + the console mid-slide), nq-solo-scoreboard.jpg
  (Sbar_SoloScoreboard exact C fields via +showscores). Formatting
  delta recorded: unbound key query prints "x" = "" vs C's not-bound
  message. Also corrected qw-dm3-packetents.jpg (the transcript stores
  each capture twice; the first extraction committed duplicate bytes).

### 2026-07-04 (QW client visual evidence pass)
- qw-client DEMOTED cleared. CL_LinkPacketEntities/CL_EmitEntities via
  evidence/qw-dm3-packetents.jpg (a wire packet entity rendered at a
  deterministic vantage); CL_MuzzleFlash + CL_ParseTEnt via
  evidence/qw-fire-muzzleflash.jpg (flash + TE_GUNSHOT puff during a
  sustained forced-fire burst, shells 25->2). DropPunchAngle earned by
  faithfulness-by-absence (tools/verify_punchangle_qw.luau): zero pitch
  deflection over 55 samples matches the C order — DropPunchAngle
  clamps the negative svc_smallkick before V_CalcRefdef reads it, so
  gun kicks genuinely do not display in authentic QuakeWorld.

### 2026-07-04 (playtest: QW sky black artifacts)
- User playtest report: sky "busted with weird black artifacts" in the
  QW boot. Root cause: qwclient.luau never consumed
  worldmesh.takeTextureAnims(), so the 10Hz writers (sky composite
  scroll, water turbulence, +wall frame swaps) never ran under QW — the
  raw palettized sky texture rendered its masked front half as opaque
  black. Ported the NQ pump into the QW heartbeat (same 10Hz tick as
  lightstyles, cleared on changelevel). Verified live at the dm3 atrium
  dome: two-layer composite scrolls correctly
  (evidence/qw-dm3-sky.jpg).

### 2026-07-04 (S3/S4 anchors committed)
- Both visual anchor screenshots recovered from the session transcript
  (the MCP returns captures inline; the transcript stores the bytes —
  user's insight) and committed under docs/coverage/evidence/ with full
  capture context. S3 and S4 VERIFIED — all four scenario rows are now
  done. id1 note: this repo has no remote; the anchors must be
  re-captured on LibreQuake before anything goes public.

### 2026-07-04 (Studio verify pass 1)
- Checked-in Studio verification tooling: tools/verify_visual_anchor.luau
  (deterministic S3/S4 anchor staging through the SVDBG_SetOrigin +
  RQ_Force* harness hooks) and tools/verify_stairsmooth_qw.luau (stair
  smoothing measured at heartbeat rate). The QW boot gained the same
  SVDBG_SetOrigin debug teleport the NQ boot has (stuck-probing), and a
  QW_OnGround diagnostic attribute.
- Stair smoothing verified live on the dm3 staircase: camera max rise
  10.04 units/frame vs 14.6-unit player risers over 181 samples — the
  oldz glide + 12-cap behave C-shaped. Both S3/S4 anchors stage and
  render correctly (MCP capture confirmed); committing the .png evidence
  awaits a pixel-export path (Screen Recording grant or manual capture).

### 2026-07-04 (nq-server sweep 2: host commands, cvars, SZ overflow fix)
- test_server gains the host_cmd.c battery (god/notarget/noclip/fly/
  give/say/color/pause/map) + the COM_CheckRegistered probe; test_com
  gains the cvar.c battery; test_msg gains SZ_GetSpace overflow checks.
- Bug found+fixed: msg.clear reset the overflowed flag, but C SZ_Clear
  only zeroes cursize — SZ_GetSpace sets the flag then clears, so every
  overflow was silently swallowed and the sv.luau/qwsv overflow checks
  were dead code. Flag now survives; suite green.
- 20 nq-server rows earned (SZ_GetSpace, CheckRegistered, cvar family,
  StartParticle, CheckBottom/movestep via the builtin battery, the
  Host_* command layer, BroadcastPrintf, ClientCommands).

### 2026-07-04 (qw-server user commands + physics battery)
- test_qw_loopback (+6 checks, 43): say broadcasts at PRINT_CHAT, pause
  toggles both ways, setinfo updates server-side userinfo, pings
  answers with svc_updateping. test_qwsv (+7 checks, 33): spike wall
  impact removes it (SV_Impact), strafing leans the player (server
  V_CalcRoll — roll reads pre-move velocity, so strafe twice), door
  use drives a full SV_Push travel/return cycle, toss battery with the
  sv_maxvelocity clamp, svc_nails carries an in-flight spike.
  test_qwbuiltins (+1, 55): WriteDest MSG_ONE lands on the netchan
  reliable stream. 23 qw-server rows earned.

### 2026-07-04 (NQ builtins battery)
- tests/test_nqbuiltins.luau (53 checks): the NQ twin of the QW
  register-level battery, plus NQ-specific coverage — wire-writing
  builtins asserted byte-level in the client reliable stream/datagram
  (bprint/sprint/centerprint/stuffcmd/particle/Write*), traceline glue
  vs a direct world.move, monster builtins on a live grunt
  (checkbottom/changeyaw exact 20-deg step/walkmove), droptofloor,
  makestatic signon growth, aim no-target path, vectoangles vertical
  special case. 44 nq-server pr_cmds rows earned; PF_break/PF_Fixme
  ruled N/A (debugger traps).

### 2026-07-04 (nq-server PENDING sweep 1)
- tests/test_com.luau: Q_atoi/Q_atof/anglemod vs transcribed C
  (documented deltas: Luau tonumber accepts exponents where Q_atof
  stops at "e"; C char constants unsupported). test_server grows the
  grunt box-hull clip, a full door pusher cycle (travel + return home),
  and a lobbed-projectile toss arc coming to rest. 20 nq-server PENDING
  rows earned: com/math, Mod_* loaders, the NQ world.c twins of the
  qwtrace battery, SV_TouchLinks via the scenario pickup, PR_RunError
  via the shared vm, and the pusher/toss physics family.

### 2026-07-04 (particle effect batteries)
- test_particles2 extended (+7 checks, 10250 total): R_EntityParticles
  (162 anorms, 64±16 shell), R_TeleportSplash (896-particle grid,
  color/die/speed windows), R_RocketTrail type 0 (ramp3 colors, the
  authentic start+=normalized-vec advance quirk). Divergence found and
  fixed: teleportSplash skipped the vel write for the zero-dir center
  particle, leaking stale pool velocity (C VectorNormalize leaves zero
  vectors zero and always scales into vel) — regression check pollutes
  the pool first. Rows re-earned in both client manifests.

### 2026-07-04 (qw-client offline rows + CalcFov truth)
- New tests/test_qcoords.luau: CalcFov against a transcribed screen.c
  formula (5 cases + hand-derived anchors: fov 90 = 73.74 vertical at
  4:3, 58.72 at 16:9) and the vrect derivation (fov_y at the reduced
  height, gun rotation scaling with viewsize). CalcFov VERIFIED in both
  client manifests; SCR_CalcRefdef rows note the math half is now
  offline-proven and only the S3/S4 anchor screenshots remain.
- qw-client DEMOTED rows with existing named checks re-cited
  (CL_ParseClientdata via the loopback prediction/validsequence checks,
  CL_ParseDelta + MSG_WriteDeltaUsercmd via test_qwents, Angle16 via
  test_msg + test_qwents). Remaining qw-client DEMOTED (4) are
  Studio-visual: CL_LinkPacketEntities/CL_EmitEntities/V_CalcRefdef/
  DropPunchAngle — queued behind the S3/S4 capture pass.

### 2026-07-04 (nq-server DEMOTED cleared)
- New tests/test_msg.luau: byte-exact wire codec battery against the C
  encodings (little-endian, (int)-cast truncation for coords/angles,
  360-wrap, NUL strings, -1+badread underflow) — re-earns the MSG_*/SZ_*
  rows. test_server gains the NQ areanode battery (door attribution,
  unlink/relink bit-equal, PF_setmodel bounds), an SV_CheckStuck
  restore-from-solid check, and the precache_*2 alias identity check.
  Movement-chain rows (ClipVelocity through SV_ClientThink) re-cite
  tools/move_truth.c + test_movement, the compiled-C chain they were
  originally earned against. nq-server manifest now has zero DEMOTED
  rows.

### 2026-07-04 (qw-server DEMOTED cleared)
- Final 25 qw-server DEMOTED rows re-earned: the shared VM rows against
  test_vm's named checks (alloc/free/parse/exec/string battery — one
  implementation serves both engines), model registry vs test_models +
  the setmodel "*1" bounds check, Mod_PointInLeaf vs test_bsp + the PHS
  guncock, netchan setup vs the loopback sequence checks, FatPVS vs the
  packet-entity/PHS checks, the four pmove trace internals vs the
  two-course ground truth, and SV_RunEntity via a new test_qwsv check
  (nailgun spike flies through the movetype dispatch; firing backward —
  RunNewmis flies the missile immediately, so a wall-facing shot dies
  in the same tick it spawns). PF_Fixme ruled N/A (dead-slot trap).
  qw-server manifest now has zero DEMOTED rows.

### 2026-07-04 (qw builtins re-earned at the register level)
- New tests/test_qwbuiltins.luau (53 checks): PF_* builtins driven
  exactly as PR_ExecuteProgram drives them — parameters into OFS_PARM*,
  results from OFS_RETURN — with expectations taken from the C source
  (printf %5.1f half-even, rint half-away-from-zero, vectoyaw int
  truncation, findradius SOLID_NOT skip, ss_loading precache gate
  preceding dedup, WriteAngle byte quantization, WriteCoord 1/8 units).
  ~28 qw-server pr_cmds rows re-earned; PF_break and the debugger stubs
  ruled N/A (debugger traps, platform-meaningless).
- Bug found+fixed while re-earning: PF_centerprint wrote to
  client.message, a buffer nothing flushes — centerprints never reached
  QW clients. Now on the netchan reliable stream (ClientReliableWrite
  equivalent) and wire-proven in test_qw_loopback, alongside a new
  runtime PF_lightstyle broadcast check.

### 2026-07-04 (qwworld re-earned at C truth)
- New tests/test_qwtrace.luau: the compiled-C trace fixture
  (tools/trace_truth.c) now replays through the QW world module itself
  — 200 point-contents x 3 hulls and every trace segment match the C —
  plus a live areanode battery on a booted qwprogs e1m1 (door hit
  attribution, unlink/relink bit-equal fraction, hull selection by
  size, SOLID_SLIDEBOX player box with a shooter passedict,
  testEntityPosition free/solid). 14 qw-server world.c rows re-earned
  from DEMOTED/PENDING: InitBoxHull, HullForEntity, CreateAreaNode,
  ClearWorld, UnlinkEdict, LinkEdict, HullPointContents, PointContents,
  RecursiveHullCheck, ClipMoveToEntity, ClipToLinks, MoveBounds, Move,
  TestEntityPosition. Documented the authentic owner==0 passedict quirk.

### 2026-07-04 (scenario S2)
- NQ campaign loop verified offline end to end (test_scenario_nq, 30
  checks): real walked-over pickup, real monster damage with the pain
  flash on the client, changelevel carry of the earned inventory and
  damaged health, save/load round-trip restoring health/shells/origin/
  time. Staging note for future scenario tests: teleporting the player
  must probe with world.testEntityPosition first — SV_CheckStuck
  silently restores oldorigin from a solid spot (that is authentic
  WinQuake behavior, not a bug).

### 2026-07-04 (playtest: harsh stairs in QW)
- User playtest report: stair climbing "harsh and hard" in the QW boot.
  Root causes found: (1) qwclient.luau had NO V_CalcRefdef stair-step
  smoothing (the NQ boot has it; the QW camera snapped a full riser per
  step) — ported the oldz 80 u/s glide with the 12-unit cap; (2) the
  pmove VERIFIED rows rested on a flat-only truth course, so the
  step-up code path had zero C coverage — an evidence-scope bug. Added
  a second 160-tick course to tools/pmove_truth.c + test_qw_pmove on
  dm3's staircase at x=-64 (found by hull-trace scan, not memory):
  climb/descend/re-climb/jumping/diagonal. Result: step-ups match the
  verbatim C to 0.000122 units — the "hard" half was the missing camera
  smoothing, not a physics divergence. PM_GroundMove/PM_Friction/
  PM_CatagorizePosition/JumpButton/PM_FlyMove/PM_AirMove/PM_Accelerate
  rows now cite the two-course truth run; header notes terrain covered
  and that water remains uncovered (PM_WaterMove stays PENDING).

### 2026-07-04 (bucket 1 continuation)
- qw-client console.c/keys.c (Con_Toggle/MessageMode/Clear/Draw*, Key_Console/Key_Message): UNIMPLEMENTED → PENDING. The QW boot now drives the shared consolelib (tilde toggle, history editor, scrollback, cl.prints into the console), a Cmd_ExecuteString subset (say/say_team, quit/disconnect note, fov via calcFovY, clear, toggleconsole) with Cmd_ForwardToServer fallback to clc_stringcmd, and T-messagemode chat ("say:" confont line, Enter → say "…"); input disabled while typing.
- qw-client cl_cam.c (Cam_Lock/Cam_Unlock/Cam_CheckHighTarget/Cam_Track/Cam_FinishMove/Cam_DrawPlayer/Cam_DrawViewModel): UNIMPLEMENTED → PENDING; Cam_Reset/CL_InitCam → SUBSTITUTED (cvars fixed on). Spectator autocam in qwclient.luau: highest-frags ptrack, chase-locked camera at the target's predicted origin + viewheight with their viewangles, jump-button cycling, clc_tmove ride-along, tracked model skipped. Flyby search (InitFlyby family) stays UNIMPLEMENTED. Live spectator screenshot still needed for VERIFIED.
- qw-client sbar.c (Sbar_Draw/DrawInventory/DrawFrags/DrawFace/DrawNum,
  intermission + DM overlays): UNIMPLEMENTED → PENDING. The QW boot now
  drives the NQ sbar.c port (hudlib) via a qwcl adapter (main bars are
  identical between the two sbar.c files; QW's ping-column DM overlay
  still pending). Structurally confirmed live (16 visible HUD elements);
  screenshot proof pending a Studio capture-tool recovery.
- nq-client S_StopSound: UNIMPLEMENTED → PENDING (svc_stopsound now
  routed through c.onStopSound → sound.stop; no offline assertion yet).
- qw-server PF_checkclient (builtin 17): dangling bsplib require fixed —
  PENDING (was a guaranteed runtime error).
- qw-server walkmove/checkbottom/changeyaw/movetogoal (builtins
  32/40/49/67): now fail with a diagnosable message instead of a nil
  call; remain UNIMPLEMENTED (stock qwprogs never calls them — they need
  a QW transform of sv_move.luau for mod support).
- qw-server WriteDest MSG_ONE: now writes to the target client's
  reliable netchan stream (was an unflushed buffer — centerprints were
  silently dropped). PENDING.
- qw-server SV_UpdateToReliableMessages: fully ported (frag rebroadcast,
  per-client svc_entgravity/svc_maxspeed on QC field change,
  reliable_datagram → all connected, sv.datagram → all spawned).
  VERIFIED for the frag path: test_qw_loopback "frag change rebroadcast"
  drives a kill over the wire and asserts the scoreboard update arrives.
- qw-server PF_lightstyle live broadcast: dead `svr.ss_active` compare
  and unflushed client.message fixed (ss_active == 2, netchan stream).
  PENDING.
- qw-server SV_SpawnServer changelevel: the QW boot now consumes
  svr.changelevelTo — respawns the server, republishes the bundle, and
  reissues serverdata to every connected client (they redo the full
  handshake; the QW client's CL_ClearState path rebuilds the renderer).
  PENDING (needs a live two-map rotation check).

### 2026-07-04 (visual pass)
- qw-client sbar.c main bar (Sbar_Draw/DrawInventory/DrawNum/DrawFace/
  DrawNormal via the hudlib adapter): PENDING -> VERIFIED. Studio Play
  screenshot (engine=qw, dm3): full status bar renders with live stats —
  shells 25 in the ammo row, armor 0, face, health 100, ammo 25.
  Remaining sbar overlays (ping scoreboard), console, cshift flash, and NQ
  wall-texture animation still need their own captures (tool recovered
  after a Studio play restart; next session can finish the pass).

### 2026-07-04 (vrect / view-weapon occlusion)
- Regression class caught by the user: once the sbar shipped, both engines'
  view weapons sat under it — the SCR_CalcRefdef SUBSTITUTED rows carried a
  justification ("replicate when the sbar lands") that had expired, and the
  qw V_CalcRefdef VERIFIED was earned before the HUD existed. Lesson encoded:
  a substitution's justification names its expiry condition; when the
  condition lands, the row reopens.
- Fix: qcoords.vrect — fov_y from the vrect (window minus sb_lines, exactly
  screen.c CalcFov usage) and the view model rotated up about the camera so
  the vrect bottom edge lands at the sbar top. World image remains
  window-centered (Roblox cameras have no projection-center offset): the
  vertical crop differs from C by sb/2, documented per row.
- VERIFIED both engines: live projection measurements (muzzle 83% vs sbar
  top 86%, C-projected 84%) + NQ screenshot with the muzzle visible above
  the HUD. SCR_CalcRefdef rows (both) and qw V_CalcRefdef updated.

### 2026-07-04 (visual pass, continued)
- qw-client console draw (Con_DrawConsole family): VERIFIED by screenshot —
  conback, notify area, and prompt render on toggle in Play. Console text
  ENTRY stays PENDING: key injection loses focus to Roblox CoreGui, so it
  needs a human-typed verification (or the RQDBG_Console hook).
- Still PENDING visuals: QW ping scoreboard (TAB cannot be injected —
  CoreGui-bound key; needs a human TAB or a debug toggle), pain flash,
  explosion sprite/particles in motion, NQ wall-texture animation cycling.

### 2026-07-04 (viewsize + sbar strip)
- The status bar is now architecturally "parked below" the view like
  WinQuake: an opaque full-width strip (world never visible inside it),
  the inventory row in its own container, and the viewsize cvar
  (screen.c sb_lines: 100/110/120) driving strip height, HUD rows, and
  the vrect fov together in both engines. VERIFIED with a vs100/vs110
  screenshot pair against the user's reference layout; the remaining
  platform delta stays the projection-center offset (world crop shifts
  by sb/2 vs C), documented on the SCR_CalcRefdef rows.

### 2026-07-04 (view-weapon projection, root-caused against WebQuake source)
- The reference (netquake.io) draws the view model through its OWN
  projection: WebQuake R.js R_DrawViewModel uses depthRange(0,0.3) and a
  vertical fov of fov*0.82 independent of window aspect (GLQuake
  heritage) — while gun PLACEMENT (V.js CalcRefdef) is byte-identical to
  WinQuake/ours. Emulated in entrender.updateAlias by squashing the view
  model's transverse vertex components by tan(fovCam/2)/tan(fovGun/2)
  (=0.632 at 16:9, =1.0 at 4:3 — the 0.82 factor is exactly the 4:3
  restoration). Verified applied: gun mesh vertex extents measure 0.632x
  on both transverse axes in Play. Replaces the vrect gun rotation.
- Remaining look difference vs netquake.io is HUD pixel scale only:
  they draw the bar at ~3%% of a large window; our SCALE=2 at a small
  Studio window is 14%% (equal to the Quakespasm scr_sbarscale=3 @1080p
  convention). scr_sbarscale-style adaptivity journaled as a HUD
  iteration item — presentation knob, no C truth at modern resolutions.

### 2026-07-04 (view-model projection: squash reverted, ViewportFrame planned)
- The transverse-squash emulation of the GL gun projection was exact only
  within the GL viewport's own coordinates; our window-centered camera
  shifts everything down by the projection-center offset (vrect center
  43%% vs window 50%%), so the composite still fell ~10%% short of the
  reference. Reverted to the verified vrect-rotation state.
- CORRECT ARCHITECTURE (next): render the view model in a ViewportFrame —
  own camera with the real fov*0.82 gun projection, frame sized to the
  vrect (projection center genuinely above the sbar strip), inherently
  drawn over the world (GL depthRange equivalent) and clipped at the
  strip. Needs: gun MeshPart in a WorldModel, manual light via setLight
  (already flat-lit), Ambient-only shading accepted as the platform
  delta. This closes the projection-center gap exactly for the gun.

### 2026-07-04 (view model: ViewportFrame gun pipeline — RESOLVED)
- The gun now renders through a real second projection: viewmodel.luau
  puts the view weapon in a ViewportFrame sized to the vrect (window
  minus sbar strip) with its own camera at fov*0.82 vertical (WebQuake
  R.js R_DrawViewModel truth), mirroring the world camera CFrame per
  frame. This is the actual GL gun architecture: own projection center
  (above the bar), drawn over the world (depthRange equivalent),
  clipped at the strip. Supersedes both the vrect gun rotation and the
  reverted vertex squash.
- VERIFIED by screenshots in BOTH engines: QW axe fills bottom-right to
  mid-screen (classic look); NQ shotgun spans bottom edge to ~68%% of
  the window vs the netquake.io reference's ~62%% (residual = their
  proportionally smaller HUD strip). EditableMesh/EditableImage content
  confirmed rendering inside ViewportFrames. Platform delta: Ambient-
  only shading in the frame; the gun was already flat-lit via setLight.

### 2026-07-04 (evidence reset)
- The VERIFIED status was re-audited mechanically: rows keep VERIFIED only
  if their evidence is re-runnable (cited test/check or compiled-C truth
  harness). 148 rows whose evidence was session prose or an unchecked-in
  screenshot were demoted to PENDING with the prior claim preserved inline
  (DEMOTED marker) — including several of this week's own screenshot
  verifications, since the captures were never committed. Standard going
  forward: VERIFIED requires a named test check or a screenshot committed
  under docs/coverage/evidence/ with capture context. Post-reset VERIFIED
  counts: nq-server 124, nq-client 17, qw-server 66, qw-client 45.

### 2026-07-04 (How-to-verify column)
- Every manifest table gained a fifth column: the executable
  re-verification procedure. Seeded mechanically — VERIFIED rows carry
  their `lune run tests/...` command (249 rows), PENDING rows carry an
  explicit TBD for the burn-down to fill with a test or a
  tools/verify script + evidence capture (460 rows), UNIMPLEMENTED and
  SUBSTITUTED rows are marked accordingly (457 rows). The burn-down
  definition of done per row: the How-to-verify cell contains a
  command anyone can run, and the Evidence cell cites its output.
