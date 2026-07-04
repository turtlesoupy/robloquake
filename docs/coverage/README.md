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

| Manifest | Rows | Verified | Pending | Unimplemented | Substituted |
|---|---|---|---|---|---|
| [nq-server.md](nq-server.md) — WinQuake sim/server/shared | 455 | 157 | 125 | 62 | 111 |
| [nq-client.md](nq-client.md) — WinQuake client/presentation | 264 | 59 | 73 | 65 | 67 |
| [qw-server.md](qw-server.md) — QuakeWorld server | 236 | 120 | 51 | 24 | 41 |
| [qw-client.md](qw-client.md) — QuakeWorld client | 226 | 53 | 56 | 69 | 48 |
| **Total** | **1181** | **389** | **305** | **220** | **267** |

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
| S2 | NQ campaign loop: spawn, pickup, damage, changelevel carry, save/load round-trip | PENDING | — | TBD |
| S3 | NQ visual anchor: scripted fixed map + vantage screenshot committed under evidence/ | PENDING | — | TBD |
| S4 | QW visual anchor: same vantage discipline, QW engine | PENDING | — | TBD |

## Changelog

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
