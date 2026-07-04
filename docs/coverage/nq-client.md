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
| CL_AllocDlight | init.client allocDlight | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md "cl_dlights ported" (fixed-during-audit record); delta: grows table to 32 then overwrites slot 1 vs C fixed-array scan | TBD: write test or tools/verify script + evidence capture |
| CL_DecayLights | heartbeat decay pass | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md dlights record; radius -= dt*decay, die-gated, same as C | TBD: write test or tools/verify script + evidence capture |
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
| CL_ParseStatic | cl.luau parseStatic + statics spawn pass | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: static framegroup animation fix (torches) live-confirmed | TBD: write test or tools/verify script + evidence capture |
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
| CL_StopPlayback | init.client stopDemo | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md demo record (fixed during audit) | TBD: write test or tools/verify script + evidence capture |
| CL_WriteDemoMessage | record branch in heartbeat pump | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: length/viewangles/payload block format, replayable | TBD: write test or tools/verify script + evidence capture |
| CL_GetMessage (demo path) | init.client demoFrame with mtime pacing | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: demo1.dem plays e1m3 end to end | TBD: write test or tools/verify script + evidence capture |
| CL_Stop_f | `stop` command | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md demo record; delta: demo stored in memory, not a file | TBD: write test or tools/verify script + evidence capture |
| CL_Record_f | `record` command | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md; delta: name-only (no map/cdtrack args), forced "-1\n" track line | TBD: write test or tools/verify script + evidence capture |
| CL_PlayDemo_f | `playdemo` command | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md; assets stream via rq_need | TBD: write test or tools/verify script + evidence capture |
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
| Chase_Update | init.client chase branch | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: "chase.c verbatim ... no camera wall clip — authentic quirk" | TBD: write test or tools/verify script + evidence capture |

## view.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| V_CalcRoll | view.luau calcRoll | PENDING | cl_rollangle 2 / cl_rollspeed 200 hardcoded | TBD: write test or tools/verify script + evidence capture |
| V_CalcBob | view.luau calcBob | PENDING | cycle/bobup/clamp -7..4 match C | TBD: write test or tools/verify script + evidence capture |
| V_StartPitchDrift | — | UNIMPLEMENTED | always-mouselook: C disables drift under mouselook anyway | — (implement first) |
| V_StopPitchDrift | — | UNIMPLEMENTED | as above | — (implement first) |
| V_DriftPitch | — | UNIMPLEMENTED | as above; idealpitch received but unused | — (implement first) |
| BuildGammaTable | — | SUBSTITUTED | no palette; gamma folded into the ^0.7 light curve | — (substitution; verify justification still holds) |
| V_CheckGamma | — | SUBSTITUTED | as above | — (substitution; verify justification still holds) |
| V_ParseDamage | cl.luau parseDamage | PENDING | kick roll/pitch *0.6, kicktime 0.5, cshift color table, faceanimtime +0.2 all match | TBD: write test or tools/verify script + evidence capture |
| V_cshift_f | — | UNIMPLEMENTED | debug command | — (implement first) |
| V_BonusFlash_f | "bf" stufftext → cshift_bonus_percent 50 | PENDING | bonus color 215/186/69 matches | TBD: write test or tools/verify script + evidence capture |
| V_SetContentsColor | init.client view-leaf contents shifts | PENDING | water/slime/lava values match; delta: no CONTENTS_SOLID case, empty clears implicitly | TBD: write test or tools/verify script + evidence capture |
| V_CalcPowerupCshift | init.client powerup shifts | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: priority quad > suit > ring > pent matches | TBD: write test or tools/verify script + evidence capture |
| V_CalcBlend | init.client shift compositor | PENDING | same a2/(1-a) accumulation; delta: final alpha capped at 0.85 | TBD: write test or tools/verify script + evidence capture |
| V_UpdatePalette | cshift Frame tint + decay | SUBSTITUTED | palette blend → fullscreen GUI tint; damage/bonus decay 150/100 per second ported | — (substitution; verify justification still holds) |
| angledelta / CalcGunAngle | gunangles = (-pitch, yaw, 0) | PENDING | delta: no yaw/pitch damped-lag smoothing — gun locked to view | TBD: write test or tools/verify script + evidence capture |
| V_BoundOffsets | — | UNIMPLEMENTED | scr_ofsx/y/z not supported | — (implement first) |
| V_AddIdle | — | UNIMPLEMENTED | v_idlescale defaults 0 in C; constant kept but unused | — (implement first) |
| V_CalcViewRoll | folded into view.calcRefdef | PENDING | dead roll 80 kept; delta: no v_centermove interaction | TBD: write test or tools/verify script + evidence capture |
| V_CalcIntermissionRefdef | — | UNIMPLEMENTED | intermission uses the normal refdef; no idle sway, gun hidden instead | — (implement first) |
| V_CalcRefdef | view.calcRefdef | PENDING | 1/32 nudge, bob, punchangle, stair smoothing (80/s, 12 cap) match; deltas: no pitch drift, no scr_ofs, no viewsize gun-z fudge, player ent angles not forced to view | TBD: write test or tools/verify script + evidence capture |
| V_RenderView | heartbeat camera CFrame + crosshair label | PENDING | crosshair '+' conchars glyph like the C Draw_Character call; defaults ON (recorded divergence) | TBD: write test or tools/verify script + evidence capture |
| V_Init | constants in view.luau/init.client | SUBSTITUTED | no cvar system; defaults baked in | — (substitution; verify justification still holds) |

## sbar.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Sbar_ShowScores / Sbar_DontShowScores | +/-showscores → hud.setShowScores | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: TAB +showscores record | TBD: write test or tools/verify script + evidence capture |
| Sbar_Changed | — | SUBSTITUTED | retained GUI; no dirty-region repaint needed | — (substitution; verify justification still holds) |
| Sbar_Init | hud.create (wad pics cached lazily) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawPic / Sbar_DrawTransPic | setPic → ImageLabel | SUBSTITUTED | framebuffer blit → ImageLabel; index 255 transparent | — (substitution; verify justification still holds) |
| Sbar_DrawCharacter / Sbar_DrawString | confont rows | SUBSTITUTED | conchars glyph labels | — (substitution; verify justification still holds) |
| Sbar_itoa | string.format | SUBSTITUTED | trivial | — (substitution; verify justification still holds) |
| Sbar_DrawNum | hud drawNum | PENDING | right-justified 24px slots, anum_ red variant, last-3-digit clip match | TBD: write test or tools/verify script + evidence capture |
| Sbar_SortFrags | buildRankings sort | PENDING | delta: skips empty names then sorts by frags (C insertion sort, same order) | TBD: write test or tools/verify script + evidence capture |
| Sbar_UpdateScoreboard | sig-string rebuild in updateOverlays | SUBSTITUTED | rebuild-on-change replaces per-frame scratch build | — (substitution; verify justification still holds) |
| Sbar_SoloScoreboard | hud soloRows | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: monsters/secrets/time/level over status row, shown when dead, scorebar.lmp backdrop | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawScoreboard | updateOverlays dispatch | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawInventory | weapon icons + flash + counts + items + sigils | PENDING | flashon formula ((time-gettime)*10, %5+2, inv2_ active) matches; counts as conchars 18+digit | TBD: write test or tools/verify script + evidence capture |
| Sbar_DrawFrags | — | UNIMPLEMENTED | in-sbar DM frag cells (4 players) not drawn | — (implement first) |
| Sbar_DrawFace | hud face branch | PENDING | invis+invuln/quad/invis/invuln specials + 5 health bands + pain via faceanimtime match | TBD: write test or tools/verify script + evidence capture |
| Sbar_Draw | hud.update | PENDING | delta: no viewsize/lineadj interaction — sbar always drawn | TBD: write test or tools/verify script + evidence capture |
| Sbar_IntermissionNumber | interBigNum | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: big digits at exact C coordinates | TBD: write test or tools/verify script + evidence capture |
| Sbar_DeathmatchOverlay | buildRankings | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: ranking.lmp, colour bars, frags, self marker char 12 | TBD: write test or tools/verify script + evidence capture |
| Sbar_MiniDeathmatchOverlay | — | UNIMPLEMENTED | small mid-game DM list absent | — (implement first) |
| Sbar_IntermissionOverlay | buildIntermission | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: complete.lmp/inter.lmp, time/secrets/monsters at C coords | TBD: write test or tools/verify script + evidence capture |
| Sbar_FinaleOverlay | finale.lmp branch | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md finale record | TBD: write test or tools/verify script + evidence capture |

## screen.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SCR_CenterPrint | hud.centerPrint | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: centerprints in conchars with faithful metrics (0.35h block, per-line centering) | TBD: write test or tools/verify script + evidence capture |
| SCR_EraseCenterString | retained GUI | SUBSTITUTED | no framebuffer erase needed | — (substitution; verify justification still holds) |
| SCR_DrawCenterString | hud.centerPrint rows + finale typewriter | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: finale typewriter at scr_printspeed | TBD: write test or tools/verify script + evidence capture |
| SCR_CheckDrawCenterString | centerTime gate in hud.update | PENDING | scr_centertime 2s; stays up during intermission like C | TBD: write test or tools/verify script + evidence capture |
| CalcFov | qcoords.calcFovY | PENDING | delta: horizontal fov converted to vertical at the real viewport aspect (Roblox FOV is vertical) | TBD: write test or tools/verify script + evidence capture |
| SCR_CalcRefdef | qcoords.vrect (both boots) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Same vrect implementation as QW (see qw-client.md): fov from window-minus-sbar, view model rotated to the vrect bottom anchor. Live-measured muzzle 83% vs sbar 86% + screenshot (dm3, gun visible above HUD). | TBD: write test or tools/verify script + evidence capture |
| SCR_SizeUp_f / SCR_SizeDown_f | accepted no-op commands | UNIMPLEMENTED | viewsize fixed | — (implement first) |
| SCR_Init | init.client GUI setup | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SCR_DrawRam / SCR_DrawTurtle / SCR_DrawNet | — | UNIMPLEMENTED | perf/lag indicator icons absent | — (implement first) |
| SCR_DrawPause | hud pausePlaque | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md pause plaque record | TBD: write test or tools/verify script + evidence capture |
| SCR_DrawLoading / SCR_BeginLoadingPlaque / SCR_EndLoadingPlaque | hud.setLoading + loadingUp gate | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: notify/centerprint clear, plaque holds until first rendered frame | TBD: write test or tools/verify script + evidence capture |
| SCR_SetUpToDrawConsole | console.update slide | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: console slide animation (scr_conspeed 300 ≙ 1.5 heights/s) | TBD: write test or tools/verify script + evidence capture |
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
| Con_ToggleConsole_f | console.toggle (backquote/tilde) | PENDING | mouse unlock while open; delta: no Key_ClearStates/togglemenu interplay | TBD: write test or tools/verify script + evidence capture |
| Con_Clear_f | `clear` command | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Con_ClearNotify | hud.setLoading clears notifyLines | PENDING | | TBD: write test or tools/verify script + evidence capture |
| Con_MessageMode_f / Con_MessageMode2_f | stub print | UNIMPLEMENTED | pointed at `say`/Roblox chat | — (implement first) |
| Con_CheckResize | — | SUBSTITUTED | fixed 64-column virtual canvas | — (substitution; verify justification still holds) |
| Con_Init | console.create | PENDING | conback drawn like Draw_ConsoleBackground | TBD: write test or tools/verify script + evidence capture |
| Con_Linefeed | implicit in print | SUBSTITUTED | | — (substitution; verify justification still holds) |
| Con_Print | console.print | PENDING | delta: hard wrap at 64 cols (no word-boundary wrap), 200-line scrollback vs 16K text buffer, no cr handling | TBD: write test or tools/verify script + evidence capture |
| Con_DebugLog | — | UNIMPLEMENTED | | — (implement first) |
| Con_Printf | c.print → console + notify + output | PENDING | delta: no rcon/server redirect concerns client-side | TBD: write test or tools/verify script + evidence capture |
| Con_DPrintf | plain print() | UNIMPLEMENTED | no developer cvar gate | — (implement first) |
| Con_SafePrintf | — | UNIMPLEMENTED | no screen-disable variant needed | — (implement first) |
| Con_DrawInput | input row + blinking char-11 cursor | PENDING | ] prompt kept; delta: no horizontal scroll of long input | TBD: write test or tools/verify script + evidence capture |
| Con_DrawNotify | hud notifyRows (4 lines, 3s) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: notify in conchars, faithful metrics; recorded divergence: sits below Roblox topbar inset | TBD: write test or tools/verify script + evidence capture |
| Con_DrawConsole | console.update | PENDING | delta: no scrollback paging, no version string | TBD: write test or tools/verify script + evidence capture |
| Con_NotifyBox | — | UNIMPLEMENTED | | — (implement first) |

## keys.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Key_Console | console.handleKey/handleText | PENDING | enter/backspace/up/down history; delta: no tab completion, no pgup/pgdn scrollback, no clipboard paste | TBD: write test or tools/verify script + evidence capture |
| Key_Message | — | UNIMPLEMENTED | chat via Roblox | — (implement first) |
| Key_StringToKeynum / Key_KeynumToString | KEYNAMES map | PENDING | delta: Roblox KeyCodes; Escape reserved by platform (menu on M), mouse1-3 mapped | TBD: write test or tools/verify script + evidence capture |
| Key_SetBinding | bindings table | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md keys.c record + "F11 zoom chain" | TBD: write test or tools/verify script + evidence capture |
| Key_Unbind_f / Key_Unbindall_f / Key_Bind_f | bind/unbind/unbindall commands | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: full bind system record | TBD: write test or tools/verify script + evidence capture |
| Key_WriteBindings | — | UNIMPLEMENTED | no config.cfg persistence (FIDELITY platform substitution; DataStore later) | — (implement first) |
| Key_Init | default.cfg exec at boot + autoexec layer | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: shipped default.cfg execs at boot, quake.rc ordering | TBD: write test or tools/verify script + evidence capture |
| Key_Event | init.client keyEvent via UserInputService | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: keyups fire the -command; W→forwardmove chain | TBD: write test or tools/verify script + evidence capture |
| Key_ClearStates | input.setEnabled(false) clears buttons | PENDING | cleared when console/menu opens | TBD: write test or tools/verify script + evidence capture |

## menu.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| M_DrawCharacter / M_Print / M_PrintWhite | — | SUBSTITUTED | implemented menus are pure .lmp pics; no text menus yet | — (substitution; verify justification still holds) |
| M_DrawTransPic / M_DrawPic | menu.addPic → ImageLabel | SUBSTITUTED | blit → ImageLabel | — (substitution; verify justification still holds) |
| M_BuildTranslationTable / M_DrawTransPicTranslate | — | UNIMPLEMENTED | player setup menu absent (textures.translatePixels exists for in-game skins) | — (implement first) |
| M_DrawTextBox | — | UNIMPLEMENTED | | — (implement first) |
| M_ToggleMenu_f | `togglemenu` / M key | PENDING | recorded divergence: Escape reserved by Roblox | TBD: write test or tools/verify script + evidence capture |
| M_Menu_Main_f / M_Main_Draw / M_Main_Key | menu.create/update/handleKey | PENDING | qplaque(16,4) + ttl_main centered + mainmenu(72,32) + menudot anim (time*10)%6 at (54,32+cursor*20) match | TBD: write test or tools/verify script + evidence capture |
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
| Draw_Character / Draw_String | confont glyph labels (color 0 transparent) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: conchars with faithful metrics; high-bit bronze glyphs pass through | TBD: write test or tools/verify script + evidence capture |
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
| S_StartSound | sound.start | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: channel override semantics on entity sounds record | TBD: write test or tools/verify script + evidence capture |
| S_StopSound | sound.stop exists but is never called | UNIMPLEMENTED | svc_stopsound is parsed and discarded in cl.luau — looped entity sounds can't be stopped | — (implement first) |
| S_StopAllSounds | sound.clear on serverinfo | PENDING | | TBD: write test or tools/verify script + evidence capture |
| S_ClearBuffer | — | SUBSTITUTED | no mix buffer | — (substitution; verify justification still holds) |
| S_StaticSound | sound.static (looped, vol/255, atten/64) | PENDING | event delivery proven (see CL_ParseStaticSound); playback itself unproven | TBD: write test or tools/verify script + evidence capture |
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
| R_NewMap | onServerInfo world build (worldmesh.build) | VERIFIED | tests/test_loopback.luau + test_changelevel.luau world loads; FIDELITY teardown fix | `lune run tests/test_changelevel.luau`; `lune run tests/test_loopback.luau` |
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
| R_MarkLights | lightatlas markLights | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md per-texel lightmaps record; same node recursion + dlightbits | TBD: write test or tools/verify script + evidence capture |
| R_PushDlights | lightatlas.updateDlights | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md; delta: also rebakes last-frame-lit regions so dead lights clear | TBD: write test or tools/verify script + evidence capture |
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
| R_InitParticles | particles.new pool | PENDING | delta: pool 1024 vs C default 2048 (-particles switch absent); pooled neon Parts | TBD: write test or tools/verify script + evidence capture |
| R_DarkFieldParticles | — | UNIMPLEMENTED | dead code in WinQuake (QUAKE2 #ifdef) — justified omission | — (implement first) |
| R_EntityParticles | particles.entityParticles | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: EF_BRIGHTFIELD with the real anorms.h table (162 normals present) | TBD: write test or tools/verify script + evidence capture |
| R_ClearParticles | — | UNIMPLEMENTED | no explicit clear on map change; particles age out by die time (masks it) | — (implement first) |
| R_ReadPointFile_f | — | UNIMPLEMENTED | dev leak-hunting tool | — (implement first) |
| R_ParseParticleEffect | cl.luau svc_particle → particles.runEffect | PENDING | dir/16, count 255→1024 explosion escape kept | TBD: write test or tools/verify script + evidence capture |
| R_ParticleExplosion | particles.explosion | PENDING | 1024 particles, ramp1, ±16 org / ±256 vel match | TBD: write test or tools/verify script + evidence capture |
| R_ParticleExplosion2 | particlesim.particleExplosion2 | VERIFIED | tests/test_particles2.luau: 512 particles, color colorStart+(i%colorLength), die +0.3, all pt_blob, ±16 org / ±256 vel | `lune run tests/test_particles2.luau` |
| R_BlobExplosion | particlesim.blobExplosion | VERIFIED | tests/test_particles2.luau: 1024 particles, 512 pt_blob (66+rand%6) / 512 pt_blob2 (150+rand%6), die 1+(rand&8)*0.05, pt_blob/pt_blob2 update physics checked | `lune run tests/test_particles2.luau` |
| R_RunParticleEffect | particles.runEffect | PENDING | color &~7 + rand&7, die 0.1*(rand%5), vel dir*15 match | TBD: write test or tools/verify script + evidence capture |
| R_LavaSplash | particles.lavaSplash | PENDING | 32x32 grid, color 224+&7, z 256 dir match | TBD: write test or tools/verify script + evidence capture |
| R_TeleportSplash | particles.teleportSplash | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md teleport splash implied by TE record; loops -16..12/-24..28 step 4 match | TBD: write test or tools/verify script + evidence capture |
| R_RocketTrail | particles.rocketTrail | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md: rocket/grenade/gib/tracer/voor trails record; all 7 types + tracercount parity | TBD: write test or tools/verify script + evidence capture |
| R_DrawParticles | particles.update | PENDING | physics (time1/2/3, grav, dvel, ramps) match; rendering delta: 0.25-stud neon cubes vs 1px span dots; z-buffer test free from GPU | TBD: write test or tools/verify script + evidence capture |

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
| R_AddDynamicLights | lightatlas addDynamicLights | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md per-texel lightmaps record; sd/td falloff formula exact | TBD: write test or tools/verify script + evidence capture |
| R_BuildLightMap | lightatlas.writeRegion | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): FIDELITY.md; 16-unit texels, style layers, blocklights sum; delta: alpha-overlay multiply + overbright x2 + gamma 0.7 instead of colormap | TBD: write test or tools/verify script + evidence capture |
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
| liveMeshes retention + Destroying destroy | worldmesh.luau | code comment: editable memory budget starved consecutive map builds (FIDELITY changelevel fix) |
| dynamic→FixedSize EditableMesh copy dance | worldmesh.luau / entrender.luau | code comment: dynamic meshes reserve the 60k-vertex max against the memory budget |
| MAX_BATCH_VERTS chunking, 1px lightmap gutters, epsilon transparency (0.02) | worldmesh.luau / lightatlas.luau | platform constraints: 60k mesh cap, bilinear bleed, translucent-queue per-texel alpha (comments in both files) |
| aliasbox / buildWedges fallback renderers | entrender.luau / worldmesh.luau | graceful degradation when Mesh & Image APIs are disabled (textures.canUseMeshApi warn) |
| demoBusy re-entry guard | init.client.luau demoFrame | code comment: world build yields while a demo message is mid-parse (FIDELITY demo record) |
| CPU page mirrors + flushPages batching | lightatlas.luau | FIDELITY.md: atlas writes batched, map-load stall fixed |

## Totals

- Rows: 264 (grouped stub/family rows counted once; d_* group = 12 rows, gl_* group = 1 row)
- VERIFIED: 59
- PENDING: 73
- UNIMPLEMENTED: 65
- SUBSTITUTED: 67
- Port-side additions: 16 (all justified; RQ_LightTick has only a weak/implied justification)

> Evidence reset 2026-07-04: VERIFIED now means re-runnable evidence only (a cited test/harness). 45 rows demoted to PENDING with their prior claims preserved inline (marked DEMOTED); re-earn via tests or checked-in screenshots under docs/coverage/evidence/.
