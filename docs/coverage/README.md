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

## Changelog

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
