# QW client coverage

Function-level manifest for the QuakeWorld client portion of the port.
C reference: `reference/quake-c/QW/client/`. Port: `src/shared/engine/qw/qwcl.luau`,
`qwents.luau`, `qwnetchan.luau`, `pmove.luau`, `qwprotocol.luau`, and
`src/client/qwclient.luau` (presentation). Statuses:

- **VERIFIED** — cited offline test assert (`tests/test_qw_loopback.luau` = "loopback",
  `tests/test_qwents.luau` = "qwents", `tests/test_qw_pmove.luau` = "pmove-truth", which
  compares against the compiled verbatim C in `tools/pmove_truth.c`) or a recorded live
  Studio verification (memory/backlog entries of 2026-07-04: commits 547df88 QW-plays-live,
  115a438/9ecc594 audit gaps live-verified, 2ee4228 CalcFov).
- **PENDING** — implemented, no direct assert or recorded visual check of that behavior.
- **UNIMPLEMENTED** — no port-side counterpart.
- **SUBSTITUTED** — platform replaces the mechanism; justification given.

## cl_main.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_Quit_f | — | SUBSTITUTED | Roblox leave-game UI owns quitting; no client quit command. |
| CL_Version_f | — | UNIMPLEMENTED | Console command; QW console overlay is journaled follow-up. |
| CL_SendConnectPacket | `qwcl.connect` | SUBSTITUTED | No OOB challenge/qport/userinfo blob: Roblox remotes are per-player authenticated; server side takes userinfo via `qwsv.wireConnect`. `connect()` goes straight to `clc_stringcmd "new"`. |
| CL_CheckForResend | — | SUBSTITUTED | Reliable ordered transport; no connect resend timer. |
| CL_BeginServerConnect | `qwcl.connect` | SUBSTITUTED | One server per place; no address, no connect_time state. |
| CL_Connect_f | — | SUBSTITUTED | No server address to type; place boot connects automatically. |
| CL_Rcon_f | — | UNIMPLEMENTED | rcon has no meaning over place-local remotes. |
| CL_ClearState | `qwcl` `clearState` | PENDING | Wipes baselines/lightstyles/statics/precaches/models/frames per C; exercised on every `svc_serverdata` in loopback but not directly asserted. Adds `levelResets` renderer signal (see additions). |
| CL_Disconnect | partial (`svc_disconnect` handler) | PENDING | Sets `state="disconnected"` + `disconnected_reason`; no drop-cmd send, no demo/upload teardown (both N/A). qwclient heartbeat bails out when disconnected. |
| CL_Disconnect_f | — | UNIMPLEMENTED | No user-initiated disconnect command. |
| CL_User_f | — | UNIMPLEMENTED | Console command. |
| CL_Users_f | — | UNIMPLEMENTED | Console command; `cl.players` holds the data (name/frags/ping asserted in loopback). |
| CL_Color_f | — | UNIMPLEMENTED | Color userinfo setting; colormap skin translation journaled open. |
| CL_FullServerinfo_f | `execStufftext` `fullserverinfo` branch | PENDING | Parses quoted info string into `cl.serverinfo`; runs during every handshake in loopback, no direct assert. |
| CL_FullInfo_f | — | UNIMPLEMENTED | Client userinfo editing not exposed. |
| CL_SetInfo_f | — | UNIMPLEMENTED | Client userinfo editing not exposed. |
| CL_Packet_f | — | SUBSTITUTED | Connectionless packets do not exist over remotes. |
| CL_NextDemo | — | UNIMPLEMENTED | Demo system out of scope (fidelity backlog). |
| CL_Changing_f | — | UNIMPLEMENTED | `"changing"` stufftext falls through to `rawStufftext`; map change relies on `reconnect` handling. Untested for QW map change. |
| CL_Reconnect_f | `execStufftext` `"reconnect"` branch | PENDING | Sends `"new"` like the C connected path; no handshake-restart test. |
| CL_ConnectionlessPacket | — | SUBSTITUTED | No OOB wire (challenge/ping/rcon replies N/A on Roblox transport). |
| CL_ReadPackets | qwclient inbound queue + `qwcl.processPacket` | VERIFIED | Loopback: every check flows through it; live 547df88 (QW plays in Studio, full handshake). Delta: packets buffered per Heartbeat instead of socket poll. |
| CL_Download_f | — | SUBSTITUTED | All content ships via the Roblox asset bundle (`QuakeClientFS`); no file downloads. |
| CL_Windows_f | — | SUBSTITUTED | Win32 minimize key; platform-owned. |
| CL_Init | `qwclient.luau` boot function | PENDING | Wires fs/transport/render/input; registers no cvars or commands (no console). |
| Host_EndGame | pcall/warn in heartbeat packet loop | PENDING | Parse errors warn and drop the packet instead of tearing down the session — softer than C. |
| Host_Error | same | PENDING | Same substitution; no reconnect-on-error. |
| Host_WriteConfiguration | — | UNIMPLEMENTED | No config/bind persistence in the QW boot. |
| Host_SimulationTime | — | SUBSTITUTED | Heartbeat drives the frame; no host_speeds/maxfps gate. |
| Host_Frame | Heartbeat closure in qwclient | VERIFIED | Live 547df88: full frame loop (read packets → send cmd → predict → render) plays in Studio; loopback `tick()` mirrors the same order. |
| simple_crypt / Host_FixupModelNames | — | UNIMPLEMENTED | id's model-name de-obfuscation; assets are already plain. |
| Host_Init | qwclient boot | PENDING | Boot path selected by `QuakeClientFS` attribute `engine="qw"` (commit b98aa9a). |
| Host_Shutdown | — | SUBSTITUTED | Roblox instance teardown. |

## cl_parse.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_CalcNet | partial | PENDING | `svc_chokecount` marks `receivedtime=-2` and `deltaPacketCount` counts delta frames (loopback asserts "delta frames dominated"), but no netgraph consumer. |
| Model_NextDownload | inside `parseModellist` | VERIFIED | Loopback: "client loaded the world model", "precache lists received". Loads all models immediately (no downloads); world = precache slot 1, errors if not brush. |
| Sound_NextDownload | inside `parseSoundlist` | VERIFIED | Loopback handshake: soundlist continuation (`soundlist N next`) then `modellist N 0` — handshake completes. Sounds resolve lazily by name in soundlib, not precached. |
| CL_RequestNextDownload | — | SUBSTITUTED | No download phases; asset bundle replaces them. |
| CL_ParseDownload | — | SUBSTITUTED | `svc_download` never sent by qwsv; assets pre-shipped. |
| CL_NextUpload / CL_StartUpload / CL_IsUploading / CL_StopUpload | — | SUBSTITUTED | clc_upload (RSShot upload) N/A; no screenshots over the wire. |
| CL_ParseServerData | `parseServerData` | VERIFIED | Loopback: protocol 28 enforced, "spawncount agreed", "movevars received (gravity 800)", "assigned player slot 0", spectator bit split. |
| CL_ParseSoundlist | `parseSoundlist` | VERIFIED | Loopback: "precache lists received" (#cl.sound_name > 1). |
| CL_ParseModellist | `parseModellist` | VERIFIED | Loopback: same check + worldmodel load. |
| CL_ParseBaseline | `parseBaseline` | VERIFIED | Loopback: "baselines received (>20)". |
| CL_ParseStatic | `parseStatic` + qwclient `spawnPendingStatics` | PENDING | Parsed in the loopback signon stream (misparse would desync the message) but no assert; rendering path (entrender per kind) not individually screenshot-verified. |
| CL_ParseStaticSound | `parseStaticSound` + `soundlib.static` | PENDING | Same: parsed in signon, playback not asserted (soundlib.static live-verified under the NQ boot only). |
| CL_ParseStartSoundPacket | `parseStartSound` | VERIFIED | Loopback: "svc_sound guncock arrived through the PHS multicast" (vol/atten/ent/channel decode). |
| CL_ParseClientdata | head of `parseServerMessage` | VERIFIED | parsecount = incoming_acknowledged, receivedtime, latency drift (drift-up 0.001 rule). Prediction convergence (<1 unit) depends on it. |
| CL_NewTranslation | — | UNIMPLEMENTED | Colormap skin translation for players journaled open (backlog "STILL OPEN"). |
| CL_ProcessUserInfo | inline in `svc_updateuserinfo`/`svc_setinfo` handlers | PENDING | Re-derives name + spectator (incl. `*spectator`); no topcolor/bottomcolor/skin processing. |
| CL_UpdateUserinfo | `svc_updateuserinfo` handler | VERIFIED | Loopback: "own player info received" (name "looper", userid parse). |
| CL_SetInfo | `svc_setinfo` handler | PENDING | Key/value update + re-derive; no max-key/value length guards. |
| CL_ServerInfo | `svc_serverinfo` handler | PENDING | Updates `cl.serverinfo[key]`. |
| CL_SetStat | `svc_updatestat`/`svc_updatestatlong` handlers | VERIFIED | Loopback: "health stat mirrors server", "shells stat present", "ammo stat dropped after firing". |
| CL_MuzzleFlash | `svc_muzzleflash` → tempEntities type -1 → qwclient `handleTempEntity` | PENDING | Dlight 18 units forward, radius 200+rand(31), die +0.1, minlight 32 — matches C; self uses simorg/viewangles, others use frame playerstate. No visual check recorded. |
| CL_ParseServerMessage | `qwcl.parseServerMessage` | VERIFIED | Every loopback check flows through it; live 547df88. Handles all svcs qwsv emits; unknown svc errors like C. Delta: `svc_setview`/`svc_download` absent (server never sends). |

## cl_input.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| KeyDown / KeyUp + the 38 IN_*Down/IN_*Up wrappers | qwclient `keyButtons` map + `input.setButton` | SUBSTITUTED | Roblox UserInputService replaces the bind-driven ± command pairs. Delta: booleans, not the C two-source `kbutton_t` down[2]/impulse tracking — simultaneous bind sources and 0.25/0.75 partial-frame presses are lost. |
| IN_Impulse | number keys 1–8 → `input.setImpulse` | PENDING | Weapon switch works live per backlog (kill/respawn/fire sessions) but no per-impulse assert. |
| CL_KeyState | — | SUBSTITUTED | Digital 0/1 only (see above); QW's fractional key state depended on sub-frame press timing. |
| CL_AdjustAngles | — | UNIMPLEMENTED | No keyboard turn/look (+left/+right/+lookup/+lookdown); mouse-only via `input.updateTurn`. |
| CL_BaseMove | `input.sample` | PENDING | Produces forward/side/upmove from button state; speed values fixed (no cl_forwardspeed cvars). |
| MakeChar | `qwcl` `makeChar` | VERIFIED | Loopback convergence (<1 unit) replays quantized cmds; &~3 with signed clamp ±508 preserved (bit32 sign fixup noted in code). |
| CL_FinishMove | split: qwclient heartbeat (buttons/impulse/msec, 250ms→100ms hitch rule) + `qwcl.sendCmd` (MakeChar + angle quantize) | VERIFIED | Loopback convergence; backlog 115a438: "MakeChar+angle16 quantization before storing cmds, 2-move discard, latency drift" fixed and live-verified session followed. Delta: quantization applied to the *stored* cmd so prediction replays the wire exactly (see additions). |
| CL_SendCmd | `qwcl.sendCmd` | VERIFIED | Loopback: 3-cmd delta chain (nullcmd→oldest→old→new), clc_delta request, frame ring store at `outgoing_sequence & UPDATE_MASK`, `movemessages <= 2` discard; "delta frames dominated (>20)". Delta: checksum and lossage bytes written 0 (authenticated reliable transport). |
| CL_InitInput | — | SUBSTITUTED | No +/- command registration; direct key wiring (QW console/bind integration journaled follow-up). |
| CL_ClearStates | `input.setEnabled(false)` path zeroes moves | PENDING | Not called on disconnect by the QW boot. |

## cl_ents.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_AllocDlight | qwclient `allocDlight` | PENDING | Key-match → expired → pool-append (cap 32, overwrite slot 1) per C; no direct test. |
| CL_NewDlight | inlined at call sites in `handleTempEntity`/`relinkEntities` | PENDING | Explosion/muzzleflash/EF radii and lifetimes match C values. |
| CL_DecayLights | heartbeat dlight block | PENDING | `radius -= dt*decay`, die-time culling; feeds `worldmesh.updateDlights`. |
| CL_ParseDelta | `qwents.parseDelta` | VERIFIED | qwents: "moved origin applied", "new entity fields", U_MOREBITS byte, all U_ field reads. |
| FlushEntityPacket | too-old branch of `qwcl` `parsePacketEntitiesMsg` | PENDING | Sets invalid+validsequence=0 and parse-discards; not reachable in the lockstep loopback (never 63 packets behind). |
| CL_ParsePacketEntities | `qwents.parsePacketEntities` + `qwcl` `parsePacketEntitiesMsg` | VERIFIED | qwents: full update, delta update, unchanged-carry, U_REMOVE, baseline-new (7 checks); loopback: "first packetentities frame received", "validsequence tracking", "packet entities present". Delta: from-sequence mismatch only warns (C's exactness kept, message differs). |
| CL_LinkPacketEntities | qwclient `relinkEntities` packet-ents loop | VERIFIED | Live 115a438/9ecc594: "items + ammo boxes render, 8 ents at dm3 yard spawn". EF_ROTATE autorotate, EF_BRIGHTLIGHT/DIMLIGHT dlights, model-flag trails + rocket glow ported. Delta: no colormap translation, no lerp (matches QW snap behavior), brush ents render via cached worldmesh templates. |
| CL_ClearProjectiles | `cl.nails = {}` per parsed message | PENDING | Nails live one message, per C. |
| CL_ParseProjectiles | `qwcl` `parseNails` | PENDING | 6-byte bit-packed decode (x/y/z *2-4096, pitch 16-step, yaw byte) matches C; no nail-firing test. |
| CL_LinkProjectiles | nails loop in `relinkEntities` (`spikeindex`) | PENDING | spike.mdl slot located from model_name like C's cl_spikeindex. |
| CL_NewTempEntity | — | SUBSTITUTED | entrender pooled RenderEnts replace the cl_visedicts temp array (`beamPool`, keyed render ents). |
| CL_ParsePlayerinfo | `qwcl` `parsePlayerinfo` | VERIFIED | Loopback: own playerstate feeds prediction which converges; PF_MSEC state_time, PF_COMMAND delta cmd, PF_VELOCITY/MODEL/SKINNUM/EFFECTS/WEAPONFRAME flags all decoded. |
| CL_AddFlagModels | — | UNIMPLEMENTED | CTF flag attachment; `cl.flagindex` located, attachment journaled open. |
| CL_LinkPlayers | players loop in `relinkEntities` | PENDING | Extrapolated origins (predictedPlayerOrigins), pitch/3, V_CalcRoll lean ported; PF_DEAD/self skip. Not verified with a second live player. |
| CL_SetSolidEntities | `qwcl` `buildPhysents(false)` | VERIFIED | World + brush-model packet ents as physents; loopback prediction converges against them. |
| CL_SetUpPlayerPrediction | `qwcl.predictedPlayerOrigins` | PENDING | Half-elapsed-move prediction capped 255ms, local player uses last predicted frame; single-client tests can't exercise other-player paths. |
| CL_SetSolidPlayers | `buildPhysents(true)` player boxes | PENDING | Non-dead others at predicted origins with player mins/maxs; same single-client limit. |
| CL_EmitEntities | `relinkEntities` orchestration in heartbeat | VERIFIED | Live: 8 ents at dm3 yard spawn render; keyed create/destroy replaces the visedict rebuild. |

## cl_pred.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_NudgePosition | — | UNIMPLEMENTED | Post-predict unstick of simorg not ported (distinct from pmove's NudgePosition, which is). |
| CL_PredictUsercmd | `qwcl.predictUsercmd` | VERIFIED | Loopback: "prediction converged (<1.0)"; >50ms split recursion, oldbuttons/waterjumptime/onground carry preserved. Movement core itself is C-exact (see pmove.c). |
| CL_PredictMove | `qwcl.predictMove` | VERIFIED | Loopback convergence + live 547df88 "prediction == server origin exactly". Replays unacked cmds from incoming_sequence, senttime interpolation, 128-unit teleport snap, paused/intermission/validsequence gates, onserver→active promotion. |
| CL_InitPrediction | — | SUBSTITUTED | cl_pushlatency/cl_nopred cvars unregistered; `cl.nopred` field exists for the no-predict path. |

## cl_cam.c (spectator/chase camera)

Autocam essentials live in qwclient.luau (`camLock`/`camUnlock`/`camCheckHighTarget`/`camTrack`): always-on cl_hightrack target pick, `ptrack <num>` stringcmds, chase-locked view through the tracked player's predicted origin + viewangles, BUTTON_JUMP cycling, clc_tmove ride-along. The flyby-position search (InitFlyby family) is not ported — the view locks straight on like cl_chasecam 1.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| vectoangles / vlen (statics) | — | UNIMPLEMENTED | Only needed by the unported flyby search. |
| Cam_DrawViewModel / Cam_DrawPlayer | qwclient camera branch + relink skip | PENDING | Tracked player's model skipped, viewmodel drawn with the target's weaponframe while locked; needs a live spectator screenshot. |
| Cam_Unlock / Cam_Lock | `camUnlock` / `camLock` | PENDING | `ptrack`/`ptrack <num>` clc_stringcmds; no flyby, locks immediately (chasecam semantics). |
| Cam_DoTrace / Cam_TryFlyby / Cam_IsVisible / InitFlyby | — | UNIMPLEMENTED | Flyby camera-position search skipped; the port is chase-lock only. |
| Cam_CheckHighTarget | `camCheckHighTarget` | PENDING | Highest-frags pick over cl.players (name set, not spectator), relock when the leader out-frags the tracked player. |
| Cam_Track / adjustang / Cam_SetView / Cam_FinishMove | `camTrack` | PENDING | Runs per sent cmd: hightrack pick while unlocked, dead-target retarget, clc_tmove when >16 units off, moves zeroed while locked, jump-cycle with oldbuttons edge gate ("don't pogo stick"). Delta: hightrack recheck only while unlocked so jump-cycling sticks (C's hightrack path skips the jump check entirely). adjustang/Cam_SetView are #if 0 in the C. |
| Cam_Reset / CL_InitCam | — | SUBSTITUTED | cl_hightrack/cl_chasecam cvars fixed on; state is per-boot locals. |

## cl_demo.c (demo record/playback)

All demo functionality is out of scope for the milestone (fidelity backlog lists demo playback). One substitution: the read path.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_StopPlayback / CL_WriteDemoCmd / CL_WriteDemoMessage / CL_GetDemoMessage | — | UNIMPLEMENTED | No .qwd file I/O. |
| CL_GetMessage | `qwcl.processPacket` | SUBSTITUTED | The demo-vs-net dispatch collapses to the remote packet queue. |
| CL_Stop_f / CL_Record_f / CL_ReRecord_f / CL_PlayDemo_f | — | UNIMPLEMENTED | |
| CL_WriteRecordDemoMessage / CL_WriteSetDemoMessage | — | UNIMPLEMENTED | |
| CL_FinishTimeDemo / CL_TimeDemo_f | — | UNIMPLEMENTED | |

## cl_tent.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CL_InitTEnts | lazy `beamModelDef` + name-based `teSound` | SUBSTITUTED | Models/sounds resolved on first use instead of precached at init; same assets (bolt/bolt2/bolt3.mdl, tink/ric/exp sounds). |
| CL_ClearTEnts | — | UNIMPLEMENTED | Beams/pools not cleared on level reset; benign (0.2s beam lifetime) but a leak of pooled instances across maps. |
| CL_AllocExplosion | — | UNIMPLEMENTED | The `s_explod.spr` explosion sprite is omitted — TE_EXPLOSION renders particles+dlight+sound only. Visible fidelity delta. |
| CL_ParseBeam | wire: `qwcl` `parseTempEntity` (ent+start+end); slots: qwclient `parseBeam` | PENDING | Entity-keyed reuse then free-slot scan, endtime = time+0.2, MAX_BEAMS 8 — matches C. |
| CL_ParseTEnt | `qwcl` `parseTempEntity` + qwclient `handleTempEntity` | PENDING | All 14 TE_ types wired with C particle counts/colors, randomized spike ric sounds, explosion dlight (350/0.5s/decay 300). Backlog 115a438 lists tent effects among fixed audit gaps; the recorded live check named view weapon/items, not effects. |
| CL_NewTempEntity | — | SUBSTITUTED | See cl_ents.c row: pooled entrender instances. |
| CL_UpdateBeams | qwclient `updateBeams` | PENDING | 30-unit segments, random roll per segment, yaw/pitch from dist, player-owned beam pinned to simorg (playernum+1). Delta: pooled parts hidden at -10000 z instead of freed. |
| CL_UpdateExplosions | — | UNIMPLEMENTED | Sprite frame animation (goes with CL_AllocExplosion). |
| CL_UpdateTEnts | heartbeat drain (`handleTempEntity` loop + `updateBeams`) | PENDING | Runs each frame after relink. |

## view.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| V_CalcRoll | inlined twice in qwclient (own view + other players' lean) | PENDING | side/200*2 clamp * sign; rollangle=2, rollspeed=200 hardcoded (cvar defaults). |
| V_CalcBob | inlined in camera block | PENDING | 0.6s cycle, sin split at 0.5, xy-speed*0.02, 0.3/0.7 blend, clamp [-7,4] — C defaults hardcoded. |
| V_StartPitchDrift / V_StopPitchDrift / V_DriftPitch | — | UNIMPLEMENTED | Pitch drift is keyboard-look-era behavior; mouse-look always on. |
| BuildGammaTable / V_CheckGamma | shared texture path (gamma 0.7) | SUBSTITUTED | Gamma baked into palette conversion in the shared textures module; no runtime table. |
| V_ParseDamage | `svc_damage` → `cl.damage` in qwcl | PENDING | Recorded but unused: no damage kick (v_dmg_pitch/roll) and no cshift. Journaled open ("damage kicks/cshifts"). |
| V_cshift_f / V_BonusFlash_f | — | UNIMPLEMENTED | Screen color shifts absent. |
| V_SetContentsColor / V_CalcPowerupCshift / V_CalcBlend / V_UpdatePalette | — | UNIMPLEMENTED | No underwater/powerup/damage palette blends in the QW boot (NQ fidelity backlog too). |
| angledelta / CalcGunAngle | — | UNIMPLEMENTED | Gun yaw/pitch lag not ported; gun uses view angles directly. |
| V_BoundOffsets | — | UNIMPLEMENTED | 14-unit eye clamp vs entity origin; prediction keeps eye on simorg so drift can't occur. |
| V_AddIdle | — | UNIMPLEMENTED | v_idlescale sway (intermission idle) absent. |
| V_CalcViewRoll | camera block (roll + dead branch) | PENDING | 80° death roll at viewheight -16 ported; PF_DEAD or health<=0 triggers. |
| V_CalcIntermissionRefdef | intermission branch | PENDING | Fixed simorg/simangles from svc_intermission, no bob/height; no idle sway (see V_AddIdle). |
| V_CalcRefdef | camera block in heartbeat | VERIFIED | Backlog 115a438/9ecc594: "V_CalcRefdef camera (bob/roll/punch/dead/gib/intermission)" implemented, session live-verified view weapon + world. Deltas: no view_ofs from server (STAT_VIEWHEIGHT + PF_GIB +8), gun bob simplified to forward push. |
| DropPunchAngle | `punchangle -= 10*dt`, clamp 0 | VERIFIED | Backlog 2ee4228 note: "QW DropPunchAngle is verbatim (kicks last one frame — authentic QW)". svc_smallkick/bigkick set -2/-4. |
| V_RenderView | camera.CFrame via `qcoords.cframe` | SUBSTITUTED | Roblox camera replaces the software refresh entry; live 547df88 world renders through it. |
| V_Init | — | SUBSTITUTED | No cvar/command registration. |

## sbar.c (status bar / scoreboard)

Entire file UNIMPLEMENTED for the QW boot — journaled as "QW sbar/console/scoreboard overlay (biggest remaining UX gap)". The data side is live (`cl.stats`, `cl.players` frags/ping verified in loopback); the NQ boot's `src/client/hud.luau` draws an NQ sbar but is not wired to QW state.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Sbar_ShowTeamScores / Sbar_DontShowTeamScores / Sbar_ShowScores / Sbar_DontShowScores | — | UNIMPLEMENTED | +showscores/+showteamscores keys. |
| Sbar_Changed / Sbar_Init | — | UNIMPLEMENTED | |
| Sbar_DrawPic / Sbar_DrawSubPic / Sbar_DrawTransPic / Sbar_DrawCharacter / Sbar_DrawString / Sbar_itoa / Sbar_DrawNum | — | UNIMPLEMENTED | Drawing primitives (NQ hud.luau has equivalents to reuse). |
| Sbar_SortFrags / Sbar_SortTeams | — | UNIMPLEMENTED | Data available in `cl.players`. |
| Sbar_SoloScoreboard / Sbar_DrawInventory / Sbar_DrawFrags / Sbar_DrawFace / Sbar_DrawNormal / Sbar_Draw | — | UNIMPLEMENTED | |
| Sbar_IntermissionNumber / Sbar_TeamOverlay / Sbar_DeathmatchOverlay / Sbar_MiniDeathmatchOverlay / Sbar_IntermissionOverlay / Sbar_FinaleOverlay | — | UNIMPLEMENTED | Intermission state (cl.intermission=1/2) is parsed and moves the camera; overlays missing. |

## screen.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CalcFov | `qcoords.calcFovY` | VERIFIED | Commit 2ee4228 (backlog): fov cvar horizontal at true viewport aspect (16:9 fov 90 → 58.7 vertical), viewport resize tracked, "gun placement verified exact vs v_shot.mdl authoring". |
| SCR_CenterPrint / SCR_DrawCenterString / SCR_CheckDrawCenterString / SCR_EraseCenterString | centerprints drained to `print()` | PENDING | Text reaches the Studio output only; on-screen center string is part of the console/HUD follow-up. |
| SCR_CalcRefdef | — | SUBSTITUTED | Roblox viewport; journaled follow-up: WinQuake draws the 3D vrect *above* the sbar (raised view center) — to replicate when the QW sbar lands. |
| SCR_SizeUp_f / SCR_SizeDown_f | — | UNIMPLEMENTED | viewsize scaling (fidelity backlog). |
| SCR_Init | — | SUBSTITUTED | |
| SCR_DrawRam / SCR_DrawTurtle / SCR_DrawNet / SCR_DrawFPS / SCR_DrawPause | — | UNIMPLEMENTED | Debug/status icons; svc_setpause is parsed (`cl.paused` gates prediction) but nothing draws it. |
| SCR_SetUpToDrawConsole / SCR_DrawConsole / SCR_BringDownConsole | `consolelib.update` (Heartbeat) | PENDING | scr_conspeed slide + draw via the shared console module. |
| WritePCXfile / SCR_ScreenShot_f / MipColor / SCR_DrawCharToSnap / SCR_DrawStringToSnap / SCR_RSShot_f | — | SUBSTITUTED | Screenshots/remote-shots are platform features; N/A. |
| SCR_DrawNotifyString / SCR_ModalMessage | — | UNIMPLEMENTED | |
| SCR_UpdateScreen / SCR_UpdateWholeScreen | Heartbeat render sequence | SUBSTITUTED | Roblox render pipeline; the C draw-order (3D → sbar → console) has no equivalent yet because the 2D layers are absent. |

## console.c

The QW boot now drives the shared `src/client/console.luau` (the NQ boot's console module): tilde toggle, line editor + history, scrollback, and a messagemode chat line; typed commands run the Cmd_ExecuteString subset in qwclient.luau with Cmd_ForwardToServer fallback.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Con_Printf / Con_Print | `cl.prints` sink → hudlib notify + `consolelib.print` + Studio output | PENDING | svc_print text (incl. chat, verified live 547df88 "kill/respawn + chat broadcasts over the wire") now also lands in the console scrollback; needs a live screenshot. |
| Con_DPrintf | `cl.dprint` hook | PENDING | qwclient wires it to print. |
| Key_ClearTyping / Con_ToggleConsole_f / Con_ToggleChat_f / Con_MessageMode_f / Con_MessageMode2_f | qwclient key wiring + `execCommand` | PENDING | Backquote/tilde toggles; `messagemode`/`messagemode2` commands open the chat line (T is bound to messagemode per default.cfg); input.setEnabled(false) while either is up. |
| Con_Clear_f / Con_ClearNotify / Con_Resize / Con_CheckResize / Con_Init / Con_Linefeed | consolelib | PENDING | `clear` empties con.lines; wrap/scrollback in consolelib.print; resize N/A (fixed 64-col conback). |
| Con_DrawInput / Con_DrawNotify / Con_DrawConsole / Con_NotifyBox / Con_SafePrintf | `consolelib.update` + chat row | PENDING | Input line with blink cursor + scrollback via conchars rows; the messagemode "say:" line is a confont row (notify fade stays on hudlib). NotifyBox/SafePrintf N/A. |

## keys.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Key_Event | qwclient `onKey` (InputBegan/InputEnded) | PENDING | Hardcoded `keyButtons` table (WASD/arrows/space/ctrl/shift, mouse1 attack, 1–8 impulses); dispatch tiers now match key_dest: console → messagemode → game, tilde toggles from anywhere, mouse ignored while typing. |
| Key_Console / Key_Message | `consoleKey` (consolelib.handleKey) / `messageKey` | PENDING | Enter executes/`say "…"`s, Backspace, history arrows, SHIFT_MAP + GetStringForKeyCode text entry (NQ boot's scheme); Escape/tilde leaves messagemode. Needs a live typing screenshot. |
| CheckForCommand / CompleteCommand | — | UNIMPLEMENTED | |
| Key_StringToKeynum / Key_KeynumToString | — | UNIMPLEMENTED | |
| Key_SetBinding / Key_Unbind_f / Key_Unbindall_f / Key_Bind_f / Key_WriteBindings / Key_Init | — | UNIMPLEMENTED | No bind system in the QW boot (code comment: "QW console/bind integration is journaled follow-up work"). |
| Key_ClearStates | — | UNIMPLEMENTED | |

## menu.c

Entire file UNIMPLEMENTED for the QW boot. Roblox platform owns quit/pause; options + key-binding menus are in the fidelity backlog. The NQ boot's `src/client/menu.luau` is not wired to QW.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| M_DrawCharacter / M_Print / M_PrintWhite / M_DrawTransPic / M_DrawPic / M_BuildTranslationTable / M_DrawTransPicTranslate / M_DrawTextBox / M_DrawSlider / M_DrawCheckbox | — | UNIMPLEMENTED | Menu drawing primitives. |
| M_ToggleMenu_f / M_Init / M_Draw / M_Keydown | — | UNIMPLEMENTED | |
| M_Menu_Main_f / M_Main_Draw / M_Main_Key | — | UNIMPLEMENTED | |
| M_Menu_Options_f / M_AdjustSliders / M_Options_Draw / M_Options_Key | — | UNIMPLEMENTED | |
| M_Menu_Keys_f / M_FindKeysForCommand / M_UnbindCommand / M_Keys_Draw / M_Keys_Key | — | UNIMPLEMENTED | |
| M_Menu_Video_f / M_Video_Draw / M_Video_Key | — | UNIMPLEMENTED | Video modes are platform-owned anyway. |
| M_Menu_Help_f / M_Help_Draw / M_Help_Key | — | UNIMPLEMENTED | |
| M_Menu_Quit_f / M_Quit_Key / M_Quit_Draw | — | SUBSTITUTED | Roblox leave-game UI. |
| M_Menu_SinglePlayer_f / M_SinglePlayer_Draw / M_SinglePlayer_Key / M_Menu_MultiPlayer_f / M_MultiPlayer_Draw / M_MultiPlayer_Key | — | UNIMPLEMENTED | Even in C these are "use the console" stubs for QW. |

## skin.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Skin_Find / Skin_Cache | — | UNIMPLEMENTED | No custom .pcx skins; players render base player.mdl skinnum. Colormap translation journaled open. |
| Skin_NextDownload | `execStufftext` `"skins"` branch → `begin N` | VERIFIED | Loopback: "handshake completed: server spawned the client" requires the skins→begin step. Substitution note in code: "no skin downloads over remotes: report ready immediately". |
| Skin_Skins_f / Skin_AllSkins_f | — | UNIMPLEMENTED | Console commands. |

## snd_dma.c

Roblox `Sound`/3D audio (`src/client/sound.luau`) replaces the DMA mixer wholesale; rows below map intent, not implementation.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| S_Init / S_Startup / S_Shutdown | `soundlib.new(Workspace)` | SUBSTITUTED | No DMA buffer; Roblox audio engine. |
| S_FindName / S_TouchSound / S_PrecacheSound | soundmap lookup (`regionFor`) | SUBSTITUTED | Sounds live in one uploaded asset with per-sample time regions (soundmap.txt); resolved by name at play time. |
| SND_PickChannel | `bankSound` pooling | SUBSTITUTED | Roblox voice management; ent+channel override kept in `sound.start`/`sound.stop`. |
| SND_Spatialize | `rolloffFor` + emitter parts | SUBSTITUTED | Roblox distance attenuation approximates ATTN scaling; no stereo separation math. |
| S_StartSound | `soundlib.start` via `cl.sounds` drain | VERIFIED | Wire side: loopback "svc_sound guncock arrived through the PHS multicast". Playback path shared with NQ boot (live-verified there: "57/57 statics playing+loaded, one-shots fire"); QW playback itself not separately screenshot/audio-verified. |
| S_StopSound | `soundlib.stop` (svc_stopsound → num=-1 sentinel) | PENDING | Ent/channel stop wired; untested. |
| S_StopAllSounds / S_StopAllSoundsC / S_ClearBuffer | `sound.clear` exists | PENDING | qwclient does NOT call it on level reset — sounds can carry across maps (gap). |
| S_StaticSound | `soundlib.static` via `spawnPendingStatics` | PENDING | Volume byte passthrough (soundlib scales by 255); loop regions per sample. |
| S_UpdateAmbientSounds | `sound.updateAmbients` exists | UNIMPLEMENTED | qwclient never calls it (NQ boot does) — no water/sky ambients in QW. |
| S_Update / GetSoundtime / S_ExtraUpdate / S_Update_ | — | SUBSTITUTED | Mixer paint loop N/A. |
| S_Play / S_PlayVol / S_SoundList / S_SoundInfo_f | — | UNIMPLEMENTED | Console commands. |
| S_LocalSound | — | UNIMPLEMENTED | No local UI sounds (menu beeps, talk.wav on chat print). |
| S_AmbientOff / S_AmbientOn / S_ClearPrecache / S_BeginPrecaching / S_EndPrecaching | — | SUBSTITUTED | Precache phases N/A with asset-shipped sounds. |

## net_chan.c

Netchan-lite (`qwnetchan.luau`): the transport is already reliable+ordered, so the retransmitted reliable stream with fragment bits collapses to `[seq:u32][ack:u32][reliable][datagram]`. Sequence numbers keep their exact protocol role (frames ring, delta keys).

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Netchan_Init | — | SUBSTITUTED | No qport (no NAT rebinding over remotes). |
| Netchan_OutOfBand / Netchan_OutOfBandPrint | — | SUBSTITUTED | No connectionless packets. |
| Netchan_Setup | `qwnetchan.new` | VERIFIED | Loopback + qwents suites construct channels; C POST-increment semantics preserved (packet carries current outgoing_sequence, incremented after — code comment + backlog note). |
| Netchan_CanPacket / Netchan_CanReliable | — | SUBSTITUTED | No rate choke/backoff; Roblox transport paces. |
| Netchan_Transmit | `qwnetchan.transmit` | VERIFIED | Loopback end-to-end (handshake + 100+ play packets); reliable stream rides in-band with the datagram appended, cleared after send. Delta: no reliable retransmission machinery, no fragment/sequence-high bits. |
| Netchan_Process | `qwnetchan.process` | VERIFIED | Loopback; stale/duplicate seq discarded, drop_count (net_drop) computed for the server's cmd-replay path, ack drives `parsecount`. |

## pmove.c

Ported verbatim in `src/shared/engine/qw/pmove.luau`; ground truth = `tools/pmove_truth.c`, which compiles the **actual QW pmove.c/pmovetst.c** and runs a 300-tick scripted course on e1m1 (run/veer/strafe/bunny-jump/backpedal/diagonal-jump/look-down). `tests/test_qw_pmove.luau` asserts max position error < 0.01 (measured 0.000122), velocity < 0.05, and onground/waterlevel equality **every tick**.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Pmove_Init / PM_InitBoxHull | `hullForBox` per call | SUBSTITUTED | Fresh 6-clipnode box hull built per trace instead of a static; identical plane layout (verified transitively by pmove-truth, whose player-vs-box path is unused with world-only physents). |
| PM_ClipVelocity | `clipVelocity` | VERIFIED | pmove-truth (every slide/landing tick). |
| PM_FlyMove | `flyMove` | VERIFIED | pmove-truth (air phases, clip-plane creases, waterjump velocity restore). |
| PM_GroundMove | `groundMove` | VERIFIED | pmove-truth (step-up/down vs slide comparison on e1m1 terrain). |
| PM_Friction | `friction` | VERIFIED | pmove-truth (incl. edge-friction 2x trace). |
| PM_Accelerate | `accelerate` | VERIFIED | pmove-truth. |
| PM_AirAccelerate | `airAccelerate` | VERIFIED | pmove-truth (bunny phases; 30-unit wishspd cap). |
| PM_WaterMove | `waterMove` | PENDING | Ported verbatim; the truth course never enters water (waterlevel asserted 0 every tick, so the branch is untraversed). |
| PM_AirMove | `airMove` | VERIFIED | pmove-truth (ground + air branches). |
| PM_CatagorizePosition | `catagorizePosition` | VERIFIED | pmove-truth: onground and waterlevel agree all 300 ticks. |
| JumpButton | `jumpButton` | VERIFIED | pmove-truth (held-jump pogo suppression in bunny phases). Swim sub-branch untraversed (no water on course). |
| CheckWaterJump | `checkWaterJump` | PENDING | Ported verbatim; unreachable on the truth course (requires waterlevel 2). |
| NudgePosition | `nudgePosition` | VERIFIED | pmove-truth (runs every tick). C subtlety deliberately preserved: the 1/8 truncation is dead code (base copied pre-truncation) — do not "fix" (backlog M1 note). |
| SpectatorMove | `spectatorMove` | PENDING | Ported; no spectator in truth script or loopback. |
| PlayerMove | `pmove.playerMove` | VERIFIED | pmove-truth top-level; also loopback (client prediction and qwsv SV_RunCmd both drive it — convergence < 1 unit). |

## pmovetst.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| PM_InitBoxHull | `hullForBox` | SUBSTITUTED | See pmove.c row. |
| PM_HullPointContents | `hullPointContents` | VERIFIED | pmove-truth (every trace/contents call for 300 ticks). |
| PM_PointContents | `pointContents` | VERIFIED | pmove-truth (waterlevel equality each tick). |
| PM_RecursiveHullCheck | `recursiveHullCheck` | VERIFIED | pmove-truth (DIST_EPSILON crossings, re-enter-solid backoff loop) — position error at the f32/f64 noise floor. |
| PM_TestPlayerPosition | `testPlayerPosition` | VERIFIED | pmove-truth via NudgePosition each tick. |
| PM_PlayerMove (the trace) | `playerTrace` | VERIFIED | pmove-truth; multi-physent closest-fraction select with 0-based `ent` index preserved (loopback exercises brush-ent + player-box physents). |

## common.c (MSG_* — delta usercmd scope)

Base MSG_Read/Write* live in the shared `src/shared/engine/common/msg.luau` (covered by the NQ manifest); rows here are the QW-specific delta-usercmd parts.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| MSG_WriteDeltaUsercmd | `qwents.writeDeltaUsercmd` | VERIFIED | qwents: full round trip (CM_ bits, msec always written). |
| MSG_ReadDeltaUsercmd | `qwents.readDeltaUsercmd` | VERIFIED | qwents: forwardmove/side/buttons/impulse/msec exact; loopback replays them through the server. |
| MSG_WriteAngle16 / MSG_ReadAngle16 | `msg.writeAngle16` / `msg.readAngle16` | VERIFIED | qwents: "cmd angle1/2 round-trips (angle16, mod 360)" — signed-short congruence semantics preserved. |
| MSG_WriteAngle (QW byte angle) | `msg.writeAngleQW` | VERIFIED | Entity angles in qwents delta rows round-trip in the qwents suite. |

## wad.c / draw.c (2D assets & drawing — as relevant)

The QW boot currently has **no 2D overlay** (sbar/console/menu all above). The shared NQ modules (`render/textures.luau`, `render/confont.luau`, `hud.luau`, `console.luau`; wad parsing verified by `tests/test_wad.luau`) are the planned substrate.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| W_CleanupName / W_LoadWadFile / W_GetLumpName / W_GetLumpNum / SwapPic | shared wad module (NQ boot) | PENDING | Exists and test-covered (test_wad) but not consumed by the QW boot yet. |
| Draw_Init / Draw_Character / Draw_String / Draw_Alt_String / Draw_Pic / Draw_SubPic / Draw_TransPic / Draw_TransPicTranslate / Draw_ConsoleBackground / Draw_TileClear / Draw_Fill / Draw_FadeScreen | NQ confont/hud equivalents | UNIMPLEMENTED (QW boot) | Awaits the QW sbar/console overlay. |
| Draw_Pixel / Draw_Crosshair | — | UNIMPLEMENTED | No crosshair in the QW boot. |
| Draw_DebugChar / Draw_CharToConback / R_DrawRect8 / R_DrawRect16 / Draw_BeginDisc / Draw_EndDisc | — | SUBSTITUTED | Software-framebuffer plumbing (disc = disk-access icon); no framebuffer exists. |

## Rasterizer files — substituted groups (Roblox EditableMesh renderer)

Per the port architecture, the software rasterizer is replaced wholesale; groups get one row each, except particles/dlights/lightstyles/lightmaps, where the port reproduces the *outputs* and gets real rows.

| C group / function | Port | Status | Evidence / Delta |
|---|---|---|---|
| d_*.c/.s/.asm (d_edge, d_scan, d_polyse, d_sprite, d_sky, d_surf, d_part, d_fill, d_zpoint, …) | — | SUBSTITUTED | Span/poly/particle scanline rasterization is the GPU's job; geometry ships as EditableMesh. No per-pixel path exists to port. |
| r_main.c / r_bsp.c / r_edge.c / r_draw.c / r_aclip.c / r_vars.c / r_misc.c / r_efrag.c | `render/worldmesh.luau` | SUBSTITUTED | World surfaces prebuilt as EditableMesh batches per texture; Roblox handles frustum/visibility/z instead of the edge list + PVS surface walk. Live 547df88: QW world (dm3) renders; loopback verifies the same BSP data loads. |
| r_alias.c (+ r_aliasa) | `render/entrender.luau` | SUBSTITUTED | Alias frames as EditableMesh with light level via `setLight`; used for QW packet ents, players, gun, beams. Live 115a438/9ecc594: items + view weapon render. Delta: no per-vertex anorm shading table. |
| r_sprite.c | entrender sprite billboards | SUBSTITUTED | Sprite frames as billboards. |
| r_sky.c / d_sky.c | shared sky (10Hz image scroll) | SUBSTITUTED | Live-verified under the NQ boot; same module. |
| gl_*.c (entire GL renderer) | — | SUBSTITUTED | The port targets the software renderer's feature set as the fidelity reference; the GL path is an alternative C backend, not a feature source. |
| r_part.c: R_RunParticleEffect | `particles.runEffect` | PENDING | r_part.c port live-verified under the NQ boot (memory 2026-07-03); QW wiring (`handleTempEntity`) not separately visually verified. |
| r_part.c: R_ParticleExplosion | `particles.explosion` | PENDING | Same. |
| r_part.c: R_LavaSplash / R_TeleportSplash | `particles.lavaSplash` / `.teleportSplash` | PENDING | Same. |
| r_part.c: R_RocketTrail (all 7 trail types) | `particles.rocketTrail` | PENDING | QW trail-type mapping (rocket/grenade/gib/zomgib/tracer1-3 by model flags) wired in `relinkEntities`. |
| r_part.c: R_DrawParticles | `particles.update` | PENDING | Called per Heartbeat with cl.time/dt. |
| r_light.c: R_AnimateLight | qwclient `updateLightstyles` + `worldmesh.updateLightStyles` | PENDING | 10Hz 'a'–'z' style animation; loopback asserts lightstyles *arrive* (cl.lightstyles[0]); animation live-verified under NQ only. |
| r_light.c: R_MarkLights / R_AddDynamicLights | `worldmesh.updateDlights` + `render/lightatlas.luau` | PENDING | Dynamic light surface pass fed by the CL_DecayLights block; no recorded QW visual check. |
| r_light.c: R_LightPoint | `render/lightpoint.at` | PENDING | Used for the R_DrawViewModel gun light (floor of 24 — NQ-boot note says the floor is required or the gun vanishes in dark rooms). |
| r_surf.c / d_surf.c (surface cache + lightmaps) | `lightatlas.luau` + worldmesh lighting | VERIFIED | QW world renders lit, live 547df88 — including the recorded observation that dm3's spawn is genuinely 12/255 light ("near-black screens there are faithful, not a bug"), which is a lightmap-correctness check. |

## Port-side additions with no C counterpart

| Addition | Where | Justification |
|---|---|---|
| `QW_Cmd` workspace attribute → `sendStringCmd` | qwclient heartbeat | Studio debug escape hatch to issue stringcmds (e.g. `kill`) until the QW console overlay lands; journaled as a debug hook in the backlog (547df88 session). |
| `QW_SimOrg` / `QW_State` / `QW_SeqIn` / `QW_SeqOut` / `QW_Valid` attributes | qwclient heartbeat | Live-verification diagnostics; memory records that screen capture is unreliable in play mode and numeric attribute polling is the preferred check. Used in the 2026-07-04 live sessions. |
| `cl.levelResets` counter | `qwcl` `clearState` | Renderer rebuild signal: C's CL_ClearState reaches into renderer globals directly; the port keeps qwcl rendering-agnostic and lets qwclient watch the counter to rebuild world/statics/templates. |
| `cl.deltaPacketCount` | `qwcl` `parsePacketEntitiesMsg` | Netgraph substitute; asserted by loopback ("delta frames dominated"). |
| Event sinks: `cl.prints`, `cl.centerprints`, `cl.sounds`, `cl.tempEntities`, `cl.damage`, `cl.stufftext`/`rawStufftext` | `qwcl.new` | C parse code calls Con_Printf/S_StartSound/renderer directly; the port queues events so the same core serves the Roblox layer and offline tests (loopback consumes `cl.sounds`, `cl.stats`). `rawStufftext` holds non-connection lines for the future console layer. |
| Cmd quantization *before* storing (`makeChar` + `quantAngle` on the saved frame cmd) | `qwcl.sendCmd` | Deliberate delta: C predicts from the pre-quantization struct and eats sub-unit drift; the port quantizes to angle16/±4-step first "so prediction replays exactly what the server receives" (code comment). Backed by loopback convergence and the live "prediction == server origin exactly" note. |
| Checksum and lossage bytes written as 0 in clc_move | `qwcl.sendCmd` | The C checksum defends spoofed UDP and lossage reports measured drop; Roblox remotes are authenticated and netchan-lite computes `drop_count` from sequences. Code comments state both. |
| Stale-packet discard rule (`seq <= incoming_sequence` → drop) | `qwnetchan.process` | Transport is ordered, so any non-increasing sequence is a duplicate; replaces C's out-of-order/duplicate warnings. |
| `execStufftext` `"skins"` short-circuit → `begin` | `qwcl` | Replaces Skin_NextDownload's download loop: "no skin downloads over remotes: report ready immediately" (code comment); handshake-verified in loopback. |
| `RQ_ForceForward` / `RQ_ForceUp` / `RQ_ForceYaw` / `RQ_ForcePitch` / `RQ_ForceAttack` attributes | `src/client/input.luau` `sample` | "Scripted-test hooks (verification harness drives the real input path)" — code comment; lets Studio verification inject movement through the same sample() path both boots use. |
| Per-Heartbeat move accumulator with 250ms→100ms hitch substitution | qwclient heartbeat | Direct transplant of CL_FinishMove's `msec > 250 → 100` rule onto Heartbeat timing (comment cites it); the accumulator itself replaces the fixed-rate Host_Frame pump. |
| `sendStringCmd` exported helper | `qwcl` | Convenience wrapper over the two MSG writes C inlines everywhere; also the QW_Cmd hook's entry point. |

No additions were found without a stated justification (code comment or backlog entry).

## Totals

Rows count grouped one-liner families (IN_* wrappers, menu triads, upload/download clusters) as single rows.

| Status | Rows |
|---|---|
| VERIFIED | 53 |
| PENDING | 65 |
| UNIMPLEMENTED | 59 |
| SUBSTITUTED | 49 |
| **Total rows** | **226** |

Highest-impact gaps (all journaled in the backlog):
1. **sbar.c/console.c live proof** — HUD, console and chat line are wired (hudlib + consolelib) but all rows sit at PENDING until a Studio screenshot verifies them.
2. **cl_cam.c flyby search** — spectator autocam is chase-lock only (InitFlyby/Cam_TryFlyby camera positioning not ported); needs live spectator verification.
3. **CL_AllocExplosion / CL_UpdateExplosions** — `s_explod.spr` explosion sprite omitted (particles/dlight/sound only).
4. **V_ParseDamage consumers + cshifts** — damage parsed but no view kick or screen blends (`V_Calc*Cshift`, `V_UpdatePalette` family).
5. **CL_NewTranslation / skin colormaps + CL_AddFlagModels** — no player color translation or CTF flag attachment (flagindex ready).
Also noteworthy: PM_WaterMove/CheckWaterJump are ported verbatim but the C ground-truth course never enters water; S_UpdateAmbientSounds and sound clearing on level change are unwired in the QW boot.
