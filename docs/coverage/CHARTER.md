# Coverage burn-down charter (user-ratified 2026-07-05)

**Goal**: drive docs/coverage/* to zero UNIMPLEMENTED and zero PENDING — every
row VERIFIED (re-runnable evidence), SUBSTITUTED (cited replacement), or N/A
(concept cannot exist; definition in docs/coverage/README.md). Baseline after
the 2026-07-05 hand passes (commits 9831648 + e0e7691): UNIMPLEMENTED
nq-client 36, nq-server 26, qw-client 53, qw-server 8; one honest PENDING
(qw-server SV_Serverinfo/Localinfo — finish serverinfo mutability or verify).

**Hard rules** (user-set):
- The thread may NOT move rows INTO N/A without flagging each for user review
  — all N/A classification was done by hand with the user; "don't want to
  build it" is never N/A.
- Every SUBSTITUTED move must cite WHERE the purpose is served.
- PENDING=0 invariant holds THROUGHOUT (evidence with the claim, not after).
- Totals sections are column-exact counts; update per commit.
- All lune suites green per commit; engine-core edits follow the usual
  fidelity discipline (this goal is mostly presentation/product layer).

**User rulings (2026-07-05), all decided — do not re-ask**:
- Dev tooling IMPLEMENT list: ED_Print/edicts family (both servers) +
  PR_ValueString/PR_GlobalString printers; qw ED_Write/ED_ParseGlobals;
  PR_PrintStatement + PR_Profile_f (+PR_StackTrace qw); V_cshift_f palette
  debugger; COM_Path_f; ALL of group D: Con_DPrintf (developer cvar),
  Con_SafePrintf, Cvar/Cmd tab completion, Host_Version_f/CL_Version_f,
  CL_User_f/CL_Users_f, S_Play/S_PlayVol/S_SoundList, S_LocalSound beeps.
- Already reclassified (done): profiling/timedemo family → N/A; Mod_Print,
  R_ReadPointFile_f, Draw_DebugChar, Con_DebugLog → N/A; CL_PrintEntities_f
  → SUBSTITUTED (RQ_VisEnts/RQDBG).
- 1996 menus: SPLIT — config menus (options/keys/setup/game-options,
  messagemode entry) → SUBSTITUTED citing console cmds/director/TextChat;
  save/load menus + main/single-player menu stay OPEN to implement as the
  authentic-feel core.
- Keyboard-look era: ALL OPEN — implement V_DriftPitch family (both boots)
  and QW keyboard turning (+left/+right etc.; NQ parity, input.updateTurn
  exists).
- Admin/social: fold into DIRECTOR — implement kick + status/ping as admin
  menu features; Host_Tell → SUBSTITUTED (Roblox whisper); SV_CheckVars join
  passwords → SUBSTITUTED (private servers); QW SV_God/Give/Noclip cheats →
  IMPLEMENT as host-gated commands (user explicitly rejected substituting
  them).

**Implementation priorities** (user-aligned): 1) QW presentation cluster —
TAB scoreboard/rankings overlays (reuse NQ hud.luau primitives; cl.players
has name/frags/ping verified), screen cshifts/palette blends, CTF
flag-on-back, QW player color translation, s_explod explosion sprite; 2) NQ
HUD odds (in-sbar DM frag cells, mini scoreboard, intermission sway); 3) the
implement lists above; 4) classification sweep last (definitions stable by
then; some rows say "as above" — dedupe).

**Context to inherit**: backlog memory (Luau local-before-declaration gotcha,
changelevel stress harness = timelimit 0.05 + maplist for regression-testing
overlays, rojo-sync verification habit, executor-VM cannot reach module
state, MCP callbacks die on invocation return). QW boot has no overlay infra;
NQ hud.luau is the explicit donor. Avatars-on-QW parity is a separate product
row, not this goal. FIDELITY.md untouched (complete; different document).
