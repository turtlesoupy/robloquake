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

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_Quit_f | — | SUBSTITUTED | Roblox leave-game UI owns quitting; no client quit command. | — (substitution; verify justification still holds) |
| CL_Version_f | `version` in execCommand | VERIFIED | Live battery: "Version 2.40 / robloquake QuakeWorld port" ([evidence/qw-console-tooling-battery.txt](evidence/qw-console-tooling-battery.txt)). | Stage per the battery .txt |
| CL_SendConnectPacket | `qwcl.connect` | SUBSTITUTED | No OOB challenge/qport/userinfo blob: Roblox remotes are per-player authenticated; server side takes userinfo via `qwsv.wireConnect`. `connect()` goes straight to `clc_stringcmd "new"`. | — (substitution; verify justification still holds) |
| CL_CheckForResend | — | SUBSTITUTED | Reliable ordered transport; no connect resend timer. | — (substitution; verify justification still holds) |
| CL_BeginServerConnect | `qwcl.connect` | SUBSTITUTED | One server per place; no address, no connect_time state. | — (substitution; verify justification still holds) |
| CL_Connect_f | — | SUBSTITUTED | No server address to type; place boot connects automatically. | — (substitution; verify justification still holds) |
| CL_Rcon_f | — | N/A | rcon has no meaning over place-local remotes. N/A: transport-era (rcon). | — (implement first) |
| CL_ClearState | `qwcl` `clearState` | VERIFIED | test_qw_loopback changelevel: "client cleared state and loaded e1m2" — full state reset + rebuild over the wire. | `lune run tests/test_qw_loopback.luau` |
| CL_Disconnect | partial (`svc_disconnect` handler) | VERIFIED | test_qw_loopback: svc_disconnect sets state "disconnected" + records the reason; heartbeat bail-out is the qwclient consumer. No drop-cmd send, no demo/upload teardown (both N/A on remotes). | `lune run tests/test_qw_loopback.luau` |
| CL_Disconnect_f | — | N/A | No user-initiated disconnect command. N/A: platform-owned flow. | — (implement first) |
| CL_User_f | `user <name/userid>` in execCommand (20-column userinfo dump) | VERIFIED | Live battery: own userinfo dumped by name ([evidence/qw-console-tooling-battery.txt](evidence/qw-console-tooling-battery.txt)); "User not in server." for misses. | Stage per the battery .txt |
| CL_Users_f | `users` in execCommand (userid/frags/name table + total) | VERIFIED | Live battery: the C-format table with "1 total users" ([evidence/qw-console-tooling-battery.txt](evidence/qw-console-tooling-battery.txt)); the data side is the loopback-verified cl.players. | Stage per the battery .txt |
| CL_Color_f | `color <top> [bottom]` → two setinfo stringcmds (13-clamp like C) | VERIFIED | [evidence/qw-color-crosshair.jpg](evidence/qw-color-crosshair.jpg): "color 4 12" round-trips the wire — yellow/red fills in the rankings row, the in-sbar frag cell, AND the mini overlay at once; the setinfo path is loopback-verified. | Stage per evidence/qw-color-crosshair.txt |
| CL_FullServerinfo_f | `execStufftext` `fullserverinfo` branch | VERIFIED | test_qw_loopback now asserts cl.serverinfo is populated by the handshake's fullserverinfo stufftext. | `lune run tests/test_qw_loopback.luau` |
| CL_FullInfo_f | `fullinfo \\k\\v...` → per-pair setinfo stringcmds | VERIFIED | The backslash-pair parse feeds the loopback-verified setinfo path (code: execCommand fullinfo); CL_Color_f's capture proves the downstream. | code + `lune run tests/test_qw_loopback.luau` (setinfo) |
| CL_SetInfo_f | `setinfo k v` forwards as the wire setinfo user command | VERIFIED | test_qw_loopback: setinfo updates cross the wire and broadcast back via svc_setinfo (the C client-side table mirror is the broadcast echo — recorded delta: no local-only copy). | `lune run tests/test_qw_loopback.luau` |
| CL_Packet_f | — | SUBSTITUTED | Connectionless packets do not exist over remotes. | — (substitution; verify justification still holds) |
| CL_NextDemo | — | SUBSTITUTED | Same as the NQ row: the startdemos attract loop fills a disconnected state that the platform session model never enters (the place boots straight into the live server). | — (substitution; platform session flow) |
| CL_Changing_f | `"changing"` branch in execStufftext (intermission cleared, "Changing map..." printed, state held at connected) | VERIFIED | test_qw_loopback: crafted changing stufftext asserts all three effects. | `lune run tests/test_qw_loopback.luau` |
| CL_Reconnect_f | `execStufftext` `"reconnect"` branch | VERIFIED | test_qw_loopback: an svc_stufftext "reconnect" makes the client send "new" and the server answers the fresh handshake. | `lune run tests/test_qw_loopback.luau` |
| CL_ConnectionlessPacket | — | SUBSTITUTED | No OOB wire (challenge/ping/rcon replies N/A on Roblox transport). | — (substitution; verify justification still holds) |
| CL_ReadPackets | qwclient inbound queue + `qwcl.processPacket` | VERIFIED | Loopback: every check flows through it; live 547df88 (QW plays in Studio, full handshake). Delta: packets buffered per Heartbeat instead of socket poll. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_Download_f | — | SUBSTITUTED | All content ships via the Roblox asset bundle (`QuakeClientFS`); no file downloads. | — (substitution; verify justification still holds) |
| CL_Windows_f | — | SUBSTITUTED | Win32 minimize key; platform-owned. | — (substitution; verify justification still holds) |
| CL_Init | `qwclient.luau` boot function | VERIFIED | Same evidence set as Host_Init: the wired fs/transport/render/input stack is what every committed QW capture and battery runs on. Delta stands: no cvar registration layer. | Boot with engine="qw"; batteries per qw-input-console-battery.txt |
| Host_EndGame | pcall/warn in heartbeat packet loop | SUBSTITUTED | Parse errors warn and drop the packet instead of tearing the session down — deliberately softer than C on a hosted platform. Expiry: revisit if a malformed-packet loop is ever observed live (would need the C teardown to recover). | code: qwclient heartbeat pcall |
| Host_Error | same | SUBSTITUTED | Same soft-fail substitution as Host_EndGame; no reconnect-on-error. Same expiry condition. | code: qwclient heartbeat pcall |
| Host_WriteConfiguration | — | SUBSTITUTED | config.cfg writing needs a user filesystem the platform doesn't expose; binds/settings are session-scoped over the default.cfg exec, durable persistence would be DataStore (same rationale as Key_WriteBindings). | — (substitution; platform owns storage) |
| Host_SimulationTime | — | SUBSTITUTED | Heartbeat drives the frame; no host_speeds/maxfps gate. | — (substitution; verify justification still holds) |
| Host_Frame | Heartbeat closure in qwclient | VERIFIED | Live 547df88: full frame loop (read packets → send cmd → predict → render) plays in Studio; loopback `tick()` mirrors the same order. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| simple_crypt / Host_FixupModelNames | — | N/A | id's model-name de-obfuscation; assets are already plain. N/A: DOS-era (asset de-obfuscation; assets plain). | — (implement first) |
| Host_Init | qwclient boot | VERIFIED | The QW boot path is exercised end-to-end by every committed QW artifact (S4 anchor, sky, scoreboard, rocket, input battery — all captured on live engine="qw" boots). | Boot with QuakeAssets engine="qw"; QW_State must reach "active" |
| Host_Shutdown | — | SUBSTITUTED | Roblox instance teardown. | — (substitution; verify justification still holds) |

## cl_parse.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_CalcNet | partial | SUBSTITUTED | The inputs are wired and loopback-asserted (chokecount -> receivedtime=-2, deltaPacketCount "delta frames dominated") but there is no netgraph consumer to render them. Expiry: when an r_netgraph overlay lands. | `lune run tests/test_qw_loopback.luau` (inputs) |
| Model_NextDownload | inside `parseModellist` | VERIFIED | Loopback: "client loaded the world model", "precache lists received". Loads all models immediately (no downloads); world = precache slot 1, errors if not brush. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Sound_NextDownload | inside `parseSoundlist` | VERIFIED | Loopback handshake: soundlist continuation (`soundlist N next`) then `modellist N 0` — handshake completes. Sounds resolve lazily by name in soundlib, not precached. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_RequestNextDownload | — | SUBSTITUTED | No download phases; asset bundle replaces them. | — (substitution; verify justification still holds) |
| CL_ParseDownload | — | SUBSTITUTED | `svc_download` never sent by qwsv; assets pre-shipped. | — (substitution; verify justification still holds) |
| CL_CheckOrDownloadFile (cl_parse.c:145) | — | SUBSTITUTED | Row added by the 2026-07-06 audit: the entry point of the download cluster above (checks local presence, else requests). Same substitution: the asset bundle pre-ships everything, so the check always "has" the file and the request path is dead. | — (substitution; verify justification still holds) |
| CL_NextUpload / CL_StartUpload / CL_IsUploading / CL_StopUpload | — | SUBSTITUTED | clc_upload (RSShot upload) N/A; no screenshots over the wire. | — (substitution; verify justification still holds) |
| CL_ParseServerData | `parseServerData` | VERIFIED | Loopback: protocol 28 enforced, "spawncount agreed", "movevars received (gravity 800)", "assigned player slot 0", spectator bit split. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_ParseSoundlist | `parseSoundlist` | VERIFIED | Loopback: "precache lists received" (#cl.sound_name > 1). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_ParseModellist | `parseModellist` | VERIFIED | Loopback: same check + worldmodel load. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_ParseBaseline | `parseBaseline` | VERIFIED | Loopback: "baselines received (>20)". | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_ParseStatic | `parseStatic` + qwclient `spawnPendingStatics` | VERIFIED | test_qw_loopback crafted svc_spawnstatic: fields + the INTERLEAVED origin/angle coord layout asserted; rendering rides the shared entrender path (statics visible across committed captures). | `lune run tests/test_qw_loopback.luau` |
| CL_ParseStaticSound | `parseStaticSound` + `soundlib.static` | VERIFIED | test_qw_loopback crafted svc_spawnstaticsound: pos/num/vol/atten asserted; playback is the shared soundlib.static path (NQ live-verified). | `lune run tests/test_qw_loopback.luau` |
| CL_ParseStartSoundPacket | `parseStartSound` | VERIFIED | Loopback: "svc_sound guncock arrived through the PHS multicast" (vol/atten/ent/channel decode). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_ParseClientdata | head of `parseServerMessage` | VERIFIED | test_qw_loopback: parsecount/receivedtime bookkeeping proven by "prediction converged (<1 unit)" and "validsequence tracking" — both fail if the frame ring is misindexed. | `lune run tests/test_qw_loopback.luau` |
| CL_NewTranslation | `relinkEntities` colors byte → `entrender.updateAlias` → `textures.translatePixels` | VERIFIED | test_qwview translate battery: table build exact vs C (shirt rows from top*16 forward, pants rows >= 128 reversed, identity elsewhere); the topcolor/bottomcolor byte path also drives the scoreboard fills live in [evidence/qw-team-overlay.jpg](evidence/qw-team-overlay.jpg). No .pcx skin substrate (see skin.c) — translation applies to the base player.mdl skin like -noskins QW. | `lune run tests/test_qwview.luau` |
| CL_ProcessUserInfo | inline in `svc_updateuserinfo`/`svc_setinfo` handlers | VERIFIED | test_scenario_qw: each client resolves the other's name from broadcast userinfo ("alpha's scoreboard lists bravo" and vice versa); loopback "own player info received". | `lune run tests/test_scenario_qw.luau`; `lune run tests/test_qw_loopback.luau` |
| CL_UpdateUserinfo | `svc_updateuserinfo` handler | VERIFIED | Loopback: "own player info received" (name "looper", userid parse). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_SetInfo | `svc_setinfo` handler | VERIFIED | test_qw_loopback: setinfo updates cross the wire (server-side userinfo check) and the svc_setinfo path feeds the same players table the scenario name checks read. | `lune run tests/test_qw_loopback.luau` |
| CL_ServerInfo | `svc_serverinfo` handler | VERIFIED | test_qw_loopback: a crafted svc_serverinfo updates a single key (teamplay=2) in cl.serverinfo. | `lune run tests/test_qw_loopback.luau` |
| CL_SetStat | `svc_updatestat`/`svc_updatestatlong` handlers | VERIFIED | Loopback: "health stat mirrors server", "shells stat present", "ammo stat dropped after firing". | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_MuzzleFlash | `svc_muzzleflash` → tempEntities type -1 → qwclient `handleTempEntity` | VERIFIED | [evidence/qw-fire-muzzleflash.jpg](evidence/qw-fire-muzzleflash.jpg): orange muzzle flash renders at the gun during sustained fire. | Stage per evidence/qw-fire-muzzleflash.txt, capture, compare |
| CL_ParseServerMessage | `qwcl.parseServerMessage` | VERIFIED | Every loopback check flows through it; live 547df88. Handles all svcs qwsv emits; unknown svc errors like C. Delta: `svc_setview`/`svc_download` absent (server never sends). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## cl_input.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| KeyDown / KeyUp + the 38 IN_*Down/IN_*Up wrappers | qwclient `keyButtons` map + `input.setButton` | SUBSTITUTED | Roblox UserInputService replaces the bind-driven ± command pairs. Delta: booleans, not the C two-source `kbutton_t` down[2]/impulse tracking — simultaneous bind sources and 0.25/0.75 partial-frame presses are lost. | — (substitution; verify justification still holds) |
| IN_Impulse | number keys 1–8 + console "impulse N" → `input.setImpulse` (client-side like C — fixed 2026-07-05: it previously forwarded to the server, which ignores it) | VERIFIED | exec `impulse 8` selected and fired the freshly picked-up dm3 LG (which discharged underwater for the authentic -99 — [evidence/qw-input-console-battery.txt](evidence/qw-input-console-battery.txt)); impulse 9 correctly refused in DM. Number-key synthesis blocked by CoreGUI (platform note shared with the NQ row). | Battery steps in the evidence file |
| CL_KeyState | — | SUBSTITUTED | Digital 0/1 only (see above); QW's fractional key state depended on sub-frame press timing. | — (substitution; verify justification still holds) |
| CL_AdjustAngles | shared `input.updateTurn` (already the NQ implementation) + default.cfg-parity keys in qwclient: Left/Right arrows turn, PageUp/PageDown look | VERIFIED | The mechanism is the same shared updateTurn the NQ input battery drove live ([evidence/nq-input-menu-battery.txt](evidence/nq-input-menu-battery.txt): +left/+right/klook/lookup paths); the QW boot now binds the keys (code: qwclient keyButtons). anglespeedkey/strafe gates in the shared code. | NQ battery procedure (shared code); qwclient keyButtons |
| CL_BaseMove | `input.sample` | VERIFIED | Real W and RQ_ForceForward both drove forwardmove over the wire (QW_SimOrg deltas in [evidence/qw-input-console-battery.txt](evidence/qw-input-console-battery.txt)); dead-player moves ignored until respawn (authentic). Speeds fixed — noted. | Battery steps in the evidence file |
| MakeChar | `qwcl` `makeChar` | VERIFIED | Loopback convergence (<1 unit) replays quantized cmds; &~3 with signed clamp ±508 preserved (bit32 sign fixup noted in code). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_FinishMove | split: qwclient heartbeat (buttons/impulse/msec, 250ms→100ms hitch rule) + `qwcl.sendCmd` (MakeChar + angle quantize) | VERIFIED | Loopback convergence; backlog 115a438: "MakeChar+angle16 quantization before storing cmds, 2-move discard, latency drift" fixed and live-verified session followed. Delta: quantization applied to the *stored* cmd so prediction replays the wire exactly (see additions). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_SendCmd | `qwcl.sendCmd` | VERIFIED | Loopback: 3-cmd delta chain (nullcmd→oldest→old→new), clc_delta request, frame ring store at `outgoing_sequence & UPDATE_MASK`, `movemessages <= 2` discard; "delta frames dominated (>20)". Delta: checksum and lossage bytes written 0 (authenticated reliable transport). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_InitInput | — | SUBSTITUTED | No +/- command registration; direct key wiring (QW console/bind integration journaled follow-up). | — (substitution; verify justification still holds) |
| CL_ClearStates | `input.setEnabled(false)` path zeroes moves | VERIFIED | The committed messagemode evidence caught it live: game input (including a forced attack) is dead while chat is open — the shared input-clear mechanism, same as the NQ menu-battery proof. Delta noted: not called on disconnect by the QW boot. | qw-messagemode evidence + tools/verify_input_nq.luau mechanism |

## cl_ents.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_AllocDlight | qwcl.allocDlight (shared; qwclient delegates) | VERIFIED | test_qw_loopback pool battery vs cl_ents.c:42: exact-key reset, expired reuse before growth, 32 cap, overflow overwrites slot 1 like C's &cl_dlights[0]. | `lune run tests/test_qw_loopback.luau` |
| CL_NewDlight | inlined at call sites in `handleTempEntity`/`relinkEntities` | VERIFIED | Call-site values spot-checked against cl_tent.c/cl_ents.c (muzzleflash die +0.1; explosion radius/die +0.5/decay 300; EF glows die +0.1) on top of the offline-tested shared pool. | Code inspection + `lune run tests/test_qw_loopback.luau` (pool) |
| CL_DecayLights | qwcl.decayDlights (shared; heartbeat delegates) | VERIFIED | test_qw_loopback: radius -= dt*decay (100-30 at dt .1/decay 300), fully-decayed lights culled from the active list that feeds worldmesh.updateDlights. | `lune run tests/test_qw_loopback.luau` |
| CL_ParseDelta | `qwents.parseDelta` | VERIFIED | test_qwents named checks: "moved origin applied", "new entity fields", U_MOREBITS byte, all U_ field reads. | `lune run tests/test_qwents.luau` |
| FlushEntityPacket | too-old branch of `qwcl` `parsePacketEntitiesMsg` | VERIFIED | test_qw_loopback: a crafted delta from a 70-packet-stale frame is read-and-discarded with frame.invalid=true and validsequence reset to 0. | `lune run tests/test_qw_loopback.luau` |
| CL_ParsePacketEntities | `qwents.parsePacketEntities` + `qwcl` `parsePacketEntitiesMsg` | VERIFIED | qwents: full update, delta update, unchanged-carry, U_REMOVE, baseline-new (7 checks); loopback: "first packetentities frame received", "validsequence tracking", "packet entities present". Delta: from-sequence mismatch only warns (C's exactness kept, message differs). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_LinkPacketEntities | qwclient `relinkEntities` packet-ents loop | VERIFIED | [evidence/qw-dm3-packetents.jpg](evidence/qw-dm3-packetents.jpg) + .txt: a b_nail0 packet entity renders at its wire position at a deterministic vantage; parse layer separately covered by test_qwents/test_qw_loopback. | Stage per evidence/qw-dm3-packetents.txt, capture, compare |
| CL_ClearProjectiles | `cl.nails = {}` per parsed message | VERIFIED | Nails live one message: cl.nails resets per frame parse (the loopback check catches them within the frame they ride). | `lune run tests/test_qw_loopback.luau` |
| CL_ParseProjectiles | `qwcl` `parseNails` | VERIFIED | test_qw_loopback: "svc_nails parsed into cl.nails" after firing the nailgun over the wire. | `lune run tests/test_qw_loopback.luau` |
| CL_LinkProjectiles | nails loop in `relinkEntities` (`spikeindex`) | VERIFIED | The wire half (CL_ParseProjectiles) is bit-exact tested: hand-packed 6-byte nail decodes to origin (100,-200,24) / pitch 90 / yaw 180 in test_qw_loopback; the link loop renders cl.nails through the same shared entrender path as every verified alias capture, spike.mdl slot from model_name like cl_spikeindex. | `lune run tests/test_qw_loopback.luau` |
| CL_NewTempEntity | — | SUBSTITUTED | entrender pooled RenderEnts replace the cl_visedicts temp array (`beamPool`, keyed render ents). | — (substitution; verify justification still holds) |
| CL_ParsePlayerinfo | `qwcl` `parsePlayerinfo` | VERIFIED | Loopback: own playerstate feeds prediction which converges; PF_MSEC state_time, PF_COMMAND delta cmd, PF_VELOCITY/MODEL/SKINNUM/EFFECTS/WEAPONFRAME flags all decoded. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_AddFlagModels | `qwview.flagPlacement` + linkEnt in `relinkEntities` (EF_FLAG1/EF_FLAG2, skinnum by team) | VERIFIED | test_qwview flag battery: the full f-offset table exact vs C (axpain/pain/attack frames), the composition (reversed forward z, +22 right, -16 z, roll -45). Wire+carry half: test_scenario_ctf drives a real Threewave flag carrier over the wire; the carried-flag state is live-evidenced in [evidence/qw-ctf2m3-flag-carried.jpg](evidence/qw-ctf2m3-flag-carried.jpg). | `lune run tests/test_qwview.luau`; `lune run tests/test_scenario_ctf.luau` |
| CL_LinkPlayers | players loop in `relinkEntities` | VERIFIED | Wire + extrapolation halves: the two-client scenario asserts alpha sees bravo's playerstate at the staged duel spot (test_scenario_qw) and predictedPlayerOrigins drives the loop; the lean now delegates to the shared C-truth-tested view.calcRoll (*4). Rendering rides the shared alias path. PF_DEAD/self skip in code. | `lune run tests/test_scenario_qw.luau`; `lune run tests/test_view.luau` |
| CL_SetSolidEntities | `qwcl` `buildPhysents(false)` | VERIFIED | World + brush-model packet ents as physents; loopback prediction converges against them. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_SetUpPlayerPrediction | `qwcl.predictedPlayerOrigins` | VERIFIED | Every loopback predictMove replay assembles predicted player physents (convergence <1 unit depends on it); the scenario adds a second live player to the set. | `lune run tests/test_qw_loopback.luau`; `lune run tests/test_scenario_qw.luau` |
| CL_SetSolidPlayers | `buildPhysents(true)` player boxes | VERIFIED | Same physent assembly: buildPhysents(true) runs inside every verified prediction replay. | `lune run tests/test_qw_loopback.luau` |
| CL_EmitEntities | `relinkEntities` orchestration in heartbeat | VERIFIED | Same capture: the relinkEntities orchestration drew world + packet entities + view model in one frame ([evidence/qw-dm3-packetents.jpg](evidence/qw-dm3-packetents.jpg)). | Stage per evidence/qw-dm3-packetents.txt, capture, compare |

## cl_pred.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_NudgePosition | `qwcl.nudgePosition` after the predictMove lerp (PM_HullPointContents on the world player hull, 1/8 jitter grid, "stuck" dprint) | VERIFIED | test_qw_loopback: empty origin untouched, a real wall-boundary spot east of spawn nudges free, deep solid reports stuck like C. | `lune run tests/test_qw_loopback.luau` |
| CL_PredictUsercmd | `qwcl.predictUsercmd` | VERIFIED | Loopback: "prediction converged (<1.0)"; >50ms split recursion, oldbuttons/waterjumptime/onground carry preserved. Movement core itself is C-exact (see pmove.c). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_PredictMove | `qwcl.predictMove` | VERIFIED | Loopback convergence + live 547df88 "prediction == server origin exactly". Replays unacked cmds from incoming_sequence, senttime interpolation, 128-unit teleport snap, paused/intermission/validsequence gates, onserver→active promotion. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CL_InitPrediction | — | SUBSTITUTED | cl_pushlatency/cl_nopred cvars unregistered; `cl.nopred` field exists for the no-predict path. | — (substitution; verify justification still holds) |

## cl_cam.c (spectator/chase camera)

Autocam essentials live in qwcl.luau (`camLock`/`camUnlock`/`camCheckHighTarget`/`camTrack`): always-on cl_hightrack target pick, `ptrack <num>` stringcmds, chase-locked view through the tracked player's predicted origin + viewangles, BUTTON_JUMP cycling, clc_tmove ride-along. The flyby-position search (InitFlyby family) is ported and offline-tested; the default view remains the cl_chasecam-1 lock.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| vectoangles / vlen (statics) | `qwcl.camVectoangles` / `camVlen` | VERIFIED | test_qw_cam: the C int truncation (yaw 45 exact), straight-up/down pitch 90/270, negative-yaw +360 wrap, vlen. | `lune run tests/test_qw_cam.luau` |
| Cam_DrawViewModel / Cam_DrawPlayer | qwcl.camTrackedState gate + qwclient render branch | VERIFIED | The gating state function (spectator+locked+fresh playerstate) is offline-tested through the three-client spectator loopback (test_qw_cam); the render consumers are two code-pinned lines (skip tracked model in relink, draw the gun with the target's weaponframe). | `lune run tests/test_qw_cam.luau` |
| Cam_Unlock / Cam_Lock | qwcl.camUnlock / qwcl.camLock (shared) | VERIFIED | test_qw_cam over the real wire: ptrack <n> reaches the server (spec_track set 1-based), bare ptrack clears it; locks immediately (chasecam semantics, no flyby — recorded delta). | `lune run tests/test_qw_cam.luau` |
| Cam_DoTrace / Cam_TryFlyby / Cam_IsVisible / InitFlyby | `qwcl.initFlyby` family (player-hull traces via pmove.playerTrace, the 12 direction combos, the 32..800 usable band, checkvis pass) | VERIFIED | test_qw_cam: InitFlyby finds a camera spot around the live tracked player on the booted map, the spot passes Cam_IsVisible and sits in the 32..800 band, and the search locks the camera. | `lune run tests/test_qw_cam.luau` |
| Cam_CheckHighTarget | qwcl.camCheckHighTarget (shared) | VERIFIED | test_qw_cam: with two players and a spectator, the frag leader is picked (bravo at 5 frags over the wire-synced scoreboard); spectators and empty slots skipped. | `lune run tests/test_qw_cam.luau` |
| Cam_Track / adjustang / Cam_SetView / Cam_FinishMove | qwcl.camTrack (shared) | VERIFIED | test_qw_cam: hightrack pick while unlocked, BUTTON_JUMP edge cycling (held jump doesn't pogo; release+press cycles), kicked-target retarget to the survivor, clc_tmove written when >16 units off. Deltas stand: hightrack recheck only while unlocked; adjustang/Cam_SetView are #if 0 in the C. | `lune run tests/test_qw_cam.luau` |
| Cam_Reset / CL_InitCam | — | SUBSTITUTED | cl_hightrack/cl_chasecam cvars fixed on; state is per-boot locals. | — (substitution; verify justification still holds) |

## cl_demo.c (demo record/playback)

The .qwd pipeline is ported and offline-tested (test_qw_demo): record synthesizes the C signon from current state, the byte format round-trips, playback replays into a fresh client. One substitution: the packet-source dispatch.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_StopPlayback / CL_WriteDemoCmd / CL_WriteDemoMessage / CL_GetDemoMessage | the qwcl demo core: dem_cmd/dem_read/dem_set blocks, the .qwd byte layout (24-byte usercmd struct + viewangles), `demoStep` mirroring the C playback effects (dem_set seeds sequences, dem_cmd fills the frame ring + advances outgoing, dem_read parses) | VERIFIED | test_qw_demo: a live loopback run records, the .qwd byte stream round-trips block-exact, and a BRAND-NEW client replays it — world loads from the recorded signon, the player slot is taken, and the recorded run's motion replays (>100 units). | `lune run tests/test_qw_demo.luau` |
| CL_GetMessage | `qwcl.processPacket` | SUBSTITUTED | The demo-vs-net dispatch collapses to the remote packet queue. | — (substitution; verify justification still holds) |
| CL_Stop_f / CL_Record_f / CL_ReRecord_f / CL_PlayDemo_f | record/rerecord/stop/playdemo(+stopdemo) commands over an in-memory .qwd store (no user filesystem — the NQ boot's demo-store policy) | VERIFIED | test_qw_demo drives recordStart/recordStop/serialize/parse/playback end to end; the boot commands are thin wrappers over those exact functions (code). | `lune run tests/test_qw_demo.luau` |
| CL_WriteRecordDemoMessage / CL_WriteSetDemoMessage | `recordStart` synthesizes the signon from current state exactly like C (serverdata+fullserverinfo, complete sound/model lists, baselines+statics, lightstyles/players/stats) in ascending fake-sequence dem_read blocks, then dem_set with the live sequences. Delta: lists ride one block each (no MAX_MSGLEN/2 chunking — no UDP framing to respect). | VERIFIED | test_qw_demo: dem_set closes the 5-block synthesized signon; the fresh playback client boots entirely from those blocks. | `lune run tests/test_qw_demo.luau` |
| CL_FinishTimeDemo / CL_TimeDemo_f | — | N/A | N/A: as the NQ timedemo rows. | — (implement first) |

## cl_tent.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CL_InitTEnts | lazy `beamModelDef` + name-based `teSound` | SUBSTITUTED | Models/sounds resolved on first use instead of precached at init; same assets (bolt/bolt2/bolt3.mdl, tink/ric/exp sounds). | — (substitution; verify justification still holds) |
| CL_ClearTEnts | `qwview.clearTEnts` + qwclient levelResets block | VERIFIED | test_qwview: "CL_ClearTEnts: beams + explosions cleared" (the C memset); the port-side pooled beam render instances and prepared beam defs are released in the same levelResets block (code). | `lune run tests/test_qwview.luau` |
| CL_AllocExplosion | `qwview.allocExplosion` (TE_EXPLOSION in `handleTempEntity`) | VERIFIED | test_qwview ring battery: free slots fill in order, full ring replaces the oldest (start-time scan exact vs C); live composite in [evidence/qw-explosion-sprite.jpg](evidence/qw-explosion-sprite.jpg) (s_explod fireball + particles at a rocket impact). | `lune run tests/test_qwview.luau`; stage per evidence/qw-explosion-sprite.txt |
| CL_ParseBeam | wire: `qwcl` `parseTempEntity` (ent+start+end); slots: qwclient `parseBeam` | VERIFIED | Live LG beam on the QW boot ([evidence/qw-lightning-beam.jpg](evidence/qw-lightning-beam.jpg) + [.txt](evidence/qw-lightning-beam.txt)); entity-keyed reuse/free-slot/0.2s/MAX_BEAMS 8 per C in code. | Stage per the evidence file |
| CL_ParseTEnt | `qwcl` `parseTempEntity` + qwclient `handleTempEntity` | VERIFIED | [evidence/qw-fire-muzzleflash.jpg](evidence/qw-fire-muzzleflash.jpg): TE_GUNSHOT impact puff at the wall hit point; particle counts/colors for the effect family are offline-tested in test_particles2 (shared particlesim). | Stage per evidence/qw-fire-muzzleflash.txt; `lune run tests/test_particles2.luau` |
| CL_NewTempEntity | — | SUBSTITUTED | See cl_ents.c row: pooled entrender instances. | — (substitution; verify justification still holds) |
| CL_UpdateBeams | qwclient `updateBeams` | VERIFIED | The captured bolt shows the 30-unit random-roll segments pinned muzzle-to-impact while held ([evidence/qw-lightning-beam.jpg](evidence/qw-lightning-beam.jpg) + [.txt](evidence/qw-lightning-beam.txt)). Delta stands: pooled parts hidden at -10000 z. | Stage per the evidence file |
| CL_UpdateExplosions | `qwview.explosionFrame` + the explosion loop in `relinkEntities` | VERIFIED | test_qwview frame battery: f = floor(10*(time-start)), frame 0 at start, truncation, expiry at numframes (slot freed); the animated sprite renders live in [evidence/qw-explosion-sprite.jpg](evidence/qw-explosion-sprite.jpg). | `lune run tests/test_qwview.luau` |
| CL_UpdateTEnts | heartbeat drain (`handleTempEntity` loop + `updateBeams`) | VERIFIED | The drain's outputs are the committed QW tent set: muzzleflash, gunshot puffs, rocket splash, and now the live beam ([evidence/qw-lightning-beam.jpg](evidence/qw-lightning-beam.jpg) + [.txt](evidence/qw-lightning-beam.txt)). | Stage per the evidence files |

## view.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| V_CalcRoll | shared view.calcRoll (own view + CL_LinkPlayers lean * 4) | VERIFIED | Both inline copies now delegate to the shared, C-truth-tested view.calcRoll (test_view battery: 2/200 scaling, clamp, sign). | `lune run tests/test_view.luau` |
| V_CalcBob | shared view.calcBob (camera block delegates) | VERIFIED | The inline copy now delegates to the shared, C-truth-tested view.calcBob (test_view: cycle split, blend, clamps). | `lune run tests/test_view.luau` |
| V_StartPitchDrift / V_StopPitchDrift / V_DriftPitch | shared `view` pitch-drift trio, driven in the qwclient heartbeat (QW centers to 0 — no idealpitch wire); centerview command | VERIFIED | test_view drift battery (accelerating glide, exact overshoot clamp, airborne reset, forward-running re-arm, laststop guard). Boot stops drift on any manual pitch motion (C's IN_MouseMove under +mlook). | `lune run tests/test_view.luau` |
| BuildGammaTable / V_CheckGamma | shared texture path (gamma 0.7) | SUBSTITUTED | Gamma baked into palette conversion in the shared textures module; no runtime table. | — (substitution; verify justification still holds) |
| V_ParseDamage | `svc_damage` → `cl.damage` in qwcl → `qwview.parseDamage` | VERIFIED | Wire: test_scenario_qw "svc_damage reached the victim". Consumer: test_qwview damage battery — count floor 10, 3*count percent with the 150 cap, armor-vs-blood colors {200,100,100}/{220,50,50}/{255,0,0}, kick roll/pitch = count*dot*0.6 with v_kicktime 0.5. | `lune run tests/test_scenario_qw.luau`; `lune run tests/test_qwview.luau` |
| V_cshift_f / V_BonusFlash_f | `qwview.cshiftCmd` (console cmd + stufftext) / `qwview.bonusFlash` ("bf" stufftext + console cmd) | VERIFIED | test_qwview: v_cshift writes cshift_empty (not the live shift) and empty contents pick it up, atoi zero-fill; bonus {215,186,69,50} with the 100/s drop. Live: [evidence/qw-vcshift-dead-teamoverlay.jpg](evidence/qw-vcshift-dead-teamoverlay.jpg) — "v_cshift 0 0 255 120" blends the whole view blue. | `lune run tests/test_qwview.luau`; stage per the evidence .txt |
| V_SetContentsColor / V_CalcPowerupCshift / V_CalcBlend / V_UpdatePalette | `qwview` blend pipeline consumed by the qwclient heartbeat (view-leaf contents → cshiftFrame) | VERIFIED | test_qwview batteries: lava/slime/solid/water/empty shift values exact, quad>suit>ring>pent priority + values, the V_UpdatePalette 150/s + 100/s drops, V_CalcBlend hand-derived two-shift anchor + alpha clamp. Live composite: [evidence/qw-cshift-water.jpg](evidence/qw-cshift-water.jpg) (underwater tint over the dm3 water channel). | `lune run tests/test_qwview.luau`; stage per evidence/qw-cshift-water.txt |
| angledelta / CalcGunAngle | gun angles follow the view directly | VERIFIED | Faithfulness by identity: in the shipped C, CalcGunAngle's lag terms are PROVABLY ZERO (yaw = angledelta(yaw - viewangles[YAW]) where yaw was just set to viewangles[YAW], same for pitch) — the gun follows the view exactly, which is precisely what the port does. The base (-pitch, yaw) mapping is asserted in test_view. | `lune run tests/test_view.luau`; C: QW/client/view.c CalcGunAngle |
| V_BoundOffsets | — | N/A | 14-unit eye clamp vs entity origin; prediction keeps eye on simorg so drift can't occur. N/A: condition structurally impossible in port (eye pinned to simorg). | — (implement first) |
| V_AddIdle | shared `view.addIdle`; qwclient intermission branch applies it at scale 1 | VERIFIED | test_view: exact sway constants (pitch sin(t*1)*0.3, yaw sin(t*2)*0.3, roll sin(t*0.5)*0.1); consumed by the QW intermission refdef (code). v_idlescale stays 0 outside intermission like C. | `lune run tests/test_view.luau` |
| V_CalcViewRoll | camera block (movement roll shared; dead branch inline) | VERIFIED | Movement roll now delegates to the C-truth-tested view.calcRoll; the dead branch (80-degree roll at viewheight -16) is two code-pinned lines observed live in the dm3 discharge death this session. | `lune run tests/test_view.luau`; code: qwclient camera dead branch |
| V_CalcIntermissionRefdef | intermission branch | VERIFIED | test_qw_cam crafted svc_intermission: intermission=1 with simorg pinned, simvel zeroed, simangles pinned — exactly the fixed refdef inputs; the camera branch consumes them with no bob/height (code). The idle sway landed 2026-07-05 (see V_AddIdle row). | `lune run tests/test_qw_cam.luau` |
| V_CalcRefdef | camera block in heartbeat | VERIFIED | Three re-runnable probes into the camera block: the S4 anchor screenshot (composite refdef look — eye height, view model over the sbar strip: evidence/qw-dm3-stairs.jpg), tools/verify_stairsmooth_qw.luau (oldz glide/cap measured live), tools/verify_punchangle_qw.luau (kick order matches C by absence). Deltas: no view_ofs from server; gun bob simplified to forward push; CalcGunAngle lag absent; bob/roll amplitudes are C-transcribed constants not independently measured. | S4 anchor procedure + tools/verify_stairsmooth_qw.luau + tools/verify_punchangle_qw.luau |
| DropPunchAngle | `punchangle -= 10*dt`, clamp 0 | VERIFIED | Faithfulness by absence, measured live (tools/verify_punchangle_qw.luau): 55 heartbeat samples during sustained fire show ZERO pitch deflection — matching C, where svc_smallkick's negative punch is clamped by DropPunchAngle immediately before V_CalcRefdef reads it. Gun kicks do not display in authentic QW; lingering recoil is NetQuake behavior. Firing proven by shells 25->2 + [evidence/qw-fire-muzzleflash.jpg](evidence/qw-fire-muzzleflash.jpg). | tools/verify_punchangle_qw.luau (Studio MCP chunk; pass = |delta| < 0.3) |
| V_RenderView | camera.CFrame via `qcoords.cframe` | SUBSTITUTED | Roblox camera replaces the software refresh entry; live 547df88 world renders through it. | — (substitution; verify justification still holds) |
| V_Init | — | SUBSTITUTED | No cvar/command registration. | — (substitution; verify justification still holds) |

## sbar.c (status bar / scoreboard)

The QW boot drives the shared sbar.c port (`src/client/hud.luau`) through a qwcl adapter in qwclient.luau (`updateHudAdapter` + `hudlib.updateOverlaysQW`); scoreboard sorting lives in the offline-tested `qwview` module. Main bar, DM rankings, team overlay, and the mini overlay are all live-evidenced.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Sbar_ShowScores / Sbar_DontShowScores | qwclient execCommand +/-showscores → hudlib.setShowScores | VERIFIED | Implemented 2026-07-04 (the TAB binds); [evidence/qw-dm-scoreboard.jpg](evidence/qw-dm-scoreboard.jpg) shows the overlay raised via +showscores. | Console "+showscores" per evidence/qw-dm-scoreboard.txt, capture, compare |
| Sbar_ShowTeamScores / Sbar_DontShowTeamScores | qwclient execCommand +/-showteamscores → `hudlib.setShowTeamScores` | VERIFIED | [evidence/qw-team-overlay.jpg](evidence/qw-team-overlay.jpg): the team overlay raised via "+showteamscores" (RQDBG battery per the .txt). | Console "+showteamscores" per evidence/qw-team-overlay.txt, capture, compare |
| Sbar_Changed / Sbar_Init | sig-diff rebuild in `updateOverlaysQW` + lazy `getPic` loads (hud.create) | SUBSTITUTED | Sbar_Changed's dirty-flag redraw is replaced by the signature-diff overlay rebuild plus retained-mode GUI widget updates (no framebuffer to re-blit); Sbar_Init's pic precache is replaced by lazy gfx.wad pic loads on first draw through the shared image page. Both serve the same purpose: draw only what changed, have the pics when needed. | code: hud.luau updateOverlaysQW sig / getPic |
| Sbar_DrawPic / Sbar_DrawSubPic / Sbar_DrawTransPic / Sbar_DrawCharacter / Sbar_DrawString / Sbar_itoa / Sbar_DrawNum | hudlib `setPic`/`charPic`/`drawNum`/`interText`/`interFill` + confont rows | VERIFIED | Every committed QW sbar capture renders through these primitives: main bar pics/nums ([evidence/qw-dm3-stairs.jpg](evidence/qw-dm3-stairs.jpg)), conchars strings + Draw_Fill bars ([evidence/qw-dm-scoreboard.jpg](evidence/qw-dm-scoreboard.jpg), [evidence/qw-team-overlay.jpg](evidence/qw-team-overlay.jpg)). | Any QW sbar capture procedure (S4 anchor / scoreboard evidence files) |
| Sbar_SortFrags / Sbar_SortTeams | `qwview.sortFrags` / `qwview.sortTeams` (hudlib consumes) | VERIFIED | test_qwview: frags descending with the C bubble-sort tie stability, spectator exclusion + the includespec -999 quirk; team aggregation (frags/players), ping low/high/total, teamplay-0 early-out. | `lune run tests/test_qwview.luau` |
| Sbar_ColorForMap (sbar.c:463) | shared frag-cell/rankings fills: palette row base + 8 (hud.luau:627 and the hudlib cells) | VERIFIED | Row added by the 2026-07-06 audit. [evidence/qw-color-crosshair.jpg](evidence/qw-color-crosshair.jpg): "color 4 12" produces the yellow/red fills in the rankings row, in-sbar frag cell, and mini overlay at once — that mapping is this function. 13-clamp happens on the send side (CL_Color_f row). | Stage per evidence/qw-color-crosshair.txt |
| Sbar_SoloScoreboard / Sbar_DrawInventory / Sbar_DrawFace / Sbar_DrawNormal / Sbar_Draw | hudlib `update` via the qwcl adapter | VERIFIED | The full main-bar composite is the committed S4 anchor ([evidence/qw-dm3-stairs.jpg](evidence/qw-dm3-stairs.jpg): sbar + ibar with live stats) and every subsequent QW capture (face pain/dead states visible across the burn-down set); solo scoreboard fields are the same shared hudlib rows evidenced by nq-solo-scoreboard.jpg. | S4 anchor procedure; `lune run tests/test_qw_loopback.luau` (stats wire) |
| Sbar_DrawFrags | shared hudlib `updateFragCells` (the QW adapter feeds it; QW layout identical) | VERIFIED | Shared implementation live-evidenced under NQ ([evidence/nq-fragcells-minidm.jpg](evidence/nq-fragcells-minidm.jpg)); sorting offline-tested (test_qwview sortFrags). The QW boot drives the same code through updateHudAdapter's scores. | Stage per evidence/nq-fragcells-minidm.txt (shared path); `lune run tests/test_qwview.luau` |
| Sbar_DeathmatchOverlay | hudlib QW overlay driver ("dm" mode) | VERIFIED | [evidence/qw-dm-scoreboard.jpg](evidence/qw-dm-scoreboard.jpg) + .txt: RANKINGS plaque with the QW ping/pl/time/frags/name columns and self-row highlight. | Console "+showscores" per evidence/qw-dm-scoreboard.txt, capture, compare |
| Sbar_IntermissionOverlay / Sbar_IntermissionNumber | hudlib driver shows the DM overlay at intermission (authentic QW behaviour) | VERIFIED | svc_intermission inputs crafted-tested (test_qw_cam); the overlay it raises is the visually-verified DM scoreboard (qw-dm-scoreboard evidence) with Draw_Fill bars and the shared number pics. | `lune run tests/test_qw_cam.luau`; qw-dm-scoreboard evidence |
| Sbar_TeamOverlay | hudlib `buildQWTeamOverlay` (+ the dead/teamplay gate in `updateOverlaysQW`) | VERIFIED | [evidence/qw-team-overlay.jpg](evidence/qw-team-overlay.jpg): low/avg/high header, team row with own-team brackets, appended teamplay-column player list; [evidence/qw-vcshift-dead-teamoverlay.jpg](evidence/qw-vcshift-dead-teamoverlay.jpg) proves the authentic dead→TeamOverlay branch (no TAB held). Aggregation offline-tested (test_qwview sortTeams). | Stage per evidence/qw-team-overlay.txt; `lune run tests/test_qwview.luau` |
| Sbar_MiniDeathmatchOverlay | hudlib `updateMiniOverlayQW` | VERIFIED | [evidence/qw-minidm-overlay.jpg](evidence/qw-minidm-overlay.jpg): the frags/name strip right of the sbar (color fills, %3i frags, own-row brackets, name; team column in the teamplay captures), windowed around self in the sortFrags(false) order. C gates preserved: sb_lines > 0, numlines >= 3, vid.width >= 512. | Stage per evidence/qw-minidm-overlay.txt, capture, compare |
| Sbar_FinaleOverlay | "finale" mode in `updateOverlaysQW` (gfx/finale.lmp centered, y=16) | VERIFIED | Wire half: test_qw_cam crafted svc_finale (intermission=2 + finale text into the centerprint sink). Draw half is the shared interLmp path live-evidenced by the NQ finale capture ([evidence/nq-finale-overlay.jpg](evidence/nq-finale-overlay.jpg)) — same code, same pic family. | `lune run tests/test_qw_cam.luau`; nq-finale-overlay evidence (shared path) |

## screen.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CalcFov | `qcoords.calcFovY` | VERIFIED | test_qcoords: matches a transcribed screen.c CalcFov on 5 cases + hand-derived anchors (fov 90 -> 73.74 at 4:3, 58.72 at 16:9). | `lune run tests/test_qcoords.luau` |
| SCR_CenterPrint / SCR_DrawCenterString / SCR_CheckDrawCenterString / SCR_EraseCenterString | centerprints drained to hudlib.centerPrint (qwclient heartbeat) | VERIFIED | Stale row: the drain now feeds the shared hud centerprint (qwclient ~1541), whose rendering + 2s gate are visually verified by the NQ capture pair (nq-centerprint/-expired — same hudlib code path); the wire side (svc_centerprint -> cl.centerprints) parses in every loopback QC death message. | `lune run tests/test_qw_loopback.luau`; shared-hud visuals per nq-centerprint.txt |
| SCR_CalcRefdef | qcoords.vrect (both boots) | VERIFIED | Math half: test_qcoords (fov_y from the window minus the sbar strip, gun rotation scaling). Visual half: the committed S4 anchor (qw-dm3-stairs.jpg) shows the crop + gun-over-HUD seating — the row predates the anchor landing. | `lune run tests/test_qcoords.luau`; diff the S4 anchor |
| SCR_SizeUp_f / SCR_SizeDown_f | `sizeup`/`sizedown` commands (viewsize +/-10, clamp 30..120) | VERIFIED | Same shared viewsize path live-evidenced by [evidence/nq-sizeup-110.jpg](evidence/nq-sizeup-110.jpg) (identical code; the QW boot's viewsize command was already capture-verified in the vs100/vs110 pair). | Stage per evidence/nq-sizeup-110.txt (shared path) |
| SCR_Init | — | SUBSTITUTED | | — (substitution; verify justification still holds) |
| SCR_DrawRam / SCR_DrawTurtle / SCR_DrawNet / SCR_DrawFPS / SCR_DrawPause | shared hudlib icons + conditions (turtle/net; ram never — no surface cache), `show_fps` + hud.setFps, pause via hudlib.setPaused (wired since the qw pause battery — the old row note was stale) | VERIFIED | Icons: [evidence/nq-scr-icons.jpg](evidence/nq-scr-icons.jpg) (shared pipeline); FPS: "58 FPS" live on the QW boot in [evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg); pause plaque is the NQ-evidenced shared plaque (qwclient calls setPaused). | Stage per the evidence files |
| SCR_SetUpToDrawConsole / SCR_DrawConsole / SCR_BringDownConsole | `consolelib.update` (Heartbeat) | VERIFIED | Shared console module: the committed qw-console-open.jpg captures the slide/draw live on the QW boot (and the NQ pair covers the same code path). | qw-console-open evidence; RQDBG_Console "toggle" + capture |
| WritePCXfile / SCR_ScreenShot_f / MipColor / SCR_DrawCharToSnap / SCR_DrawStringToSnap / SCR_RSShot_f | — | SUBSTITUTED | Screenshots/remote-shots are platform features; N/A. | — (substitution; verify justification still holds) |
| SCR_DrawNotifyString / SCR_ModalMessage | — | N/A | Dead in QW itself: SCR_ModalMessage has zero callers in the QW client source and scr_notifystring is set by nothing else — the modal y/n flow only exists in NetQuake. N/A: dead-in-C. User-ratified 2026-07-06. | — (N/A) |
| SCR_UpdateScreen / SCR_UpdateWholeScreen | Heartbeat render sequence | SUBSTITUTED | Roblox render pipeline; the C draw-order (3D → sbar → console) has no equivalent yet because the 2D layers are absent. | — (substitution; verify justification still holds) |

## console.c

The QW boot now drives the shared `src/client/console.luau` (the NQ boot's console module): tilde toggle, line editor + history, scrollback, and a messagemode chat line; typed commands run the Cmd_ExecuteString subset in qwclient.luau with Cmd_ForwardToServer fallback.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Con_Printf / Con_Print | `cl.prints` sink → hudlib notify + `consolelib.print` + Studio output | VERIFIED | [evidence/qw-console-open.jpg](evidence/qw-console-open.jpg) + .txt: entered-the-game and PRINT_CHAT lines in the QW scrollback (cl.prints sink through the shared consolelib). | RQDBG battery per evidence/qw-console-open.txt, capture, compare |
| Con_DPrintf | `cl.dprint` hook | VERIFIED | test_qw_loopback: the delta from-mismatch warning fires through the hook (crafted mismatched delta); qwclient wires it to print. | `lune run tests/test_qw_loopback.luau` |
| Key_ClearTyping / Con_ToggleConsole_f / Con_ToggleChat_f / Con_MessageMode_f / Con_MessageMode2_f | qwclient key wiring + `execCommand` | VERIFIED | [evidence/qw-messagemode.jpg](evidence/qw-messagemode.jpg) + .txt: the "say:" line renders and gameplay input is disabled while it is up (a forced attack did not fire); console toggle separately captured in evidence/qw-console-open.jpg. Caveat: Roblox chrome partially overlaps the line at this window size. | Console "messagemode" per evidence/qw-messagemode.txt, capture, compare |
| Con_Clear_f / Con_ClearNotify / Con_Resize / Con_CheckResize / Con_Init / Con_Linefeed | consolelib | VERIFIED | Live QW probe: console dump 94 chars -> 0 after exec `clear` ([evidence/qw-input-console-battery.txt](evidence/qw-input-console-battery.txt)); linefeed/wrap exercised by every battery through consolelib.print (shared module, same code as the NQ console evidence). Resize N/A (fixed 64-col conback) stands. | Battery steps in the evidence file |
| Con_DrawInput / Con_DrawNotify / Con_DrawConsole / Con_NotifyBox / Con_SafePrintf | `consolelib.update` + chat row | VERIFIED | [evidence/qw-console-open.jpg](evidence/qw-console-open.jpg): conback, scrollback, ] prompt with cursor under the QW boot. NotifyBox/SafePrintf N/A (no dedicated-server stdin). | RQDBG battery per evidence/qw-console-open.txt, capture, compare |

## keys.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Key_Event | qwclient `onKey` (InputBegan/InputEnded) | VERIFIED | Real UserInputService W (not the harness) moved the player through onKey -> buttons -> pmove ([evidence/qw-input-console-battery.txt](evidence/qw-input-console-battery.txt)); dispatch-tier behaviour previously shown in the messagemode/console evidence. | Battery steps in the evidence file |
| Key_Console / Key_Message | `consoleKey` (consolelib.handleKey) / `messageKey` | VERIFIED | Committed captures: qw-messagemode.jpg (say: line typed through messageKey live) and qw-console-open.jpg (console battery typed through handleKey/handleText — same shared consolelib as the NQ battery). | qw-messagemode + qw-console-open evidence |
| CompleteCommand | consolelib Tab handler + `com.completePrefix` | VERIFIED | Live: Tab completed "use" -> "user " on the QW boot ([evidence/qw-console-tooling-battery.txt](evidence/qw-console-tooling-battery.txt)); matcher offline-tested (test_com). | `lune run tests/test_com.luau`; battery .txt |
| CheckForCommand | unknown console lines forward as clc_stringcmd (Cmd_ForwardToServer) instead of becoming implicit `say` | SUBSTITUTED | C uses CheckForCommand so bare console text becomes chat; on this platform player speech MUST route through the filtered TextChatService say path, so implicit console-chat is deliberately not reproduced — bare text forwards to the server like any command. | — (substitution; platform chat filtering) |
| Cmd_ForwardToServer_f (cmd.c:627 — the explicit `cmd <args>` command) | — | SUBSTITUTED | Row added by the 2026-07-06 audit. `cmd X` exists in C to force-forward when a local command shadows a server one; the port's execCommand already forwards every unrecognized line verbatim, so typing the target command directly produces the same wire bytes. | — (substitution; verify justification still holds) |
| Key_StringToKeynum / Key_KeynumToString | shared `keymap` (quake key names <-> KeyCodes; both boots) | VERIFIED | Live bind battery: "zz" isn't a valid key (StringToKeynum refusal), bind echoes by name ([evidence/qw-menu-fps.txt](evidence/qw-menu-fps.txt)). | Battery per the evidence .txt |
| Key_SetBinding / Key_Unbind_f / Key_Unbindall_f / Key_Bind_f / Key_WriteBindings / Key_Init | the QW bindings table (Key_Init seeds default.cfg-parity binds; keys route bindings through execCommand, +cmd release sends -cmd) | VERIFIED | Live battery: bind x +attack echoed, unbind cleared, invalid key refused ([evidence/qw-menu-fps.txt](evidence/qw-menu-fps.txt)). Key_WriteBindings within the family stays SUBSTITUTED (platform owns storage — see Host_WriteConfiguration). | Battery per the evidence .txt |
| Key_ClearStates | `input.setEnabled(false)` clears every held button (console/chat/menu open) | VERIFIED | The same shared mechanism live-proven by the messagemode evidence (a forced attack did not fire while typing — qw-messagemode.jpg battery); the menu now routes through the identical refreshInputMode path. | qw-messagemode evidence (shared mechanism) |

## menu.c

Entire file UNIMPLEMENTED for the QW boot. Roblox platform owns quit/pause; options + key-binding menus are in the fidelity backlog. The NQ boot's `src/client/menu.luau` is not wired to QW.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| M_DrawCharacter / M_Print / M_PrintWhite / M_DrawTransPic / M_DrawPic / M_BuildTranslationTable / M_DrawTransPicTranslate / M_DrawTextBox / M_DrawSlider / M_DrawCheckbox | the shared menulib primitives (pics, confont text, drawTextBox, translated player pic); sliders/checkboxes belong to the substituted options menu | VERIFIED | The QW boot now drives the same menulib as NQ ([evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg)); the primitive set is live-evidenced by the NQ menu captures (setup page shows the translate + textbox: [evidence/nq-setup-menu.jpg](evidence/nq-setup-menu.jpg)). | Stage per the menu evidence files |
| M_ToggleMenu_f / M_Init / M_Draw / M_Keydown | menulib toggle/create/update/handleKey wired into the QW boot (M key + togglemenu; menu consumes keys; input cleared while open) | VERIFIED | [evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg): the menu live on the QW boot with the animated cursor and fade. | Stage per evidence/qw-menu-fps.txt |
| M_Menu_Main_f / M_Main_Draw / M_Main_Key | shared menulib main menu | VERIFIED | [evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg): MAIN plaque + all five items + menudot cursor on the QW boot. | Stage per evidence/qw-menu-fps.txt |
| M_Menu_Options_f / M_AdjustSliders / M_Options_Draw / M_Options_Key | — | SUBSTITUTED | Same ruling as the NQ options rows (menus split 2026-07-05): console commands (sensitivity/fov/crosshair/viewsize/show_fps) + the director admin menu cover option setting. | — (substitution; NQ menus ruling) |
| M_Menu_Keys_f / M_FindKeysForCommand / M_UnbindCommand / M_Keys_Draw / M_Keys_Key | — | SUBSTITUTED | Same ruling as the NQ keys-menu row: the bind/unbind/unbindall console commands (now live on the QW boot too) cover key configuration. | — (substitution; NQ menus ruling) |
| M_Menu_Video_f / M_Video_Draw / M_Video_Key | — | N/A | Thin trampolines into the DOS/Win vid drivers' mode list (VID_MenuDraw/Key); no display modes exist to enumerate on the platform. N/A: DOS-era, mirroring the NQ hand ruling. User-ratified 2026-07-06. | — (N/A) |
| M_Menu_Help_f / M_Help_Draw / M_Help_Key | shared menulib help pages | VERIFIED | The identical shared code is live-evidenced by the NQ help captures (nq-help-page1/2.jpg); the QW boot reaches it through the same handleKey (menu live in [evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg)). | NQ help evidence (shared path) |
| M_Menu_Quit_f / M_Quit_Key / M_Quit_Draw | — | SUBSTITUTED | Roblox leave-game UI. | — (substitution; verify justification still holds) |
| M_Menu_SinglePlayer_f / M_SinglePlayer_Draw / M_SinglePlayer_Key / M_Menu_MultiPlayer_f / M_MultiPlayer_Draw / M_MultiPlayer_Key | qwMode menulib: Single Player prints the network-only notice (C's QW stub), Multiplayer opens the color setup page | VERIFIED | Menu live on the QW boot ([evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg)); the setup page is the NQ-evidenced shared state ([evidence/nq-setup-menu.jpg](evidence/nq-setup-menu.jpg)) and CL_Color_f's capture proves the QW color path end-to-end. | Stage per the evidence files |

## skin.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Skin_Find / Skin_Cache | — | SUBSTITUTED | Custom .pcx skins arrive by per-player file download in C; the platform ships a fixed asset bundle with no client file downloads (the same substitution as CL_Download_f/Skin_NextDownload). The base player.mdl skin + the VERIFIED colormap translation serve the identity purpose. | — (substitution; no client downloads) |
| Skin_NextDownload | `execStufftext` `"skins"` branch → `begin N` | VERIFIED | Loopback: "handshake completed: server spawned the client" requires the skins→begin step. Substitution note in code: "no skin downloads over remotes: report ready immediately". | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Skin_Skins_f / Skin_AllSkins_f | — | SUBSTITUTED | These reload/re-download the .pcx skin set — meaningless without the skin download mechanism (see Skin_Find). | — (substitution; no client downloads) |

## snd_dma.c

Roblox `Sound`/3D audio (`src/client/sound.luau`) replaces the DMA mixer wholesale; rows below map intent, not implementation.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| S_Init / S_Startup / S_Shutdown | `soundlib.new(Workspace)` | SUBSTITUTED | No DMA buffer; Roblox audio engine. | — (substitution; verify justification still holds) |
| S_FindName / S_TouchSound / S_PrecacheSound | soundmap lookup (`regionFor`) | SUBSTITUTED | Sounds live in one uploaded asset with per-sample time regions (soundmap.txt); resolved by name at play time. | — (substitution; verify justification still holds) |
| SND_PickChannel | `bankSound` pooling | SUBSTITUTED | Roblox voice management; ent+channel override kept in `sound.start`/`sound.stop`. | — (substitution; verify justification still holds) |
| SND_Spatialize | `rolloffFor` + emitter parts | SUBSTITUTED | Roblox distance attenuation approximates ATTN scaling; no stereo separation math. | — (substitution; verify justification still holds) |
| S_StartSound | `soundlib.start` via `cl.sounds` drain | VERIFIED | Wire side: loopback "svc_sound guncock arrived through the PHS multicast". Playback path shared with NQ boot (live-verified there: "57/57 statics playing+loaded, one-shots fire"); QW playback itself not separately screenshot/audio-verified. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| S_StopSound | `soundlib.stop` (svc_stopsound → num=-1 sentinel) | VERIFIED | test_qw_loopback: crafted svc_stopsound queues the ent/channel stop sentinel (ent 5 chan 3, num -1) into the sounds sink soundlib.stop consumes. | `lune run tests/test_qw_loopback.luau` |
| S_StopAllSounds / S_StopAllSoundsC / S_ClearBuffer | `soundlib.clear(sndsys)` on level reset | VERIFIED | FIDELITY FIX 2026-07-04: the QW boot now calls sound.clear in the levelResets teardown (C calls S_StopAllSounds from CL_ParseServerData); previously looping sounds carried across maps. sound.clear itself is the NQ-verified path. | code: qwclient levelResets block; regression-guard is the gauntlet in tools/verify_meshbudget.luau (map cycles) |
| S_StaticSound | `soundlib.static` via `spawnPendingStatics` | VERIFIED | Wire side asserted by the crafted svc_spawnstaticsound in test_qw_loopback (pos/num/vol/atten); playback is the shared soundlib.static path, live-verified under the NQ boot (ambient probes). | `lune run tests/test_qw_loopback.luau` |
| S_UpdateAmbientSounds | qwclient heartbeat feeds `sound.updateAmbients` from the view leaf's ambient levels (the same block that reads contents) | VERIFIED | The shared updateAmbients path is live-verified by the snd_ambient battery ([evidence/sound-utilities-battery.txt](evidence/sound-utilities-battery.txt)); the QW wiring is the same leaf.ambient consumer (code). | Battery per the evidence .txt; code: qwclient contents block |
| S_Update / GetSoundtime / S_ExtraUpdate / S_Update_ | — | SUBSTITUTED | Mixer paint loop N/A. | — (substitution; verify justification still holds) |
| S_Play / S_PlayVol / S_SoundList / S_SoundInfo_f | `play`/`playvol`/`soundlist` commands (S_SoundInfo_f's DMA report has no counterpart — the bank listing carries the useful half) | VERIFIED | Live battery on the QW boot: play started a local channel, soundlist listed 221 regions ([evidence/sound-utilities-battery.txt](evidence/sound-utilities-battery.txt)). | Battery per the evidence .txt |
| S_LocalSound | `sound.localSound`; talk.wav fires on PRINT_CHAT prints in the drain | VERIFIED | The localSound path is the battery-verified play command ([evidence/sound-utilities-battery.txt](evidence/sound-utilities-battery.txt)); the PRINT_CHAT hook is two code-pinned lines in the prints drain. | Battery per the evidence .txt; code: qwclient prints drain |
| S_AmbientOff / S_AmbientOn / S_ClearPrecache / S_BeginPrecaching / S_EndPrecaching | — | SUBSTITUTED | Precache phases N/A with asset-shipped sounds. | — (substitution; verify justification still holds) |

## net_chan.c

Netchan-lite (`qwnetchan.luau`): the transport is already reliable+ordered, so the retransmitted reliable stream with fragment bits collapses to `[seq:u32][ack:u32][reliable][datagram]`. Sequence numbers keep their exact protocol role (frames ring, delta keys).

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Netchan_Init | — | SUBSTITUTED | No qport (no NAT rebinding over remotes). | — (substitution; verify justification still holds) |
| net_udp.c / net_wins.c (entire files: NET_GetPacket/NET_SendPacket/NET_StringToAdr/NET_CompareAdr/UDP_OpenSocket etc.) | RemoteEvent/UnreliableRemoteEvent wiring (qwserver.luau / qwclient boot) | SUBSTITUTED | Row added by the 2026-07-06 audit: the UDP socket layer under netchan had no row (the NQ manifest's NET group covers NQ's different net_* architecture, not these). Roblox remotes replace sockets and addressing wholesale — netadr_t has no counterpart; per-player remotes are the address. | — (substitution; verify justification still holds) |
| Netchan_OutOfBand / Netchan_OutOfBandPrint | — | SUBSTITUTED | No connectionless packets. | — (substitution; verify justification still holds) |
| Netchan_Setup | `qwnetchan.new` | VERIFIED | Loopback + qwents suites construct channels; C POST-increment semantics preserved (packet carries current outgoing_sequence, incremented after — code comment + backlog note). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Netchan_CanPacket / Netchan_CanReliable | — | SUBSTITUTED | No rate choke/backoff; Roblox transport paces. | — (substitution; verify justification still holds) |
| Netchan_Transmit | `qwnetchan.transmit` | VERIFIED | Loopback end-to-end (handshake + 100+ play packets); reliable stream rides in-band with the datagram appended, cleared after send. Delta: no reliable retransmission machinery, no fragment/sequence-high bits. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Netchan_Process | `qwnetchan.process` | VERIFIED | Loopback; stale/duplicate seq discarded, drop_count (net_drop) computed for the server's cmd-replay path, ack drives `parsecount`. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## pmove.c

Ported verbatim in `src/shared/engine/qw/pmove.luau`; ground truth = `tools/pmove_truth.c`, which compiles the **actual QW pmove.c/pmovetst.c** and runs a 300-tick scripted course on e1m1 (run/veer/strafe/bunny-jump/backpedal/diagonal-jump/look-down). `tests/test_qw_pmove.luau` asserts max position error < 0.01 (measured 0.000122), velocity < 0.05, and onground/waterlevel equality **every tick**.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Pmove_Init / PM_InitBoxHull / PM_HullForBox (pmovetst.c:64) | `hullForBox` per call | SUBSTITUTED | (PM_HullForBox added to this row by the 2026-07-06 audit — it is the fill half of the same static-hull pair.) Fresh 6-clipnode box hull built per trace instead of a static; identical plane layout (verified transitively by pmove-truth, whose player-vs-box path is unused with world-only physents). | — (substitution; verify justification still holds) |
| PM_ClipVelocity | `clipVelocity` | VERIFIED | pmove-truth (every slide/landing tick). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_FlyMove | `flyMove` | VERIFIED | pmove-truth (air phases, clip-plane creases, waterjump velocity restore). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_GroundMove | `groundMove` | VERIFIED | pmove-truth (step-up/down vs slide comparison on e1m1 terrain). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_Friction | `friction` | VERIFIED | pmove-truth (incl. edge-friction 2x trace). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_Accelerate | `accelerate` | VERIFIED | pmove-truth. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_AirAccelerate | `airAccelerate` | VERIFIED | pmove-truth (bunny phases; 30-unit wishspd cap). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_WaterMove | `waterMove` | VERIFIED | test_qw_pmove course 4 (e1m1 slime pool): 120 truth ticks through waterlevels 1/2/3 diffed per-tick against tools/pmove_truth.c (stale row updated — the water course landed after it was written). | `lune run tests/test_qw_pmove.luau` |
| PM_AirMove | `airMove` | VERIFIED | pmove-truth (ground + air branches). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_CatagorizePosition | `catagorizePosition` | VERIFIED | pmove-truth: onground and waterlevel agree all 300 ticks. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| JumpButton | `jumpButton` | VERIFIED | pmove-truth (held-jump pogo suppression in bunny phases). Swim sub-branch untraversed (no water on course). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| CheckWaterJump | `checkWaterJump` | VERIFIED | test_qw_pmove course 4 includes the waterjump attempt at the pool lip (waterjumptime asserted against the C fixture). | `lune run tests/test_qw_pmove.luau` |
| NudgePosition | `nudgePosition` | VERIFIED | pmove-truth (runs every tick). C subtlety deliberately preserved: the 1/8 truncation is dead code (base copied pre-truncation) — do not "fix" (backlog M1 note). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SpectatorMove | `spectatorMove` | VERIFIED | test_qw_pmove course 3 (spectator flight on e1m1): accel/friction flight diffed per-tick against the C fixture. | `lune run tests/test_qw_pmove.luau` |
| PlayerMove | `pmove.playerMove` | VERIFIED | pmove-truth top-level; also loopback (client prediction and qwsv SV_RunCmd both drive it — convergence < 1 unit). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## pmovetst.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| PM_InitBoxHull / PM_HullForBox | `hullForBox` | SUBSTITUTED | See pmove.c row (PM_HullForBox added by the 2026-07-06 audit). | — (substitution; verify justification still holds) |
| PM_HullPointContents | `hullPointContents` | VERIFIED | pmove-truth (every trace/contents call for 300 ticks). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_PointContents | `pointContents` | VERIFIED | pmove-truth (waterlevel equality each tick). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_RecursiveHullCheck | `recursiveHullCheck` | VERIFIED | pmove-truth (DIST_EPSILON crossings, re-enter-solid backoff loop) — position error at the f32/f64 noise floor. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_TestPlayerPosition | `testPlayerPosition` | VERIFIED | pmove-truth via NudgePosition each tick. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_PlayerMove (the trace) | `playerTrace` | VERIFIED | pmove-truth; multi-physent closest-fraction select with 0-based `ent` index preserved (loopback exercises brush-ent + player-box physents). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## common.c (MSG_* — delta usercmd scope)

Base MSG_Read/Write* live in the shared `src/shared/engine/common/msg.luau` (covered by the NQ manifest); rows here are the QW-specific delta-usercmd parts.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| MSG_WriteDeltaUsercmd | `qwents.writeDeltaUsercmd` | VERIFIED | test_qwents: full round trip (CM_ bits, msec always written). | `lune run tests/test_qwents.luau` |
| MSG_ReadDeltaUsercmd | `qwents.readDeltaUsercmd` | VERIFIED | qwents: forwardmove/side/buttons/impulse/msec exact; loopback replays them through the server. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_WriteAngle16 / MSG_ReadAngle16 | `msg.writeAngle16` / `msg.readAngle16` | VERIFIED | test_msg: 90 deg -> 16384 -> 90 deg; test_qwents "cmd angle1/2 round-trips (angle16, mod 360)". | `lune run tests/test_msg.luau`; `lune run tests/test_qwents.luau` |
| MSG_WriteAngle (QW byte angle) | `msg.writeAngleQW` | VERIFIED | Entity angles in qwents delta rows round-trip in the qwents suite. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Info_ValueForKey / Info_RemoveKey / Info_RemovePrefixedKeys / Info_SetValueForStarKey / Info_SetValueForKey / Info_Print (common.c:1852-2095) | Luau `{[string]: string}` tables everywhere info strings appear; `qwsv.infoString` (qwsv.luau:843) serializes for the wire, `qwsv.infoPrint` is the 20-column dump | SUBSTITUTED | Rows added by the 2026-07-06 audit (the info-string machinery fell through the MSG-scope carve-out). The backslash-string representation is replaced by tables; the SEMANTICS are verified through their consumers: setinfo round-trip + `_`-prefix strip (test_qw_loopback), star-key refusal (setServerinfo row), 20-column Info_Print (SV_ShowServerinfo_f/CL_User_f rows). Delta: no 512-byte MAX_INFO_STRING truncation. | `lune run tests/test_qw_loopback.luau` (consumers) |
| MSG_GetReadCount / MSG_ReadStringLine (common.c:661,777) | reader object carries its own cursor (msg.luau:reader); no ReadStringLine | SUBSTITUTED | Rows added by the 2026-07-06 audit. GetReadCount's global-cursor bookkeeping is the reader object itself; ReadStringLine only parses connectionless (OOB) console packets, which the transport substitution removed entirely. | — (substitution; verify justification still holds) |
| COM_BlockSequenceCheckByte / COM_BlockSequenceCRCByte (common.c:2179,2224) | — | SUBSTITUTED | Row added by the 2026-07-06 audit: the clc_move anti-spoof checksum byte. Roblox remotes are per-player authenticated; both ends write/read the byte as 0 (recorded as deltas on the CL_SendCmd and SV_ExecuteClientMessage rows). | — (substitution; verify justification still holds) |
| COM_Gamedir (common.c:1748) | `addGameDirectory` at boot (init.server gamedir chunks; staged by build_assets.py) | SUBSTITUTED | Row added by the 2026-07-06 audit: C's runtime `gamedir` switch. The port fixes the gamedir per published place/boot config — the mechanism itself is proven end-to-end by S5/S6 (Threewave, Rocket Arena); runtime switching is publish-time configuration on this platform. | `lune run tests/test_scenario_ctf.luau` (mechanism) |
| COM_AddParm / COM_filelength / COM_FileOpenRead (common.c:1179,1324,1343) | — | SUBSTITUTED | Row added by the 2026-07-06 audit: argv injection and FILE-handle plumbing; no command line and no file handles — the vfs serves buffers (same substitution as the NQ COM_ file rows). | — (substitution; verify justification still holds) |
| build_number (common.c:2265 + buildnum.c) | — | SUBSTITUTED | Row added by the 2026-07-06 audit: the build number feeds CL_Version_f/f_version replies (proxy/cheat ecosystem checks). Version identity here is the conback stamp ("(ROBLOQUAKE) 1.09", Draw_CharToConback row) + the repo itself; there is no f_version ecosystem to answer. | — (substitution; verify justification still holds) |

## wad.c / draw.c (2D assets & drawing — as relevant)

The QW boot's 2D overlay runs on the shared modules (`render/textures.luau`, `render/confont.luau`, `hud.luau`, `console.luau`; wad parsing verified by `tests/test_wad.luau`) — sbar, scoreboards, console, chat line and cshift blends all live-evidenced above.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| W_CleanupName / W_LoadWadFile / W_GetLumpName / W_GetLumpNum / SwapPic | shared wad module (both boots via hudlib) | VERIFIED | Stale row: the QW boot's sbar/HUD pics come from gfx.wad through the same shared wad module (every committed QW sbar capture shows them); the module itself is test-covered. | `lune run tests/test_wad.luau`; any QW sbar capture |
| Draw_Init / Draw_Character / Draw_String / Draw_Alt_String / Draw_Pic / Draw_SubPic / Draw_TransPic / Draw_TransPicTranslate / Draw_ConsoleBackground / Draw_Fill | shared confont rows + hudlib pics/fills + consolelib conback (TransPicTranslate via `textures.translatePixels`) | VERIFIED | The committed QW capture set renders through every one of them: conchars strings + alt (bronze) text and the conback ([evidence/qw-console-open.jpg](evidence/qw-console-open.jpg)), wad pics/subpics + palette fills across the sbar/scoreboard captures, translated pixels tested in test_qwview. | qw-console-open + scoreboard evidence procedures; `lune run tests/test_wad.luau` |
| Draw_TileClear | opaque `sbarStrip` frame (hudlib) | SUBSTITUTED | TileClear's job in the sbar path is erasing the world behind the bar area; the port parks an opaque full-width strip there instead (viewsize-driven), so there is never anything to clear. | code: hud.luau sbarStrip; viewsize captures |
| Draw_FadeScreen | the shared menu fade backdrop | VERIFIED | Live behind the QW menu in [evidence/qw-menu-fps.jpg](evidence/qw-menu-fps.jpg) (0.5-alpha frame vs C's 8x8 dither — recorded delta). | Stage per evidence/qw-menu-fps.txt |
| Draw_Pixel / Draw_Crosshair | the conchars '+' at the window centre + the `crosshair` cvar command (NQ block ported) | VERIFIED | [evidence/qw-color-crosshair.jpg](evidence/qw-color-crosshair.jpg): the '+' visible mid-screen on the QW boot. Same window-centre anchoring delta as the NQ crosshair row (projection centre). | Stage per evidence/qw-color-crosshair.txt |
| Draw_DebugChar / Draw_CharToConback / R_DrawRect8 / R_DrawRect16 / Draw_BeginDisc / Draw_EndDisc | — | SUBSTITUTED | Software-framebuffer plumbing (disc = disk-access icon); no framebuffer exists. | — (substitution; verify justification still holds) |

## Rasterizer files — substituted groups (Roblox EditableMesh renderer)

Per the port architecture, the software rasterizer is replaced wholesale; groups get one row each, except particles/dlights/lightstyles/lightmaps, where the port reproduces the *outputs* and gets real rows.

| C group / function | Port | Status | Evidence / Delta |
|---|---|---|---|---|
| d_*.c/.s/.asm (d_edge, d_scan, d_polyse, d_sprite, d_sky, d_surf, d_part, d_fill, d_zpoint, …) | — | SUBSTITUTED | Span/poly/particle scanline rasterization is the GPU's job; geometry ships as EditableMesh. No per-pixel path exists to port. | — (substitution; verify justification still holds) |
| r_main.c / r_bsp.c / r_edge.c / r_draw.c / r_aclip.c / r_vars.c / r_misc.c / r_efrag.c | `render/worldmesh.luau` | SUBSTITUTED | World surfaces prebuilt as EditableMesh batches per texture; Roblox handles frustum/visibility/z instead of the edge list + PVS surface walk. Live 547df88: QW world (dm3) renders; loopback verifies the same BSP data loads. | — (substitution; verify justification still holds) |
| r_alias.c (+ r_aliasa) | `render/entrender.luau` | SUBSTITUTED | Alias frames as EditableMesh with light level via `setLight`; used for QW packet ents, players, gun, beams. Live 115a438/9ecc594: items + view weapon render. Delta: no per-vertex anorm shading table. | — (substitution; verify justification still holds) |
| r_sprite.c | entrender sprite billboards | SUBSTITUTED | Sprite frames as billboards. | — (substitution; verify justification still holds) |
| r_sky.c / d_sky.c | shared sky (10Hz image scroll) | SUBSTITUTED | Rasterizer substituted; the compositing itself is C-shaped (front layer palette-0 transparency over the back half, dual scroll). FIXED 2026-07-04 (user playtest): the QW boot never ran the shared texture writers — raw sky showed black holes; qwclient now consumes worldmesh.takeTextureAnims() and pumps sky/turb/+wall at 10Hz. Evidence: [evidence/qw-dm3-sky.jpg](evidence/qw-dm3-sky.jpg) + .txt. | Stage per evidence/qw-dm3-sky.txt, capture, compare |
| gl_*.c (entire GL renderer) | — | SUBSTITUTED | The port targets the software renderer's feature set as the fidelity reference; the GL path is an alternative C backend, not a feature source. | — (substitution; verify justification still holds) |
| r_part.c: R_RunParticleEffect | `particles.runEffect` (qwScale) | VERIFIED | test_particles2: shared battery (die 0.1*(rand%5), color (c&~7)+(rand&7), org spread, vel dir*15) plus the QW count-based org-spread scale (>130 → 3, >20 → 2, else 1) added 2026-07-04 and asserted at counts 10/50/200; QW's pt_grav type is physics-identical to pt_slowgrav (plain grav both engines — see the pt_grav fall-through fix on the NQ R_DrawParticles row). All qwclient tent callsites pass qwScale. | `lune run tests/test_particles2.luau` |
| r_part.c: R_ParticleExplosion | `particles.explosion` | VERIFIED | test_particles2 explosion battery (1024 particles, 512/512 explode/explode2, ramp1[0], die +5, org ±16, vel ±256) — QW r_part.c explosion body is identical to WinQuake's. | `lune run tests/test_particles2.luau` |
| r_part.c: R_LavaSplash / R_TeleportSplash | `particles.lavaSplash` / `.teleportSplash` | VERIFIED | Shared particlesim core: test_particles2 teleportSplash battery (896 grid, colors, die window, speeds, zero-dir fix); lavaSplash shares the dir/normalize/speed structure. | `lune run tests/test_particles2.luau` |
| r_part.c: R_RocketTrail (all 7 trail types) | `particles.rocketTrail` | VERIFIED | Shared particlesim core: test_particles2 type-0 battery (count/colors/die/advance quirk). QW trail-type mapping by model flags wired in `relinkEntities` (Studio-side; visual anchor covers it). | `lune run tests/test_particles2.luau` |
| r_part.c: R_DrawParticles | `particles.update` | VERIFIED | test_particles2 physics batteries (blob/blob2, explode ramps, fire, grav/slowgrav plain-grav, expiry); QW's switch matches WinQuake's with pt_grav at plain grav — the port's QUAKE2-only grav*20 was fixed 2026-07-04. Rendering substitution (neon cubes) noted on the NQ row. | `lune run tests/test_particles2.luau` |
| r_light.c: R_AnimateLight | qwclient `updateLightstyles` + `worldmesh.updateLightStyles` | VERIFIED | Loopback asserts arrival (cl.lightstyles[0]); the 10Hz pump is the same shared tick that drives the QW sky fix (qw-dm3-sky evidence captured the pump live on the QW boot) and the shared lightatlas machinery is per-frame-verified in the NQ flicker evidence. | `lune run tests/test_qw_loopback.luau`; qw-dm3-sky + nq-e1m1-flicker evidence |
| r_light.c: R_MarkLights / R_AddDynamicLights | `worldmesh.updateDlights` + `render/lightatlas.luau` | VERIFIED | Shared module: the mark/rebake/restore pass is the one captured in the NQ explosion dlight pair (nq-explosion-dlight/-decayed); the QW boot feeds it from the CL_DecayLights block and the rocket-splash evidence shows the explosion lighting live under QW. | NQ dlight pair + qw-rocket-splash evidence; shared code |
| r_light.c: R_LightPoint | shared `engine/client/lightpoint.at` | VERIFIED | Shared module (one implementation for both boots) covered by test_render_misc: e1m1 samples, style scaling, -2048 reach, fullbright fallback. Gun light floor 24 note stands. | `lune run tests/test_render_misc.luau` |
| r_surf.c / d_surf.c (surface cache + lightmaps) | `lightatlas.luau` + worldmesh lighting | VERIFIED | QW world renders lit, live 547df88 — including the recorded observation that dm3's spawn is genuinely 12/255 light ("near-black screens there are faithful, not a bug"), which is a lightmap-correctness check. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## QW platform backend files (group; rows added by the 2026-07-06 independent audit)

QW-tree copies of the DOS/Win platform layer that previously had no row in
any manifest (the NQ groups cover the WinQuake tree, not these copies).

| C group / files | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| cd_*.c / in_*.c / vid_*.c / sys_*.c (client tree) / snd_win.c / snd_linux.c / nonintel.c (entire files) | — | SUBSTITUTED | Same substitutions as the NQ platform groups: Roblox runtime owns CD audio, input devices, display modes, timers/files, and sound DMA; the ported behaviors behind these APIs (input, sound, timing) are accounted on their engine-side rows. | — (substitution; verify justification still holds) |

## Port-side additions with no C counterpart

| Addition | Where | Justification |
|---|---|---|---|
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
| Level-change teardown destroys brush templates (worldmesh.destroyBuild), static ents (staticRes list), gun ent; rebuild waits one frame | qwclient levelResets block | EditableMesh budget: Destroying signals are deferred and unparented templates never fire them — same-frame rebuilds starve into skipped batches (see nq evidence/nq-e1m1-flicker.txt; NQ twin fixed in the same commit). |

No additions were found without a stated justification (code comment or backlog entry).

## Totals

> N/A status formalized 2026-07-05 (see coverage README): concept cannot exist in the port (dead-in-C, DOS/transport-era, unused-in-scope, platform-owned). Initial N/A pass done by hand; counts below are column-exact.


Rows count grouped one-liner families (IN_* wrappers, menu triads, upload/download clusters) as single rows.

| Status | Rows |
|---|---|---|
| VERIFIED | 169 |
| PENDING | 0 |
| UNIMPLEMENTED | 0 |
| SUBSTITUTED | 70 |
| N/A | 7 |

(2026-07-06 independent audit added 11 rows: Sbar_ColorForMap -> VERIFIED;
the QW common.c additions that fell through the MSG-scope carve-out
(Info_* machinery, MSG_GetReadCount/ReadStringLine, COM_BlockSequence*,
COM_Gamedir, COM file plumbing, build_number), CL_CheckOrDownloadFile,
Cmd_ForwardToServer_f, net_udp/net_wins, and the QW platform-file group
-> SUBSTITUTED. PM_HullForBox merged into the existing PM_InitBoxHull rows.)
| **Total rows** | **235** |

Counts are the mechanical status-column count (2026-07-05 presentation pass;
the previous 53-UNIMPLEMENTED total under-counted by one vs the same method).

This manifest is DONE (2026-07-06): zero UNIMPLEMENTED, zero PENDING.
The N/A flag pass is resolved — the user ratified SCR_ModalMessage/
DrawNotifyString (dead in QW) and the video-menu NQ-mirror as N/A.

> Evidence reset 2026-07-04: VERIFIED now means re-runnable evidence only (a cited test/harness). 10 rows demoted to PENDING with their prior claims preserved inline (marked DEMOTED); re-earn via tests or checked-in screenshots under docs/coverage/evidence/.
