# Buried-delta triage — 2026-07-07

Trigger: the QW gun-bob bug. The V_CalcRefdef row (qw-client.md) was
VERIFIED while its notes said "gun bob simplified to forward push" — an
accurate description of a real bug (the gun's bob oscillation was entirely
missing; the forward offset was raw `speed*cl_bob*0.4` with no sine). The
delta was recorded 2026-07-05 and never triaged. Fixed 2026-07-07
(qwclient.luau gunorg = eye + fwd*(bob*0.4), QW-faithful calcBobQW with
on-ground bobtime + airborne hold in view.luau, 4 new test_view truths).

This sweep read all four manifests end-to-end and classified every
fidelity delta buried in VERIFIED/SUBSTITUTED row notes:

- **GAP** — genuine divergence still in the code → now listed in
  [FIDELITY.md](../../FIDELITY.md) "Open — ordered by visibility".
- **RULED** — deliberate or platform-inherent → the row gains an explicit
  `delta-ruled: ACCEPT (2026-07-07)` annotation instead of bare prose.
- **STALE** — delta text no longer matches the code → row rewritten to
  current truth.

New rule added to [README.md](README.md) burn-down rules: a VERIFIED row
may not carry an untriaged delta.

## Tally

| manifest | GAP (code) | GAP (test-coverage only) | RULED | STALE |
|---|---|---|---|---|
| qw-client.md | 2 | — | 12 | 8 |
| nq-client.md | ~16 (many folded into FIDELITY clusters) | 1 | 10 | 9 |
| nq-server.md | 5 | 7 | 10 | 2 |
| qw-server.md | 4 | 6 | 9 | 5 |

## Code gaps (→ FIDELITY.md Open)

See FIDELITY.md items 2–15. Headliners: alias-model directional shading
absent (both boots), server RNG hard-seeded to 12345 in production,
PF_objerror aborts the QC program where C continues, soundLog/printLog
unbounded growth on the QW server, NQ player-ent angles never forced to
view, PF_localcmd silent no-op for non-changelevel commands.

## Test-coverage debt (code believed faithful, evidence missing)

Not fidelity divergences — untested shipped branches. Chase in a coverage
pass, not FIDELITY:

- NQ server: SV_CheckWaterTransition water entry/exit (splash sounds;
  extend the water truth course), SV_Physics_Step freefall land-sound,
  SV_PointContents CONTENTS_CURRENT clamp, SV_Move MOVE_MISSILE entity
  clip, SV_HullForEntity box path, SV_SendClientMessages overflow-drop,
  PF_aim 0.93-assist staged target.
- QW server: spectator cluster (SV_PostRunCmd SpectatorThink, clc_tmove,
  SV_WritePlayersToClient spec masks, SV_UpdateClientStats spec_track
  passthrough), qwphys SV_CheckWaterTransition entry/exit, PF_aim assist
  branch.
- Process debt: ~15 qw-server rows cite "full sweep" as evidence — pin
  exact tests.

## Manifest factual errors found (fixed in the same pass)

- qw-server startParticle addition claimed a "PENDING wire path" to QW C —
  the QW server has NO particle builtin (slot 48 is PF_Fixme; no
  svc_particle/SV_StartParticle in reference/qw/server). Port-side NQ-ism.
- qw-client V_CalcRefdef "no view_ofs from server" listed as a delta — QW
  C itself uses fixed +22 (STAT_VIEWHEIGHT commented out in bothdefs.h);
  the port matches C. Not a divergence.
- qw-client "CalcGunAngle lag absent" contradicted the manifest's own
  CalcGunAngle row proving the shipped C lag terms are identically zero.
- nq-client Key_Console "no tab completion" — completion exists
  (console.luau:201-206 via com.completePrefix).
- nq-client Con_DrawConsole "no version string" — WinQuake draws none at
  draw time; it is baked into conback at Con_Init, which the port does.
- nq-server line 387 "ping_times[] not tracked" — the 16-slot ring exists
  (sv_user.luau:348-352) and Host_Ping_f consumes it.

## Why the audits missed the bob bug (post-mortem)

1. Deltas recorded inside VERIFIED rows were treated as closed — no step
   forced each one to become a ruling or a backlog item.
2. The audit unit was the C function, not the call-site wiring: shared
   calcBob was C-truth-tested and VERIFIED while the gun call site
   re-derived the formula inline and dropped the sine term.
3. Verification was static (screenshots, single-frame probes, formula
   unit tests); bob is temporal — invisible in any single frame.

Follow-ups (phases 2–3 of the plan): call-site wiring audit (grep for
C constants re-derived outside shared libs), and per-frame trace diffing
against a C view_truth generator (tools/pmove_truth.c pattern).

## Phase 2 — call-site wiring audit (same day)

Three parallel audits: view-cluster call sites vs C callers, inline
C-constant re-derivation sweep over the boot layer, and
mathlib/qcoords/prediction wiring. The prediction/pmove/coordinate chain
came back CLEAN (all nine pmove inputs, time bases, quantization order,
qcoords handedness at all 31 usages, all 24 angleVectors sites).

Bugs found and FIXED (all in the QW inline camera block or NQ powerup
bits; suites green after):

1. NQ powerup bits rotated (view.powerupShift + hud.luau): quad flashed
   invuln-yellow, suit quad-blue, pentagram suit-green — and
   test_view.luau asserted the SAME wrong constants, so the C-truth
   battery green-lit the bug. Re-grounded vs quakedef.h:157-160.
   Lesson: a C-truth test is only as good as the truth that went in.
2. QW gib view height: PF_GIB fell into the PF_DEAD -16 corpse branch
   (server sets both flags); C gives gib +8 priority. Block restructured
   to C's single alive/dead/gib path.
3. QW gun angles: computed after punch/kick with lean+kick roll; C's
   CalcGunAngle runs before punchangle and gun roll stays 0.
4. QW spectator bob: no cl.spectator gate — free-flying spectators
   pumped full bob from flight velocity.
5. Same restructure also landed: bob/kick/punch while dead (C applies
   them), the 1/16 node-line nudge, gun bob offset along RAW simangles
   (view.c:909), NQ pause gate (C: `if (!cl.paused) V_CalcRefdef()`),
   QW muzzleflash dlight keyed positive like C (slot sharing).

Ruled deliberate (kept): qwcl.nudgePosition called from predictMove — C
defines CL_NudgePosition but never calls it; the port's call fixes
lerped-origin-in-solid, bounded 1/8 unit. QW muzzleflash self-state from
predicted simorg + staleness guard (beats a latency-old playerstate).

Smells recorded, not fixed:
- predictUsercmd aliases `cmd` into pmove (C struct-copies); safe today
  (pmove never writes pm.cmd) but one added mutation from the bug class.
- Duplicated formulas across the twin boot files with no shared home:
  beam vectoangles (2 copies, both skip C's int truncation — chunky beam
  rotation authentically requires it), dlight-add loop (4 copies), stair
  glide + damage kick (QW inline copies of view.luau's C-truth-tested
  blocks), EF_ROTATE `%360` vs mathlib.anglemod. Extraction candidates:
  mathlib.vectoangles + a dlight-add helper.
- particlesim GRAVITY hardcoded 800; C reads live sv_gravity.
- cl_forwardspeed declared in both view.luau and input.luau.
