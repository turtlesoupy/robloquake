# NQ client coverage

Function-level manifest for the NetQuake (WinQuake 1.09) client/presentation layer.
C reference: `reference/quake-c/WinQuake/`. Port: `src/client/` + `src/shared/engine/client/`.
Statuses: VERIFIED (offline test or recorded live check), PENDING (ported, no proof),
UNIMPLEMENTED (absent), SUBSTITUTED (platform-replaced, reason stated).
Evidence for VERIFIED cites `tests/*` or a FIDELITY.md record; nothing is invented.

## cl_main.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_ClearState | cl.luau parseServerInfo wipe + init.client onServerInfo teardown | VERIFIED | tests/test_changelevel.luau: fresh signon/precache on e1m2 after level change | `lune run tests/test_changelevel.luau` |
| CL_Disconnect | c.onDisconnect hook (print only) | UNIMPLEMENTED | no stop-sounds/clc_disconnect/demo teardown path; Roblox leave = session end | — (implement first) |
| CL_Disconnect_f | — | UNIMPLEMENTED | no `disconnect` command | — (implement first) |
| CL_EstablishConnection | clc_nop hello over RemoteEvent | SUBSTITUTED | no sockets; server connects the client when it first hears from it | — (substitution; verify justification still holds) |
| CL_SignonReply | cl.luau signonReply | VERIFIED | tests/test_loopback.luau: "client fully signed on" (prespawn/name/color/spawn/begin) | `lune run tests/test_loopback.luau` |
| CL_NextDemo | — | UNIMPLEMENTED | no startdemos attract-loop cycling; playdemo is manual | — (implement first) |
| CL_PrintEntities_f | — | UNIMPLEMENTED | RQ_VisEnts workspace attribute is the debug substitute | — (implement first) |
| SetPal | — | SUBSTITUTED | no hardware palette; cshift Frame tint covers the visible effect | — (substitution; verify justification still holds) |
| CL_AllocDlight | init.client allocDlight | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: the rocket explosion allocates a dlight whose radial wash re-lights the floor mid-flash. | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| CL_DecayLights | heartbeat decay pass | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: the wash is gone 1.2s after unpause — radius decay + die gate. | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| CL_RelinkEntities | cl.luau relinkEntities + init.client effects/trails dispatch | VERIFIED | tests/test_loopback.luau: forward motion interpolated, visible-entity counts; FIDELITY.md trail record; delta: visedict list → per-entity visible flag on persistent instances | `lune run tests/test_loopback.luau` |
| CL_ReadFromServer | inbound queue pump in heartbeat | VERIFIED | tests/test_loopback.luau drives the same parse path end to end | `lune run tests/test_loopback.luau` |
| CL_SendCmd | 72Hz-throttled sample + buildMove + takeReliable | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: "W→forwardmove 200 over the wire" | TBD: write test or tools/verify script + evidence capture |
| CL_Init | init.client boot sequence | PENDING | cvars are hardcoded constants; no cvar registration layer | TBD: write test or tools/verify script + evidence capture |

## cl_parse.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_ParseStartSoundPacket | cl.luau parseStartSound | VERIFIED | tests/test_loopback.luau: "shotgun sound event received" | `lune run tests/test_loopback.luau` |
| CL_KeepaliveMessage | — | UNIMPLEMENTED | RemoteEvent transport has no keepalive need during long loads | — (implement first) |
| CL_ParseServerInfo | cl.luau parseServerInfo | VERIFIED | tests/test_loopback.luau: levelname/maxclients/precache lists; test_changelevel.luau | `lune run tests/test_changelevel.luau`; `lune run tests/test_loopback.luau` |
| CL_ParseUpdate | cl.luau parseUpdate | VERIFIED | tests/test_loopback.luau: entity positions/visibility through fast updates | `lune run tests/test_loopback.luau` |
| CL_ParseBaseline | cl.luau parseBaseline | VERIFIED | tests/test_loopback.luau signon path (baselines feed spawnstatic/spawnbaseline) | `lune run tests/test_loopback.luau` |
| CL_ParseClientdata | cl.luau parseClientdata | VERIFIED | tests/test_loopback.luau: health 100, shells 25, velocity, onground | `lune run tests/test_loopback.luau` |
| CL_NewTranslation | textures.translatePixels + entrender translatedSkins cache | PENDING | shirt/pants rows 16-31/96-111 incl. reversed ranges; applied as whole-skin image, not colormap | TBD: write test or tools/verify script + evidence capture |
| CL_ParseStatic | cl.luau parseStatic + statics spawn pass | VERIFIED | test_scenario_nq "torch statics parsed on e1m2" (svc_spawnstatic through the wire client; the statics spawn pass renders them Studio-side). | `lune run tests/test_scenario_nq.luau` |
| CL_ParseStaticSound | cl.luau + sound.static | VERIFIED | tests/test_loopback.luau: "ambient sounds spawned" (>=4) | `lune run tests/test_loopback.luau` |
| CL_ParseServerMessage | cl.luau parseServerMessage | VERIFIED | tests/test_loopback.luau full protocol path; FIDELITY.md byte-exact protocol 15 layer; delta: svc_stopsound read but discarded, svc_cdtrack stored but unused | `lune run tests/test_loopback.luau` |

## cl_input.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| KeyDown / KeyUp | input.setButton via +/- command routing | PENDING | delta: no two-keycode tracking per button; attack/jump edge latches only | TBD: write test or tools/verify script + evidence capture |
| IN_*Down/Up (34 one-line stubs) | BUTTON_CMDS table in init.client | PENDING | +forward/back/left/right/moveleft/moveright/moveup/movedown/jump/attack/use/speed/strafe/klook/mlook/lookup/lookdown all routed | TBD: write test or tools/verify script + evidence capture |
| IN_Impulse | `impulse` command → input.setImpulse | PENDING | | TBD: write test or tools/verify script + evidence capture |
| CL_KeyState | boolean btn() | PENDING | delta: no 0.25/0.5/0.75 partial-frame press fractions — taps register a full frame | TBD: write test or tools/verify script + evidence capture |
| CL_AdjustAngles | input.updateTurn | PENDING | cl_yawspeed 140 / cl_pitchspeed 150 / cl_anglespeedkey 1.5 match; FIDELITY.md records the port, no cited proof | TBD: write test or tools/verify script + evidence capture |
| CL_BaseMove | input.sample | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: "W→forwardmove 200 over the wire"; speeds 200/200/350/200, movespeedkey 2 | TBD: write test or tools/verify script + evidence capture |
| CL_SendMove | cl.luau buildMove | VERIFIED | tests/test_loopback.luau (movement observed server-side); first-2-message drop kept | `lune run tests/test_loopback.luau` |
| CL_InitInput | bind table + BUTTON_CMDS wiring | PENDING | | TBD: write test or tools/verify script + evidence capture |

## cl_demo.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_StopPlayback | init.client stopDemo | VERIFIED | test_demo end-of-blob stop path; live "demo completed" + rejoin message. | `lune run tests/test_demo.luau` |
| CL_WriteDemoMessage | record branch in heartbeat pump | VERIFIED | test_demo: the exact block format ([i32 len][3x f32 angles][payload], "-1\n" track line) written from a live loopback stream and read back. | `lune run tests/test_demo.luau` |
| CL_GetMessage (demo path) | init.client demoFrame with mtime pacing | VERIFIED | test_demo: the demoFrame reader loop (mirrored verbatim) paces blocks against cl.time vs mtime and replays the run — view entity moves >100 units, including on a REUSED client with a stale clock. OPEN Studio-glue bug (journaled): self-recorded demos play back with a frozen view entity in Studio even though demo1.dem plays fine and the same reader works offline — the divergence is in init.client runtime glue, not the engine pipeline. | `lune run tests/test_demo.luau` |
| CL_Stop_f | `stop` command | VERIFIED | test_demo: stop closes the blob; live: "Completed demo (N bytes, ...)". Delta: demo kept in memory, not a file. | `lune run tests/test_demo.luau` |
| CL_Record_f | `record` command | VERIFIED | test_demo (writer); live: bare `record` while connected now REFUSES with C's exact message (was silently producing signon-less demos that play back frozen — 2026-07-04 fix), and `record <name> <map>` runs the map first so the fresh signon is captured, as C. | `lune run tests/test_demo.luau`; RQDBG_Console: `record x` while connected shows the refusal |
| CL_PlayDemo_f | `playdemo` command | VERIFIED | test_demo: track-line skip + signon replay from a recorded blob (fresh and reused clients); demo1.dem plays live in Studio (camera runs the recorded course, pickup prints replay). Same open Studio-glue note as CL_GetMessage for self-recorded demos. | `lune run tests/test_demo.luau` |
| CL_FinishTimeDemo | — | UNIMPLEMENTED | no timedemo benchmarking | — (implement first) |
| CL_TimeDemo_f | — | UNIMPLEMENTED | no timedemo benchmarking | — (implement first) |

## cl_tent.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_InitTEnts | lazy beamModelDef + soundbank regions | PENDING | delta: bolt models/sfx loaded on first use instead of precached | TBD: write test or tools/verify script + evidence capture |
| CL_ParseBeam | init.client parseBeam (via cl.luau TE event) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md lightning beams record; entity-override + free-slot scan kept, MAX_BEAMS 24 | TBD: write test or tools/verify script + evidence capture |
| CL_ParseTEnt | cl.luau parseTEnt + init.client onTempEntity | VERIFIED | FIDELITY.md impact sounds (fd28443); TE_TAREXPLOSION → blobExplosion (no dlight) and TE_EXPLOSION2 → particleExplosion2(colorStart/Length) + dlight now match cl_tent.c; spawners proven in tests/test_particles2.luau (routing itself unexercised by tests) | `lune run tests/test_particles2.luau` |
| CL_NewTempEntity | beamPool pooled render entities | PENDING | delta: pooled per model name, capped 40 segments/beam | TBD: write test or tools/verify script + evidence capture |
| CL_UpdateTEnts | init.client updateBeams | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: 30-unit segments, random roll, player-tracked start, 0.2s life; delta: C int-truncates yaw/pitch, port keeps float | TBD: write test or tools/verify script + evidence capture |

## chase.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Chase_Init | chase_active console command | PENDING | cvar-only; chase_back/up/right hardcoded 100/16/0 | TBD: write test or tools/verify script + evidence capture |
| Chase_Reset | — | UNIMPLEMENTED | C stub is an empty TODO too | — (implement first) |
| TraceLine | worldlib.recursiveHullCheck against hull 0 | VERIFIED | FIDELITY.md: hull collision bit-exact vs trace_truth (1503 checks) | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Chase_Update | init.client chase branch | VERIFIED | [evidence/nq-chase-cam.jpg](evidence/nq-chase-cam.jpg) + .txt: chase.c offsets, player.mdl from behind, gun hidden, no wall clip (authentic quirk). | Console "chase_active 1" per evidence/nq-chase-cam.txt, capture, compare |

## view.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| V_CalcRoll | view.luau calcRoll (now shared: src/shared/engine/client/view.luau) | VERIFIED | test_view.luau hand-computed C truths: side scaling 2/200 below rollspeed, clamp at exactly 200, sign from dot(vel,right), yaw-rotated right vector. | `lune run tests/test_view.luau` |
| V_CalcBob | view.luau calcBob (shared module) | VERIFIED | test_view.luau: cycle fraction of cl_bobcycle .6, pi ramp split at bobup .5 (peak sin at t=.15, trough at t=.45), xy-speed*.02, .3+.7*sin mix, clamps 4/-7. | `lune run tests/test_view.luau` |
| V_StartPitchDrift | — | UNIMPLEMENTED | always-mouselook: C disables drift under mouselook anyway | — (implement first) |
| V_StopPitchDrift | — | UNIMPLEMENTED | as above | — (implement first) |
| V_DriftPitch | — | UNIMPLEMENTED | as above; idealpitch received but unused | — (implement first) |
| BuildGammaTable | — | SUBSTITUTED | no palette; gamma folded into the ^0.7 light curve | — (substitution; verify justification still holds) |
| V_CheckGamma | — | SUBSTITUTED | as above | — (substitution; verify justification still holds) |
| V_ParseDamage | cl.luau parseDamage | VERIFIED | test_view.luau wire battery: count (blood+armor)*.5 floored at 10, faceanimtime +0.2, damage cshift 3*count clamped 0..150, color split (255,0,0)/(200,100,100)/(220,50,50), kicks count*side*0.6 from the hit direction, dmg_time 0.5. | `lune run tests/test_view.luau` |
| V_cshift_f | — | UNIMPLEMENTED | debug command | — (implement first) |
| V_BonusFlash_f | "bf" stufftext → cshift_bonus_percent 50 | PENDING | bonus color 215/186/69 matches | TBD: write test or tools/verify script + evidence capture |
| V_SetContentsColor | init.client view-leaf contents shifts | VERIFIED | [evidence/nq-slime-cshift.jpg](evidence/nq-slime-cshift.jpg) + .txt: full-screen slime tint while submerged, blended with the damage flash from the slime tick. Delta: no CONTENTS_SOLID grey (cannot be seen in play). | Teleport per evidence/nq-slime-cshift.txt, capture, compare |
| V_CalcPowerupCshift | init.client powerup shifts | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: priority quad > suit > ring > pent matches | TBD: write test or tools/verify script + evidence capture |
| V_CalcBlend | init.client shift compositor | PENDING | same a2/(1-a) accumulation; delta: final alpha capped at 0.85 | TBD: write test or tools/verify script + evidence capture |
| V_UpdatePalette | cshift Frame tint + decay | SUBSTITUTED | palette blend → fullscreen GUI tint; damage/bonus decay 150/100 per second ported | — (substitution; verify justification still holds) |
| angledelta / CalcGunAngle | gunangles = (-pitch, yaw, 0) | SUBSTITUTED | Gun locked to the view: the C damped yaw/pitch lag (angledelta smoothing) is not ported; the base mapping (-pitch, yaw, punch excluded) is asserted in test_view.luau. Expiry: port the damped lag if playtesting reports the gun feeling glued/stiff during fast turns. | `lune run tests/test_view.luau` (base mapping) |
| V_BoundOffsets | — | UNIMPLEMENTED | scr_ofsx/y/z not supported | — (implement first) |
| V_AddIdle | — | UNIMPLEMENTED | v_idlescale defaults 0 in C; constant kept but unused | — (implement first) |
| V_CalcViewRoll | folded into view.calcRefdef | VERIFIED | test_view.luau: movement roll folded into refdef angles, dmg kick decay (dmg_time/v_kicktime scaling, -= frametime), dead roll pinned at 80. Delta stands: no v_centermove interaction. | `lune run tests/test_view.luau` |
| V_CalcIntermissionRefdef | — | UNIMPLEMENTED | intermission uses the normal refdef; no idle sway, gun hidden instead | — (implement first) |
| V_CalcRefdef | view.calcRefdef | VERIFIED | test_view.luau composition battery: origin + viewheight + bob + 1/32 nudge, gun origin eye + forward*bob*.4 + z bob, punch added AFTER gun angles (C order), stair glide 80 u/s with the 12-unit cap and airborne snap, STAT_WEAPON/WEAPONFRAME pass-through. Deltas stand: no pitch drift, no scr_ofs, no viewsize gun-z fudge, player ent angles not forced to view. | `lune run tests/test_view.luau` |
| V_RenderView | heartbeat camera CFrame + crosshair label | PENDING | crosshair '+' conchars glyph like the C Draw_Character call; defaults ON (recorded divergence) | TBD: write test or tools/verify script + evidence capture |
| V_Init | constants in view.luau/init.client | SUBSTITUTED | no cvar system; defaults baked in | — (substitution; verify justification still holds) |

## sbar.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Sbar_ShowScores / Sbar_DontShowScores | +/-showscores → hud.setShowScores | VERIFIED | [evidence/nq-solo-scoreboard.jpg](evidence/nq-solo-scoreboard.jpg): +showscores raises the overlay; -showscores restores. | Console "+showscores" per evidence/nq-solo-scoreboard.txt, capture, compare |
| Sbar_Changed | — | SUBSTITUTED | retained GUI; no dirty-region repaint needed | — (substitution; verify justification still holds) |
| Sbar_Init | hud.create (wad pics cached lazily) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawPic / Sbar_DrawTransPic | setPic → ImageLabel | SUBSTITUTED | framebuffer blit → ImageLabel; index 255 transparent | — (substitution; verify justification still holds) |
| Sbar_DrawCharacter / Sbar_DrawString | confont rows | SUBSTITUTED | conchars glyph labels | — (substitution; verify justification still holds) |
| Sbar_itoa | string.format | SUBSTITUTED | trivial | — (substitution; verify justification still holds) |
| Sbar_DrawNum | hud drawNum | PENDING | right-justified 24px slots, anum_ red variant, last-3-digit clip match | TBD: write test or tools/verify script + evidence capture |
| Sbar_SortFrags | buildRankings sort | PENDING | delta: skips empty names then sorts by frags (C insertion sort, same order) | TBD: write test or tools/verify script + evidence capture |
| Sbar_UpdateScoreboard | sig-string rebuild in updateOverlays | SUBSTITUTED | rebuild-on-change replaces per-frame scratch build | — (substitution; verify justification still holds) |
| Sbar_SoloScoreboard | hud soloRows | VERIFIED | [evidence/nq-solo-scoreboard.jpg](evidence/nq-solo-scoreboard.jpg): exact C fields — Monsters 0/23, Secrets 0/6, Time, level name over the status row. | Console "+showscores" per evidence/nq-solo-scoreboard.txt, capture, compare |
| Sbar_DrawScoreboard | updateOverlays dispatch | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawInventory | weapon icons + flash + counts + items + sigils | PENDING | flashon formula ((time-gettime)*10, %5+2, inv2_ active) matches; counts as conchars 18+digit | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawFrags | — | UNIMPLEMENTED | in-sbar DM frag cells (4 players) not drawn | — (implement first) |
| Sbar_DrawFace | hud face branch | PENDING | invis+invuln/quad/invis/invuln specials + 5 health bands + pain via faceanimtime match | TBD: write test or tools/verify script + evidence capture |
| Sbar_Draw | hud.update | PENDING | delta: no viewsize/lineadj interaction — sbar always drawn | TBD: write test or tools/verify script + evidence capture |
| Sbar_IntermissionNumber | interBigNum | VERIFIED | [evidence/nq-intermission.jpg](evidence/nq-intermission.jpg): big digits for Time/Secrets/Kills at the C coordinates. | Exit-trigger procedure per evidence/nq-intermission.txt, capture, compare |
| Sbar_DeathmatchOverlay | buildRankings | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: ranking.lmp, colour bars, frags, self marker char 12 | TBD: write test or tools/verify script + evidence capture |
| Sbar_MiniDeathmatchOverlay | — | UNIMPLEMENTED | small mid-game DM list absent | — (implement first) |
| Sbar_IntermissionOverlay | buildIntermission | VERIFIED | [evidence/nq-intermission.jpg](evidence/nq-intermission.jpg) + .txt: complete.lmp plaque + inter.lmp labels + big numbers over the info_intermission vantage. | Exit-trigger procedure per evidence/nq-intermission.txt, capture, compare |
| Sbar_FinaleOverlay | finale.lmp branch | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md finale record | TBD: write test or tools/verify script + evidence capture |

## screen.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SCR_CenterPrint | hud.centerPrint | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: centerprints in conchars with faithful metrics (0.35h block, per-line centering) | TBD: write test or tools/verify script + evidence capture |
| SCR_EraseCenterString | retained GUI | SUBSTITUTED | no framebuffer erase needed | — (substitution; verify justification still holds) |
| SCR_DrawCenterString | hud.centerPrint rows + finale typewriter | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: finale typewriter at scr_printspeed | TBD: write test or tools/verify script + evidence capture |
| SCR_CheckDrawCenterString | centerTime gate in hud.update | PENDING | scr_centertime 2s; stays up during intermission like C | TBD: write test or tools/verify script + evidence capture |
| CalcFov | qcoords.calcFovY | VERIFIED | test_qcoords: matches a transcribed screen.c CalcFov on 5 cases + hand-derived anchors (fov 90 -> 73.74 at 4:3, 58.72 at 16:9). Delta: horizontal fov converted to vertical at the real viewport aspect (Roblox FOV is vertical). | `lune run tests/test_qcoords.luau` |
| SCR_CalcRefdef | qcoords.vrect (both boots) | PENDING | Math half VERIFIED offline: test_qcoords (vrect fov_y at reduced height, gun rotation scaling). Visual half needs the S3 anchor screenshot. | `lune run tests/test_qcoords.luau` + S3 evidence capture |
| SCR_SizeUp_f / SCR_SizeDown_f | accepted no-op commands | UNIMPLEMENTED | viewsize fixed | — (implement first) |
| SCR_Init | init.client GUI setup | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SCR_DrawRam / SCR_DrawTurtle / SCR_DrawNet | — | UNIMPLEMENTED | perf/lag indicator icons absent | — (implement first) |
| SCR_DrawPause | hud pausePlaque | VERIFIED | [evidence/nq-pause-plaque.jpg](evidence/nq-pause-plaque.jpg) + .txt: pause.lmp centered over the paused world. | Console "pause" per evidence/nq-pause-plaque.txt, capture, compare |
| SCR_DrawLoading / SCR_BeginLoadingPlaque / SCR_EndLoadingPlaque | hud.setLoading + loadingUp gate | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: notify/centerprint clear, plaque holds until first rendered frame | TBD: write test or tools/verify script + evidence capture |
| SCR_SetUpToDrawConsole | console.update slide | VERIFIED | Half-screen slide in [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg); mid-slide retraction visible at the top of [evidence/nq-pause-plaque.jpg](evidence/nq-pause-plaque.jpg) (scr_conspeed). | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| SCR_DrawConsole | console.update rows | PENDING | | TBD: write test or tools/verify script + evidence capture |
| WritePCXfile / SCR_ScreenShot_f | `screenshot` accepted no-op | UNIMPLEMENTED | no writable filesystem | — (implement first) |
| SCR_ModalMessage | — | UNIMPLEMENTED | no modal quit/confirm flow (Roblox owns quit) | — (implement first) |
| SCR_DrawNotifyString | — | UNIMPLEMENTED | modal notify text (goes with SCR_ModalMessage) | — (implement first) |
| SCR_BringDownConsole | — | UNIMPLEMENTED | | — (implement first) |
| SCR_UpdateScreen | Heartbeat overlay updates | SUBSTITUTED | Roblox render pipeline owns presentation; per-frame GUI updates replace the 2D compose | — (substitution; verify justification still holds) |
| SCR_UpdateWholeScreen | — | SUBSTITUTED | as above | — (substitution; verify justification still holds) |

## console.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Con_ToggleConsole_f | console.toggle (backquote/tilde) | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: console toggled open/closed through the harness across the battery. Delta: no Key_ClearStates. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_Clear_f | `clear` command | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Con_ClearNotify | hud.setLoading clears notifyLines | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Con_MessageMode_f / Con_MessageMode2_f | stub print | UNIMPLEMENTED | pointed at `say`/Roblox chat | — (implement first) |
| Con_CheckResize | — | SUBSTITUTED | fixed 64-column virtual canvas | — (substitution; verify justification still holds) |
| Con_Init | console.create | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: conback + id watermark drawn (Draw_ConsoleBackground). | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_Linefeed | implicit in print | SUBSTITUTED | | — (substitution; verify justification still holds) |
| Con_Print | console.print | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: scrollback renders the battery lines. Delta: hard wrap at 64 cols, 200-line scrollback vs 16K text buffer. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_DebugLog | — | UNIMPLEMENTED | | — (implement first) |
| Con_Printf | c.print → console + notify + output | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: c.print output (VERSION banner, cvar prints) lands in the console. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_DPrintf | plain print() | UNIMPLEMENTED | no developer cvar gate | — (implement first) |
| Con_SafePrintf | — | UNIMPLEMENTED | no screen-disable variant needed | — (implement first) |
| Con_DrawInput | input row + blinking char-11 cursor | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: ] prompt with blinking char-11 cursor. Delta: no horizontal scroll of long input. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_DrawNotify | hud notifyRows (4 lines, 3s) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: notify in conchars, faithful metrics; recorded divergence: sits below Roblox topbar inset | TBD: write test or tools/verify script + evidence capture |
| Con_DrawConsole | console.update | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: half-screen console over the world. Delta: no scrollback paging, no version string. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Con_NotifyBox | — | UNIMPLEMENTED | | — (implement first) |

## keys.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Key_Console | console.handleKey/handleText | PENDING | enter/backspace/up/down history; delta: no tab completion, no pgup/pgdn scrollback, no clipboard paste | TBD: write test or tools/verify script + evidence capture |
| Key_Message | — | UNIMPLEMENTED | chat via Roblox | — (implement first) |
| Key_StringToKeynum / Key_KeynumToString | KEYNAMES map | PENDING | delta: Roblox KeyCodes; Escape reserved by platform (menu on M), mouse1-3 mapped | TBD: write test or tools/verify script + evidence capture |
| Key_SetBinding | bindings table | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: bind x sets, query echoes "x" = "echo xkey_fired". | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Key_Unbind_f / Key_Unbindall_f / Key_Bind_f | bind/unbind/unbindall commands | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: bind query + unbind clears the binding. Delta: unbound query prints "x" = "" instead of C's '"x" is not bound'. | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Key_WriteBindings | — | UNIMPLEMENTED | no config.cfg persistence (FIDELITY platform substitution; DataStore later) | — (implement first) |
| Key_Init | default.cfg exec at boot + autoexec layer | VERIFIED | [evidence/nq-console-open.jpg](evidence/nq-console-open.jpg) + .txt: boot scrollback opens with "execing default.cfg" and "couldn't exec autoexec.cfg" (pak default.cfg + autoexec layer at boot). | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Key_Event | init.client keyEvent via UserInputService | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: keyups fire the -command; W→forwardmove chain | TBD: write test or tools/verify script + evidence capture |
| Key_ClearStates | input.setEnabled(false) clears buttons | PENDING | cleared when console/menu opens | TBD: write test or tools/verify script + evidence capture |

## menu.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| M_DrawCharacter / M_Print / M_PrintWhite | — | SUBSTITUTED | implemented menus are pure .lmp pics; no text menus yet | — (substitution; verify justification still holds) |
| M_DrawTransPic / M_DrawPic | menu.addPic → ImageLabel | SUBSTITUTED | blit → ImageLabel | — (substitution; verify justification still holds) |
| M_BuildTranslationTable / M_DrawTransPicTranslate | — | UNIMPLEMENTED | player setup menu absent (textures.translatePixels exists for in-game skins) | — (implement first) |
| M_DrawTextBox | — | UNIMPLEMENTED | | — (implement first) |
| M_ToggleMenu_f | `togglemenu` / M key | VERIFIED | [evidence/nq-main-menu.jpg](evidence/nq-main-menu.jpg) + .txt: togglemenu raises the menu. Delta: Escape reserved by Roblox (M key/togglemenu). | Console "togglemenu" per evidence/nq-main-menu.txt, capture, compare |
| M_Menu_Main_f / M_Main_Draw / M_Main_Key | menu.create/update/handleKey | VERIFIED | [evidence/nq-main-menu.jpg](evidence/nq-main-menu.jpg): qplaque + ttl_main + mainmenu entries + animated menudot at the C coordinates. Delta: key navigation not exercised in the capture (needs real key events). | Console "togglemenu" per evidence/nq-main-menu.txt, capture, compare |
| M_Menu_SinglePlayer_f / M_SinglePlayer_Draw / M_SinglePlayer_Key | Enter on item 0 → `map start` | UNIMPLEMENTED | submenu absent; direct new-game action instead | — (implement first) |
| M_ScanSaves / M_Menu_Load_f / M_Menu_Save_f / M_Load_Draw / M_Save_Draw / M_Load_Key / M_Save_Key | — | UNIMPLEMENTED | F6/F9 quicksave/quickload binds work end to end (FIDELITY save/load record) | — (implement first) |
| M_Menu_MultiPlayer_f / M_MultiPlayer_Draw / M_MultiPlayer_Key | stub print | UNIMPLEMENTED | Roblox players join the server automatically | — (implement first) |
| M_Menu_Setup_f / M_Setup_Draw / M_Setup_Key | — | UNIMPLEMENTED | name comes from Roblox; color fixed 0x04 | — (implement first) |
| M_Menu_Net_f / M_Net_Draw / M_Net_Key | — | UNIMPLEMENTED | serial/IPX/TCP menu meaningless here | — (implement first) |
| M_Menu_Options_f / M_AdjustSliders / M_DrawSlider / M_DrawCheckbox / M_Options_Draw / M_Options_Key | — | UNIMPLEMENTED | console commands (sensitivity, fov, crosshair, chase_active) cover the options | — (implement first) |
| M_Menu_Keys_f / M_FindKeysForCommand / M_UnbindCommand / M_Keys_Draw / M_Keys_Key | — | UNIMPLEMENTED | bind/unbind console commands cover it | — (implement first) |
| M_Menu_Video_f / M_Video_Draw / M_Video_Key | — | UNIMPLEMENTED | no video modes on platform | — (implement first) |
| M_Menu_Help_f / M_Help_Draw / M_Help_Key | help state + gfx/help0-5.lmp pages | PENDING | forward/back paging kept; back on Backspace/M | TBD: write test or tools/verify script + evidence capture |
| M_Menu_Quit_f / M_Quit_Key / M_Quit_Draw | onQuit → print | UNIMPLEMENTED | quitting is Roblox's; no confirm screen | — (implement first) |
| M_Menu_SerialConfig_f / M_SerialConfig_Draw / M_SerialConfig_Key | — | UNIMPLEMENTED | DOS serial/modem N/A | — (implement first) |
| M_Menu_ModemConfig_f / M_ModemConfig_Draw / M_ModemConfig_Key | — | UNIMPLEMENTED | N/A | — (implement first) |
| M_Menu_LanConfig_f / M_LanConfig_Draw / M_LanConfig_Key | — | UNIMPLEMENTED | N/A | — (implement first) |
| M_Menu_GameOptions_f / M_GameOptions_Draw / M_NetStart_Change / M_GameOptions_Key | — | UNIMPLEMENTED | server rules are server-side console/attributes | — (implement first) |
| M_Menu_Search_f / M_Search_Draw / M_Search_Key | — | UNIMPLEMENTED | no LAN search | — (implement first) |
| M_Menu_ServerList_f / M_ServerList_Draw / M_ServerList_Key | — | UNIMPLEMENTED | no server list | — (implement first) |
| M_Init | menu.create | PENDING | | TBD: write test or tools/verify script + evidence capture |
| M_Draw | menu.update | PENDING | delta: no console-behind-menu dim (Draw_FadeScreen absent) | TBD: write test or tools/verify script + evidence capture |
| M_Keydown | menu.handleKey | PENDING | delta: no menu sounds (S_LocalSound absent) | TBD: write test or tools/verify script + evidence capture |
| M_ConfigureNetSubsystem | — | UNIMPLEMENTED | N/A | — (implement first) |

## draw.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Draw_Init | confont/textures lazy init | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Draw_Character / Draw_String | confont glyph labels (color 0 transparent) | VERIFIED | Confont glyph rendering across all three captures (console text, scoreboard fields, plaque). | RQDBG_Console battery per evidence/nq-console-open.txt, capture, compare |
| Draw_DebugChar | — | UNIMPLEMENTED | | — (implement first) |
| Draw_Pic / Draw_TransPic | textures.createImage + ImageLabel (255 transparent) | PENDING | used by hud/menu/plaques | TBD: write test or tools/verify script + evidence capture |
| Draw_TransPicTranslate | — | UNIMPLEMENTED | only the setup menu used it | — (implement first) |
| Draw_CharToConback | — | UNIMPLEMENTED | no version string stamped on conback | — (implement first) |
| Draw_ConsoleBackground | conback ImageLabel in console.create | PENDING | delta: fixed-size canvas, no partial-height crop of the pic itself (frame slides instead) | TBD: write test or tools/verify script + evidence capture |
| R_DrawRect8 / R_DrawRect16 | — | SUBSTITUTED | framebuffer rect blits; GPU composites GUI | — (substitution; verify justification still holds) |
| Draw_TileClear | — | SUBSTITUTED | no vrect borders — 3D view is full-window | — (substitution; verify justification still holds) |
| Draw_Fill | hud interFill (palette-indexed Frames) | PENDING | used for scoreboard colour bars | TBD: write test or tools/verify script + evidence capture |
| Draw_FadeScreen | — | UNIMPLEMENTED | menu backdrop dim absent | — (implement first) |
| Draw_BeginDisc / Draw_EndDisc | — | UNIMPLEMENTED | disc I/O icon absent | — (implement first) |

## snd_dma.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| S_Init / S_Startup / S_Shutdown / S_SoundInfo_f | sound.new | SUBSTITUTED | no DMA/PCM buffer; soundbank asset + PlaybackRegion slices (FIDELITY audio substitution) | — (substitution; verify justification still holds) |
| S_AmbientOff / S_AmbientOn | — | UNIMPLEMENTED | ambients always on | — (implement first) |
| S_FindName / S_TouchSound / S_PrecacheSound | soundmap regions (offline tools/build_soundbank.py) | SUBSTITUTED | per-sample time slices replace sfx_t cache | — (substitution; verify justification still holds) |
| SND_PickChannel | channels[entnum*8+channel] map | PENDING | entity-channel override in place; delta: CHAN_AUTO fire-and-forget never steals the oldest channel | TBD: write test or tools/verify script + evidence capture |
| SND_Spatialize | Roblox RollOffMode.Linear, max = 1000/atten scaled | SUBSTITUTED | FIDELITY: Roblox rolloff approximating the linear curve; no stereo pan math | — (substitution; verify justification still holds) |
| S_StartSound | sound.start | VERIFIED | Numeric census (procedure in evidence/nq-main-menu.txt): a forced shotgun burst raises the playing-Sound instance count; wire delivery separately proven by the loopback sound checks. | Census chunk per evidence/nq-main-menu.txt |
| S_StopSound | sound.stop exists but is never called | UNIMPLEMENTED | svc_stopsound is parsed and discarded in cl.luau — looped entity sounds can't be stopped | — (implement first) |
| S_StopAllSounds | sound.clear on serverinfo | PENDING | | TBD: write test or tools/verify script + evidence capture |
| S_ClearBuffer | — | SUBSTITUTED | no mix buffer | — (substitution; verify justification still holds) |
| S_StaticSound | sound.static (looped, vol/255, atten/64) | VERIFIED | Numeric census: 16 looping ambient Sounds playing at the e1m1 vantage (statics started from the signon); event delivery proven by test_loopback "ambient sounds spawned". | Census chunk per evidence/nq-main-menu.txt; `lune run tests/test_loopback.luau` |
| S_UpdateAmbientSounds | sound.updateAmbients | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: water1/wind2 from view-leaf levels, ambient_level 0.3 / fade 100 | TBD: write test or tools/verify script + evidence capture |
| S_Update / GetSoundtime / S_ExtraUpdate / S_Update_ | — | SUBSTITUTED | Roblox engine mixes and paints | — (substitution; verify justification still holds) |
| S_Play / S_PlayVol / S_SoundList | — | UNIMPLEMENTED | console audio utilities | — (implement first) |
| S_LocalSound | — | UNIMPLEMENTED | menu/console beeps absent | — (implement first) |
| S_ClearPrecache / S_BeginPrecaching / S_EndPrecaching | — | SUBSTITUTED | no-ops around the bank model | — (substitution; verify justification still holds) |

## snd_mem.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ResampleSfx | offline soundbank build | SUBSTITUTED | bank is pre-resampled at one rate (tools/build_soundbank.py) | — (substitution; verify justification still holds) |
| S_LoadSound | region lookup in sound.luau | SUBSTITUTED | | — (substitution; verify justification still holds) |
| GetLittleShort / GetLittleLong / FindNextChunk / FindChunk / DumpChunks / GetWavinfo | offline wav parsing | SUBSTITUTED | cue-chunk loopstart survives as the region `ls` field | — (substitution; verify justification still holds) |

## snd_mix.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| (entire file: S_PaintChannels, S_TransferPaintBuffer, SND_PaintChannelFrom8/16, scale tables) | — | SUBSTITUTED | no runtime PCM access on Roblox; the engine mixes Sound instances (FIDELITY audio substitution) | — (substitution; verify justification still holds) |

## r_main.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_Init / R_InitTurb | worldmesh/textures init | SUBSTITUTED | software init; turb warp lives in textures.writeTurbFrame | — (substitution; verify justification still holds) |
| R_NewMap | onServerInfo world build (worldmesh.build, deferred one Heartbeat) | VERIFIED | tests/test_loopback.luau + test_changelevel.luau world loads; rebuild-starvation fix (user playtest "black square"): 4-rebuild gauntlet leaves 61 world parts + animated style-10 alcove region, flicker pair committed ([evidence/nq-e1m1-flicker-bright.jpg](evidence/nq-e1m1-flicker-bright.jpg), [-dark.jpg](evidence/nq-e1m1-flicker-dark.jpg), [.txt](evidence/nq-e1m1-flicker.txt)) | `lune run tests/test_changelevel.luau`; Studio: tools/verify_meshbudget.luau gauntlet prints PASS |
| R_SetVrect / R_ViewChanged | — | SUBSTITUTED | no software viewport | — (substitution; verify justification still holds) |
| R_MarkLeaves | — | UNIMPLEMENTED | no PVS culling — whole map stays resident; GPU frustum-culls (perf, not correctness) | — (implement first) |
| R_DrawEntitiesOnList | heartbeat entity update loop | PENDING | statics re-posed every frame like C (FIDELITY torch record covers the static case) | TBD: write test or tools/verify script + evidence capture |
| R_DrawViewModel | gun entity branch | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: light floor 24; hidden when dead/intermission/chase like C | TBD: write test or tools/verify script + evidence capture |
| R_BmodelCheckBBox | — | SUBSTITUTED | no per-frame brush accept/reject needed | — (substitution; verify justification still holds) |
| R_DrawBEntitiesOnList | entrender.updateBrush | SUBSTITUTED | brush ents are cloned Models moved by CFrame; delta: no rotation support (id1 unused) | — (substitution; verify justification still holds) |
| R_EdgeDrawing / R_RenderView_ / R_RenderView | camera CFrame + Roblox render | SUBSTITUTED | rasterization replaced wholesale | — (substitution; verify justification still holds) |

## r_alias.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_AliasCheckBBox | — | SUBSTITUTED | GPU culls | — (substitution; verify justification still holds) |
| R_AliasTransformVector / R_AliasPreparePoints / R_AliasSetUpTransform / R_AliasTransformFinalVert / R_AliasTransformAndProjectFinalVerts / R_AliasProjectFinalVert / R_AliasPrepareUnclippedPoints | EditableMesh verts + part CFrame | SUBSTITUTED | per-vertex transform/project replaced by mesh + CFrame (pitch negated like C entity-angle convention) | — (substitution; verify justification still holds) |
| R_AliasSetupSkin | updateAlias skin select + player translation | PENDING | delta: skingroup intervals not timed (first group frame used) | TBD: write test or tools/verify script + evidence capture |
| R_AliasSetupLighting | lightpoint sample + dlight falloff add | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: entity lighting picks up dlight falloff like R_AliasSetupLighting | TBD: write test or tools/verify script + evidence capture |
| R_AliasSetupFrame | entrender aliasFrame (framegroup by time+syncbase) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: static framegroup animation (flame.mdl) live-confirmed | TBD: write test or tools/verify script + evidence capture |
| R_AliasDrawModel | entrender.updateAlias | PENDING | delta: fullbright-skin models render unlit (per-pixel colormap fullbrights inexpressible — FIDELITY substitution) | TBD: write test or tools/verify script + evidence capture |

## r_bsp.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_EntityRotate / R_RotateBmodel | — | SUBSTITUTED | brush entity transform is a CFrame | — (substitution; verify justification still holds) |
| R_RecursiveClipBPoly / R_DrawSolidClippedSubmodelPolygons / R_DrawSubmodelPolygons | — | SUBSTITUTED | no per-frame world clipping of submodels | — (substitution; verify justification still holds) |
| R_RecursiveWorldNode / R_RenderWorld | worldmesh.build (once per map) | SUBSTITUTED | front-to-back traversal replaced by prebuilt per-texture MeshParts | — (substitution; verify justification still holds) |

## r_draw.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_EmitEdge / R_ClipEdge / R_EmitCachedEdge / R_RenderFace / R_RenderBmodelFace / R_RenderPoly / R_ZDrawSubmodelPolys | — | SUBSTITUTED | edge emission/clipping is the software rasterizer; GPU renders the prebuilt meshes | — (substitution; verify justification still holds) |

## r_edge.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_DrawCulledPolys / R_BeginEdgeFrame / R_InsertNewEdges / R_RemoveEdges / R_StepActiveU / R_CleanupSpan / R_LeadingEdgeBackwards / R_TrailingEdge / R_LeadingEdge / R_GenerateSpans / R_GenerateSpansBackward / R_ScanEdges | — | SUBSTITUTED | active-edge-table span generation replaced wholesale by GPU rasterization | — (substitution; verify justification still holds) |

## r_efrag.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_RemoveEfrags / R_SplitEntityOnNode / R_SplitEntityOnNode2 / R_AddEfrags / R_StoreEfrags | — | SUBSTITUTED | efrag leaf-linking exists to feed PVS visibility; statics are persistent Instances always rendered | — (substitution; verify justification still holds) |

## r_light.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_AnimateLight | 10Hz styleFrame tick in init.client | PENDING | (c-'a')*22 exactly; empty style = 256 ("m"=264 base) | TBD: write test or tools/verify script + evidence capture |
| R_MarkLights | lightatlas markLights | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: floor surfaces around the impact marked and re-lit. | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| R_PushDlights | lightatlas.updateDlights | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: the per-frame dlight push drives the marked-region rebake. | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| RecursiveLightPoint | lightpoint.luau recursiveLightPoint | PENDING | faithful structure incl. mid-plane split and style-layer sum >>8 | TBD: write test or tools/verify script + evidence capture |
| R_LightPoint | lightpoint.at | PENDING | -2048 downward trace, fullbright when no lightdata; dlight add lives in caller like C | TBD: write test or tools/verify script + evidence capture |

## r_misc.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_CheckVariables / Show / R_TimeRefresh_f / R_LineGraph / R_TimeGraph / R_PrintTimes / R_PrintDSpeeds / R_PrintAliasStats | — | UNIMPLEMENTED | developer profiling/graph tools | — (implement first) |
| WarpPalette | — | SUBSTITUTED | no palette; underwater cshift handled by V_SetContentsColor tint | — (substitution; verify justification still holds) |
| R_TransformFrustum / TransformVector / R_TransformPlane / R_SetUpFrustumIndexes | — | SUBSTITUTED | GPU frustum | — (substitution; verify justification still holds) |
| R_SetupFrame | heartbeat refdef + diag attributes | SUBSTITUTED | per-frame software state replaced by camera CFrame set | — (substitution; verify justification still holds) |

## r_part.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_InitParticles | particles.new pool | SUBSTITUTED | Pool is 1024 round-robin (oldest slot stolen) vs C's 2048 free-list that truncates effects when exhausted; pooled neon Parts are a platform substitution. Expiry: raise the pool / adopt free-list truncation if particle-heavy scenes visibly steal live particles. | code: particlesim.new/alloc; spawner behaviour under load exercised by test_particles2 |
| R_DarkFieldParticles | — | UNIMPLEMENTED | dead code in WinQuake (QUAKE2 #ifdef) — justified omission | — (implement first) |
| R_EntityParticles | particles.entityParticles (renders the verified particlesim core) | VERIFIED | test_particles2: 162 anorm particles, color 0x6f, die +0.01, orgs on the 64±16 shell (real anorms.h table). | `lune run tests/test_particles2.luau` |
| R_ClearParticles | — | UNIMPLEMENTED | no explicit clear on map change; particles age out by die time (masks it) | — (implement first) |
| R_ReadPointFile_f | — | UNIMPLEMENTED | dev leak-hunting tool | — (implement first) |
| R_ParseParticleEffect | cl.luau svc_particle → particles.runEffect | VERIFIED | test_particles2 wire-parse battery: org coords, dir chars * 1/16, color byte, plain count pass-through, and the 255→1024 rocket-explosion escape. FIDELITY FIX 2026-07-04: the escape was MISSING (255 spawned 255 slowgrav sparks instead of a 1024-particle explosion); now applied in cl.luau exactly where C does it. | `lune run tests/test_particles2.luau` |
| R_ParticleExplosion | particles.explosion | VERIFIED | test_particles2 explosion battery: 1024 particles, 512/512 pt_explode/pt_explode2 on i&1, color ramp1[0]=0x6f, die +5, ramp rand&3, org ±16, vel ±256. Noted delta: C interleaves org/vel rand() draws per axis, port draws org's three then vel's three (same distribution). | `lune run tests/test_particles2.luau` |
| R_ParticleExplosion2 | particlesim.particleExplosion2 | VERIFIED | tests/test_particles2.luau: 512 particles, color colorStart+(i%colorLength), die +0.3, all pt_blob, ±16 org / ±256 vel | `lune run tests/test_particles2.luau` |
| R_BlobExplosion | particlesim.blobExplosion | VERIFIED | tests/test_particles2.luau: 1024 particles, 512 pt_blob (66+rand%6) / 512 pt_blob2 (150+rand%6), die 1+(rand&8)*0.05, pt_blob/pt_blob2 update physics checked | `lune run tests/test_particles2.luau` |
| R_RunParticleEffect | particles.runEffect | VERIFIED | test_particles2 runEffect battery: die 0.1*(rand%5), color (c&~7)+(rand&7), pt_slowgrav, org ±8, vel dir*15 exact, and the count==1024 rocket-explosion branch fields. | `lune run tests/test_particles2.luau` |
| R_LavaSplash | particles.lavaSplash | VERIFIED | test_particles2 lavaSplash battery: full 32x32 grid, color 224+(rand&7), die 2..2.62, pt_slowgrav, grid org offsets, normalized dir with z=256 dominant, speeds 50..113. | `lune run tests/test_particles2.luau` |
| R_TeleportSplash | particles.teleportSplash (renders the verified particlesim core) | VERIFIED | test_particles2: full 896-particle grid, colors 7..14, die window, speeds 50..113, zero-dir center particle zero-vel (a stale-pool-velocity divergence vs C VectorNormalize found and fixed 2026-07-04). | `lune run tests/test_particles2.luau` |
| R_RocketTrail | particles.rocketTrail (renders the verified particlesim core) | VERIFIED | test_particles2: type 0 — 30 particles for len 90, ramp3 colors {0x6d,0x6b,6,5}, die +2, orgs hugging the first third of the segment (the authentic start+=normalized-vec quirk). Other trail types share the loop; tracer/blood branches structurally identical. | `lune run tests/test_particles2.luau` |
| R_DrawParticles | particles.update | VERIFIED | test_particles2 physics batteries: pt_blob/pt_blob2 (dvel accel/drag + grav), pt_explode ramp1@time2 + dvel accel, pt_explode2 ramp2@time3 + frametime drag, pt_grav/pt_slowgrav plain grav, expiry. FIDELITY FIX 2026-07-04: pt_grav used the QUAKE2-only grav*20 — stock WinQuake falls through to pt_slowgrav and QW writes plain grav; blood fell 20x too fast. Rendering substitution stands: 0.25-stud neon cubes vs 1px span dots. | `lune run tests/test_particles2.luau` |

## r_sky.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_InitSky | writeSkyFrame layer split (left=front masked on 0, right=back) | PENDING | 256x128 two-half layout honoured | TBD: write test or tools/verify script + evidence capture |
| R_MakeSky | textures.writeSkyFrame per 10Hz tick | PENDING | delta: scroll speeds time*16 front / time*8 back; drawn on world sky polys via UVs, not screen-space projection | TBD: write test or tools/verify script + evidence capture |
| R_GenSkyTile / R_GenSkyTile16 | — | SUBSTITUTED | tile compositing into the surface cache; EditableImage rewrite replaces it | — (substitution; verify justification still holds) |
| R_SetSkyFrame | time captured per rewrite | SUBSTITUTED | | — (substitution; verify justification still holds) |

## r_sprite.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_RotateSprite / R_ClipSpriteFace / R_SetupAndDrawSprite | BillboardGui | SUBSTITUTED | sprite polygon build/clip replaced by billboard | — (substitution; verify justification still holds) |
| R_GetSpriteframe | updateSprite frame index | PENDING | delta: sprite-group intervals not timed — first group frame used | TBD: write test or tools/verify script + evidence capture |
| R_DrawSprite | entrender.updateSprite | PENDING | delta: always camera-facing; SPR_* orientation types (upright/oriented) not honoured | TBD: write test or tools/verify script + evidence capture |

## r_surf.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_AddDynamicLights | lightatlas addDynamicLights | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: the radial falloff is visible across the floor texels around the impact. | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| R_BuildLightMap | lightatlas.writeRegion | VERIFIED | [evidence/nq-explosion-dlight.jpg](evidence/nq-explosion-dlight.jpg) + [decayed pair](evidence/nq-explosion-decayed.jpg) + .txt: the atlas region rewrites under the flash and restores after decay (static lava tiles unchanged in both frames). | Pause-freeze procedure per evidence/nq-explosion-dlight.txt, capture pair, compare |
| R_TextureAnimation | init.client wall-anim tick + worldmesh "wall" TextureAnims | PENDING | tests/test_texanim.luau proves the +N/+a chain data and the anim_min/anim_max walk math on e1m2/start; base chain only (world frame 0), swaps chunk TextureContent between prebuilt frame images — visual confirmation pending | TBD: write test or tools/verify script + evidence capture |
| R_DrawSurface / R_DrawSurfaceBlock8_mip0-3 / R_DrawSurfaceBlock16 | — | SUBSTITUTED | surface-cache block drawing; GPU samples texture × lightmap overlay instead | — (substitution; verify justification still holds) |
| R_GenTurbTile / R_GenTurbTile16 | textures.writeTurbFrame | PENDING | 8px sine displacement both axes, period 32, speed time*2 — software look approximated in texture space | TBD: write test or tools/verify script + evidence capture |
| R_GenTile | — | SUBSTITUTED | | — (substitution; verify justification still holds) |

## r_aclip.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| R_Alias_clip_z/left/right/top/bottom / R_AliasClip / R_AliasClipTriangle | — | SUBSTITUTED | near/screen-edge triangle clipping is the GPU's job | — (substitution; verify justification still holds) |

## r_vars.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| (global refresh variables only, no functions) | — | SUBSTITUTED | state lives in module locals | — (substitution; verify justification still holds) |

## d_*.c rasterizer group (one row per file)

| File | Port | Status | Evidence / Delta |
|---|---|---|---|---|
| d_edge.c | — | SUBSTITUTED | span/edge surface emission — GPU rasterizes | — (substitution; verify justification still holds) |
| d_fill.c | — | SUBSTITUTED | screen rect fill | — (substitution; verify justification still holds) |
| d_init.c | — | SUBSTITUTED | rasterizer setup | — (substitution; verify justification still holds) |
| d_modech.c | — | SUBSTITUTED | video mode changes N/A | — (substitution; verify justification still holds) |
| d_part.c | — | SUBSTITUTED | particle pixel/z drawing; particle BEHAVIOR is ported in particles.luau (see r_part.c rows) | — (substitution; verify justification still holds) |
| d_polyse.c | — | SUBSTITUTED | alias triangle span rasterization | — (substitution; verify justification still holds) |
| d_scan.c | — | SUBSTITUTED | span texture mapping; D_DrawTurbulent's water warp OUTPUT reproduced by textures.writeTurbFrame; D_WarpScreen (underwater full-screen warp) NOT reproduced — FIDELITY open item, no screen-space shader access | — (substitution; verify justification still holds) |
| d_sky.c | — | SUBSTITUTED | screen-space sky span projection; scrolling two-layer sky OUTPUT reproduced by textures.writeSkyFrame | — (substitution; verify justification still holds) |
| d_sprite.c | — | SUBSTITUTED | sprite span rasterization | — (substitution; verify justification still holds) |
| d_surf.c | — | SUBSTITUTED | surface cache management; lighting OUTPUT reproduced by lightatlas.luau pages | — (substitution; verify justification still holds) |
| d_vars.c | — | SUBSTITUTED | rasterizer globals | — (substitution; verify justification still holds) |
| d_zpoint.c | — | SUBSTITUTED | z-buffered point drawing | — (substitution; verify justification still holds) |

## gl_*.c group (one row)

| Files | Port | Status | Evidence / Delta |
|---|---|---|---|---|
| gl_draw/gl_mesh/gl_model/gl_refrag/gl_rlight/gl_rmain/gl_rmisc/gl_rsurf/gl_screen/gl_test/gl_vid*/gl_warp.c | — | SUBSTITUTED | GLQuake is not the reference target (WinQuake software is canon); the EditableMesh approach merely resembles GL's geometry path — no gl_* code was ported | — (substitution; verify justification still holds) |

## Port-side additions with no C counterpart

| Addition | Where | Justification |
|---|---|---|---|
| rq_need asset streaming (demandFile) | init.client.luau | client bundle publishes pak files on demand; documented in FIDELITY.md demo record |
| QuakeClientFS ready-gate + engine="qw" boot switch | init.client.luau top | server-published bundle must replicate before boot; per-place engine selection (commit b98aa9a "Studio wiring") |
| RQDBG_Console BindableFunction | init.client.luau | code comment: "debug hook: drive the console remotely (verification without keypresses)" |
| RQ_* workspace diagnostic attributes (Signon/Time/Health/Shells/VisEnts/Origin) | init.client.luau frame loop | code comment: "diagnostics for external verification" |
| RQ_LightTick attribute | init.client.luau lightstyle tick | no explicit comment; consistent with the RQ_* verification-attribute family (weak justification) |
| RQ_Force* input override attributes | input.luau sample() | code comment: "scripted-test hooks (verification harness drives the real input path)" |
| WASD/E/C/M autoexec bind layer | init.client.luau | FIDELITY.md: modern layout applied via the authentic autoexec mechanism after 1996 default.cfg |
| crosshair default 1, always-mouselook, notify below topbar inset, TAB dual player-list | various | FIDELITY.md "Deliberate default changes" section |
| soundbank PreloadAsync warm + one-shot GC delay timers | sound.luau | code comments: first shot latency; regions misreport Ended while streaming |
| missing-region warn set | sound.luau | diagnostics for incomplete soundbanks (warn once per sample) |
| liveMeshes retention + synchronous destroyBuild release (Destroying hook is only a backstop) | worldmesh.luau | code comment: Destroying signals are deferred, so same-frame rebuilds starved the EditableMesh budget into skipped batches — the e1m1 "black square" playtest bug; evidence/nq-e1m1-flicker.txt |
| level teardown destroys brush templates, RenderEnt alias meshes, beam pool, gun ent; world build deferred one Heartbeat (worldBuildGen guard) | init.client.luau onServerInfo / entrender.destroy | same bug: templates were unparented (no Destroying ever fired) and re.em was never freed, leaking a mesh per entity per map change; verify via tools/verify_meshbudget.luau |
| RQDBG_Atlas probe (region/alpha/rewrite by lightofs) + worldmesh._debug | init.client.luau / worldmesh.luau | debug hook family (RQDBG_Console twin): execute_luau runs in a separate VM and cannot reach live module state; used by tools/verify_meshbudget.luau |
| dynamic→FixedSize EditableMesh copy dance | worldmesh.luau / entrender.luau | code comment: dynamic meshes reserve the 60k-vertex max against the memory budget |
| MAX_BATCH_VERTS chunking, 1px lightmap gutters, epsilon transparency (0.02) | worldmesh.luau / lightatlas.luau | platform constraints: 60k mesh cap, bilinear bleed, translucent-queue per-texel alpha (comments in both files) |
| aliasbox / buildWedges fallback renderers | entrender.luau / worldmesh.luau | graceful degradation when Mesh & Image APIs are disabled (textures.canUseMeshApi warn) |
| demoBusy re-entry guard | init.client.luau demoFrame | code comment: world build yields while a demo message is mid-parse (FIDELITY demo record) |
| CPU page mirrors + flushPages batching | lightatlas.luau | FIDELITY.md: atlas writes batched, map-load stall fixed |

## Totals

- Rows: 264 (grouped stub/family rows counted once; d_* group = 12 rows, gl_* group = 1 row)
- VERIFIED: 66
- PENDING: 68
- UNIMPLEMENTED: 62
- SUBSTITUTED: 68
- Port-side additions: 18 (all justified; RQ_LightTick has only a weak/implied justification)

> Evidence reset 2026-07-04: VERIFIED now means re-runnable evidence only (a cited test/harness). 45 rows demoted to PENDING with their prior claims preserved inline (marked DEMOTED); re-earn via tests or checked-in screenshots under docs/coverage/evidence/.
