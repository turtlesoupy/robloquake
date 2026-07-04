# QW server coverage

Function-level manifest for the QuakeWorld server port. C reference: `reference/quake-c/QW/server/*.c`
(pmove.c/pmovetst.c/net_chan.c/mathlib.c/zone.c/common.c live in `reference/quake-c/QW/client/` and are
shared with the server build). Port: `src/shared/engine/qw/*.luau` + `src/server/qwserver.luau`; the QW
port intentionally reuses NQ-shared modules under `src/shared/engine/{progs,bsp,models,common}/`.

Status legend:
- **VERIFIED** — a passing offline test asserts the behavior (all four QW tests run green as of this audit:
  `test_qw_pmove` 3/3, `test_qwents` 21/21, `test_qwsv` 25/25, `test_qw_loopback` 26/26).
  Functions covered by `test_qw_pmove.luau` are checked against `tools/pmove_truth.c`, which `#include`s the
  VERBATIM C `pmove.c`/`pmovetst.c` (max pos error 0.000122 units over 300 ticks).
- **PENDING** — ported, no offline test asserts it.
- **UNIMPLEMENTED** — no port code (or port code that cannot run).
- **SUBSTITUTED** — intentionally replaced, with a platform justification.

## sv_main.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ServerPaused | `svr.paused` field (qwsv.luau) | PENDING | Read directly by frame/clc_move guards; no test toggles pause. |
| SV_Shutdown | — | SUBSTITUTED | No process/log lifecycle on Roblox; server dies with the DataModel. |
| SV_Error | Luau `error()` propagation | SUBSTITUTED | Lua error/stack semantics replace longjmp + SV_FinalMessage. |
| SV_FinalMessage | — | UNIMPLEMENTED | No shutdown broadcast; players are disconnected by the platform. |
| SV_DropClient | `qwsv.dropClient` (qwsv.luau:1213) | PENDING | Runs ClientDisconnect/SpectatorDisconnect, writes svc_disconnect, fullClientUpdate to reliable_datagram; wired to `Players.PlayerRemoving` in qwserver.luau. No test drops a client. |
| SV_CalcPing | `qwsv.calcPing` (qwsv.luau:930) | PENDING | Frame-ring ping_time average; produced into updateping but no test asserts the value. |
| SV_FullClientUpdate | `qwsv.fullClientUpdate` (qwsv.luau:946) | VERIFIED | test_qw_loopback: "own player info received" (name via svc_updateuserinfo); `_`-prefixed keys stripped as in Info_RemovePrefixedKeys. |
| SV_FullClientUpdateToClient | — | UNIMPLEMENTED | Single-client resend path unused; setinfo broadcasts via reliable_datagram instead. |
| SVC_Status | — | SUBSTITUTED | Out-of-band status query; Roblox server browser/matchmaking replaces it. |
| SV_CheckLog / SVC_Log | `svr.fraglog` ring (qwsv.luau:196) | SUBSTITUTED | Frag log kept as in-memory ring of 512 `{killer,killee,time}`; no UDP log pull — external stat pullers don't exist on this transport. |
| SVC_Ping | — | SUBSTITUTED | Out-of-band ping probe; transport RTT is Roblox's concern. |
| SVC_GetChallenge | — | SUBSTITUTED | Challenge/anti-spoof handshake unnecessary: Roblox authenticates players before OnServerEvent fires. |
| SVC_DirectConnect | `qwsv.allocClient` + `qwsv.wireConnect` (qwsv.luau:460,502) + `connectPlayer` (qwserver.luau) | VERIFIED | test_qw_loopback: wireConnect → handshake completes; slot setup + SetNewParms spawn parms match the C core. Challenge/qport/rate/IP checks dropped (SUBSTITUTED by platform auth). |
| Rcon_Validate / SVC_RemoteCommand | — | SUBSTITUTED | rcon absent: no out-of-band packets; Studio/console access replaces remote admin. |
| SV_ConnectionlessPacket | — | SUBSTITUTED | No connectionless (0xffffffff) packets on Roblox remotes; first inbound buffer implicitly connects (qwserver.luau `onInbound`). |
| StringToFilter / SV_AddIP_f / SV_RemoveIP_f / SV_ListIP_f / SV_WriteIP_f / SV_SendBan / SV_FilterPacket | — | SUBSTITUTED | IP filtering/banning is Roblox moderation's job; server never sees IPs. |
| SV_ReadPackets | `onInbound` (qwserver.luau) | PENDING | Per-packet processing + immediate reply preserved ("one reply per received packet"); loopback test exercises the same call pair directly, not through the remotes. |
| SV_CheckTimeouts | — | SUBSTITUTED | Roblox fires PlayerRemoving on disconnect; no zombie/timeout sweep needed on a connection-oriented transport. |
| SV_GetConsoleCommands | — | SUBSTITUTED | No stdin console; Studio command bar + `_G.RQ_SERVER` (qwserver.luau) replace it. |
| SV_CheckVars | — | UNIMPLEMENTED | password/spectator_password not enforced (no join password concept wired). |
| SV_Frame | `qwsv.frame` (qwsv.luau:1933) + Heartbeat loop (qwserver.luau) | VERIFIED | test_qwsv/test_qw_loopback drive frames; physics + reliable_datagram fan-out. Delta: bookkeeping (timeouts, master, log, vars) intentionally absent per rows above. |
| SV_InitLocal | cvar seeding in `qwsv.newGame` (qwsv.luau:84) | PENDING | QW cvar defaults registered directly; no Cmd_AddCommand table (commands dispatch via `userCommands`). |
| Master_Heartbeat / Master_Shutdown | — | SUBSTITUTED | No master server protocol; Roblox discovery replaces it. |
| SV_ExtractFromUserinfo | `extractUserinfo` (qwsv.luau:418) | PENDING | Name trim/"console"→unnamed/dupe-prefix + rename broadcast + msg level ported. Delta: no name-flood penalty (lastnamecount), no `rate` extraction (no rate control on Roblox), no team resync. |
| SV_InitNet | remotes wiring (qwserver.luau) | SUBSTITUTED | RemoteEvent/UnreliableRemoteEvent replace UDP sockets; both currently route to the same reliable path (see qwnetchan note). |
| SV_Init | `qwsv.newGame` + qwserver boot | VERIFIED | test_qwsv boots e1m1 via the same entry points used by qwserver.luau. |

## sv_user.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_New_f | `qwsv.newF` (qwsv.luau:817) | VERIFIED | test_qw_loopback: serverdata parsed (protocol, spawncount, gamedir "qw", playernum, levelname, all 10 movevars — "movevars received (gravity 800)"), cdtrack, fullserverinfo stufftext. |
| SV_Soundlist_f | `qwsv.soundlistF` (qwsv.luau:881) | VERIFIED | test_qw_loopback "precache lists received"; continuation format (`writeList`) with MAX_MSGLEN/2 chunking and spawncount recheck ported. |
| SV_Modellist_f | `qwsv.modellistF` (qwsv.luau:894) | VERIFIED | Same loopback check as soundlist. |
| SV_PreSpawn_f | `qwsv.prespawnF` (qwsv.luau:908) | VERIFIED | test_qw_loopback "baselines received (>20)". Delta: C paginates the signon across several `cmd prespawn` round-trips; port copies the whole signon buffer in one reliable write (transport has no 1450-byte packet limit) and errors on overflow instead of chunking. |
| SV_Spawn_f | `qwsv.spawnF` (qwsv.luau:977) | VERIFIED | test_qw_loopback: handshake completes; lightstyles received; forced stat refresh ("skins" stufftext → begin). Delta: no `nails2`/checksum handling (not in protocol 28 path used). |
| SV_SpawnSpectator | spectator branch of `qwsv.spawnIntoGame` (qwsv.luau:519) | PENDING | Places at info_player_start, runs SpectatorConnect if present. No spectator test. |
| SV_Begin_f | `qwsv.beginF` (qwsv.luau:1044) | VERIFIED | test_qw_loopback "handshake completed: server spawned the client"; ClientConnect/PutClientInServer run exactly once here. Delta: no model-checksum ("check") anti-cheat, no unpause-on-begin counters. |
| SV_NextDownload_f / SV_BeginDownload_f / SV_NextUpload / OutofBandPrintf | — | SUBSTITUTED | File download/upload protocol unnecessary: `clientbundle` publishes all assets to clients ahead of time (qwserver.luau). |
| SV_Say / SV_Say_f / SV_Say_Team_f | `userCommands.say` / `say_team` (qwsv.luau:1114,1143) | PENDING | Chat with `[SPEC]` prefix, sv_spectalk gating, team routing, flood protection. Delta: flood window hardcoded (4 msgs / 4 s, 10 s lockout) instead of fp_* cvars; no `sv_aim`-style console echo. No test asserts chat. |
| SV_Pings_f | `userCommands.pings` (qwsv.luau:1078) | PENDING | updateping/updatepl per spawned client; untested. |
| SV_Kill_f | `userCommands.kill` (qwsv.luau:1192) | PENDING | health>0 guard + ClientKill exec. Delta: no "Can't suicide -- allready dead" print. |
| SV_TogglePause / SV_Pause_f | `userCommands.pause` (qwsv.luau:1175) | PENDING | pausable cvar gate, broadcast, svc_setpause via reliable_datagram; also sent on begin when paused. Untested. |
| SV_Drop_f | `userCommands.drop` → dropClient | PENDING | Untested. |
| SV_PTrack_f | `userCommands.ptrack` (qwsv.luau:1093) | PENDING | Spectator autocam target incl. goalentity write; untested. |
| SV_Rate_f | — | SUBSTITUTED | Bandwidth rate control meaningless on Roblox remotes (no per-client UDP throttling). |
| SV_Msg_f | `userCommands.msg` (qwsv.luau:1186) | PENDING | messagelevel filter set; untested. |
| SV_SetInfo_f | `userCommands.setinfo` (qwsv.luau:1155) | PENDING | Star-key protection, dedupe, extractUserinfo, svc_setinfo broadcast. Untested. |
| SV_ShowServerinfo_f | — | UNIMPLEMENTED | `serverinfo` user command absent (table exists; only sent via fullserverinfo at connect). |
| SV_NoSnap_f | — | SUBSTITUTED | Snap/upload (remote screenshot) feature absent — depends on the upload protocol, dropped with it. |
| SV_ExecuteUserCommand | `qwsv.executeUserCommand` (qwsv.luau:1203) + `tokenize` | VERIFIED | Drives the whole loopback handshake (new/soundlist/modellist/prespawn/spawn/begin). Delta: unknown commands only dprint (C prints to client). |
| V_CalcRoll | `calcRoll` (qwsv.luau:542) | PENDING | cl_rollangle=2/cl_rollspeed=200 hardcoded (server has no such cvars); feeds angles[ROLL]*4 in runCmd. No assertion. |
| AddLinksToPmove / AddAllEntsToPmove | inline scan in `qwsv.runCmd` (qwsv.luau:630-672) | VERIFIED | test_qwsv movement + loopback prediction run through it. Delta: linear scan over all edicts with absbox-vs-±256 test instead of the areanode walk — same accept set, different visit order (physent order affects only `onground` index mapping, handled via `physentEdicts`). MAX_PHYSENTS=32 kept. |
| SV_PreRunCmd | playertouch reset in `executeCmd`/clc_move (qwsv.luau:737,1283) | VERIFIED | Touch dedupe across chopped halves + net_drop replays asserted implicitly by loopback play (no double-touch crash); structure matches C. |
| SV_RunCmd | `qwsv.runCmd` (qwsv.luau:558) | VERIFIED | test_qwsv: movement >100 units via pmove, settle/onground, shotgun fire via button0; test_qw_loopback: prediction convergence < 1.0 unit implies server-side cmd execution matches the client's pmove replay. msec>50 chop, angle/roll, PlayerPreThink+runThink, pmove fill, FL_ONGROUND/groundentity writeback, touch dedupe all present. |
| SV_PostRunCmd | `qwsv.postRunCmd` (qwsv.luau:754) | VERIFIED | test_qwsv shotgun: PlayerPostThink fired the weapon (shell consumed, guncock sound). SV_RunNewmis folded in via physicsToss at 0.05s. SpectatorThink branch untested. |
| SV_ExecuteClientMessage | `qwsv.executeClientMessage` (qwsv.luau:1243) | VERIFIED | test_qw_loopback: full clc stream (nop/delta/move/stringcmd) with net_drop fill-in from lastcmd/oldest/oldcmd, ping bookkeeping via frame ack. Deltas: move checksum byte read but not validated (authenticated transport); msec-overuse cheat detection (sv_user.c timer checks) absent. clc_tmove spectator-only teleport ported, untested. |
| SV_UserInit | — | SUBSTITUTED | cl_rollspeed/cl_rollangle/sv_spectalk registered in newGame's cvar table instead. |

## sv_ents.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_AddToFatPVS | `addToFatPVS` (qwsv.luau:1478) | VERIFIED | test_qwsv frame writes (entities appear exactly when in PVS); same 8-unit plane straddle recursion. |
| SV_FatPVS | `qwsv.fatPVS` (qwsv.luau:1507) | VERIFIED | Same tests; allocates per call instead of static buffer (GC platform). |
| SV_AddNailUpdate | inline in `writeEntitiesToClient` (qwsv.luau:1708) | PENDING | Nail/supernail modelindex match, MAX_NAILS=32, overflow nails dropped (not sent as packet entities) — matches C. No test spawns nails. |
| SV_EmitNailUpdate | `emitNailUpdate` (qwsv.luau:1652) | PENDING | 48-bit xyzpy packing bit-for-bit from C; test_qwsv parser skips nails bytes but none are emitted in the fixture. |
| SV_WriteDelta | `qwents.writeDelta` (qwents.luau:141) | VERIFIED | test_qwents: full + delta round-trips (moved/unchanged/removed/new-from-baseline); 0.1 origin epsilon, U_MOREBITS/U_REMOVE framing exact. |
| SV_EmitPacketEntities | `qwents.emitPacketEntities` (qwents.luau:242) | VERIFIED | test_qwents merge-walk round trip; test_qwsv "delta frame smaller than full frame" + entity set reproduction; test_qw_loopback ">20 delta packets". |
| SV_WritePlayersToClient | `qwsv.writePlayersToClient` (qwsv.luau:1525) | VERIFIED | test_qwsv hand-parses svc_playerinfo: self omits PF_MSEC/PF_COMMAND, origin within 1/8 quantization; spectator/spec_track masks ported (untested branches). |
| SV_WriteEntitiesToClient | `qwsv.writeEntitiesToClient` (qwsv.luau:1679) | VERIFIED | test_qwsv: frame ring stores what was sent, delta keyed on netchan.incoming_sequence & UPDATE_MASK, MAX_PACKET_ENTITIES respected. |

## sv_send.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_FlushRedirect / SV_BeginRedirect / SV_EndRedirect | — | SUBSTITUTED | Console redirection serves rcon/status, both absent. |
| Con_Printf / Con_DPrintf | `svr.print` / `svr.dprint` hooks (qwsv.luau:153) | SUBSTITUTED | Route to Roblox `print`; dprint default no-op (developer cvar replaced by hook swap). |
| SV_PrintToClient / SV_ClientPrintf | `svr.clientPrint` (qwsv.luau:178) | VERIFIED | Loopback receives svc_print traffic during handshake/play; messagelevel filter honored. Also mirrors into `client.prints` (see additions). |
| SV_BroadcastPrintf | `svr.broadcastPrint` (qwsv.luau:166) | PENDING | Reliable svc_print to every spawned client + printLog mirror; no test asserts receipt. |
| SV_BroadcastCommand | — | UNIMPLEMENTED | svc_stufftext broadcast (used by SV_Gamedir/serverinfo changes) absent along with those commands. |
| SV_Multicast | `qwsv.svMulticast` (qwsv.luau:1810) | VERIFIED | test_qw_loopback: "svc_sound guncock arrived through the PHS multicast". ALL/PHS/PVS + _R variants, 1024-unit PHS distance override, reliable→netchan.message vs datagram routing. Delta: reliable path writes straight to netchan.message (no backbuf, see sv_nchan.c). |
| SV_StartSound | `qwsv.startSoundWire` via `svr.startSound` (qwsv.luau:1872) | VERIFIED | Same loopback check; channel packing (ent<<3), SND_VOLUME/SND_ATTENUATION flags, bmodel origin midpoint, phs/reliable channel-8 rules ported. |
| SV_FindModelNumbers | inline in `spawnServer` (qwsv.luau:347) | VERIFIED | test_qwsv "player model number found"; nail/supernail indexes drive the nails path. |
| SV_WriteClientdataToMessage | `qwsv.writeClientdataToMessage` (qwsv.luau:1373) | PENDING | chokecount, svc_damage with inflictor midpoint, fixangle→svc_setangle (loopback asserts setangle at spawn — that one path verified); damage path untested. |
| SV_UpdateClientStats | `qwsv.updateClientStats` (qwsv.luau:1328) | VERIFIED | test_qw_loopback: health/shells stats mirror server, ammo drops after firing; spectator spec_track passthrough ported (untested); sigil bits <<28 into STAT_ITEMS. |
| SV_SendClientDatagram | `qwsv.sendClientDatagram` (qwsv.luau:1412) | VERIFIED | Loopback frames flow through it every tick. Delta: stats update not gated on Netchan_CanReliable (no reliable backlog exists on this transport). |
| SV_UpdateToReliableMessages | partial: reliable_datagram fan-out in `qwsv.frame` (qwsv.luau:1945) | PENDING | **Gap:** the C per-frame sync is mostly missing — no `old_frags != v.frags` scan (svc_updatefrags only fires from fullClientUpdate at spawn/drop, so the scoreboard never updates during play), no edict `gravity`/`maxspeed` field pickup → svc_entgravity/svc_maxspeed never sent (client.entgravity stays 1, client.maxspeed stays sv_maxspeed), and `svr.datagram` (MSG_BROADCAST dest) is never appended to client datagrams — QC MSG_BROADCAST writes are silently dropped (QW QC mostly uses MSG_MULTICAST, so id1 play works, but any broadcast write is lost). |
| SV_SendClientMessages | `qwsv.sendClientMessages` + `qwsv.replyToClient` (qwsv.luau:1448,1466) | VERIFIED | Loopback: strict 1:1 packet exchange (send_message flag) keeps sequence spaces aligned for delta/prediction. Delta: no rate/choke logic (chokecount always 0 — transport does not drop), spectator slower update path absent. |
| SV_SendMessagesToAll | — | UNIMPLEMENTED | Only used at shutdown/final message, both absent. |

## sv_init.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_ModelIndex | `svr.modelIndex` hook (qwsv.luau:212) | VERIFIED | Used by baselines/stats/setmodel throughout the verified tests. Linear precache scan, 0-based like C. |
| SV_FlushSignon | — | SUBSTITUTED | C chunks the signon into 512-byte buffers for UDP; the port keeps one signon buffer and sends it whole in prespawn (no packet size limit on the transport). |
| SV_CreateBaseline | `qwsv.createBaseline` (qwsv.luau:368) | VERIFIED | test_qwsv "baselines created" + delta-from-baseline round trip; loopback ">20 baselines received". Player slots forced to playermodel/colormap as in C. |
| SV_SaveSpawnparms | — | UNIMPLEMENTED | SetChangeParms is resolved by qwdefs but never executed; spawn parms are only captured at connect (SetNewParms). Blocks parm carry-over across level changes. |
| SV_CalcPHS | `phsRow` + `svr.phsCache` (qwsv.luau:1771) | SUBSTITUTED (verified behavior) | Computed lazily per-leaf and cached instead of the eager O(numleafs²) table — the eager build would stall level load on Roblox. Result is the same or-of-visible-PVS rows; exercised by the loopback PHS sound check. |
| SV_CheckModel | — | SUBSTITUTED | Model CRC anti-cheat pointless when the server publishes the assets (clientbundle). |
| SV_SpawnServer | `qwsv.spawnServer` (qwsv.luau:240) | VERIFIED | test_qwsv: e1m1 spawns, deathmatch entity filtering via `loadFromFileQW` (13 inhibited, 0 monsters), submodel precache, worldspawn edict, StartFrame-before-load ordering, two settle frames. Delta: no progs CRC gate beyond PROGHEADER_CRC_QW; `localmodels` naming identical (`*i`). |

## sv_phys.c

Port file: `src/shared/engine/qw/qwphys.luau` (QW-specific copy; algorithms shared with the verified NQ
sv_phys port, ABI injected via qwdefs). Primary evidence: test_qwsv boots and settles e1m1 through two
`qwphys.physics` frames and runs live play; door/plat/item behavior beyond that is untested here.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_CheckAllEnts | — | UNIMPLEMENTED | Debug-only sweep; never called in the C frame loop. |
| SV_CheckVelocity | `sv_phys.checkVelocity` (qwphys.luau:43) | PENDING | sv_maxvelocity clamp (cvar seeded via shared cvar defaults). |
| SV_RunThink | `sv_phys.runThink` (qwphys.luau:77) | VERIFIED | test_qwsv weapon think chain fires (shotgun via player think path); item/door thinks run during settle frames. |
| SV_Impact | `sv_phys.impact` (qwphys.luau:97) | PENDING | Touch pair dispatch; exercised by physics but not asserted. |
| ClipVelocity | `sv_phys.clipVelocity` (qwphys.luau:119) | PENDING | STOP_EPSILON=0.1 as C. |
| SV_FlyMove | `sv_phys.flyMove` (qwphys.luau:144) | PENDING | MAX_CLIP_PLANES=5 planes logic; exercised via physicsToss/Step in settle frames, not asserted directly. |
| SV_AddGravity | `sv_phys.addGravity` (qwphys.luau:268) | PENDING | Includes QW `gravity` field scale handling. |
| SV_PushEntity | `sv_phys.pushEntity` (qwphys.luau:289) | PENDING | |
| SV_Push + SV_PushMove | merged `pushMove` (qwphys.luau:319) | PENDING | C splits SV_PushMove→SV_Push; port merges them (same shape as C's combined flow): final-position test, standing-on-pusher carry, corpse crush-to-point, blocked callback + full move-back. Not asserted by a test (doors/plats move in test maps but nothing checks them). |
| SV_Physics_Pusher | `physicsPusher` (qwphys.luau:435) | PENDING | ltime/nextthink windowing as C. |
| SV_Physics_None | `physicsNone` (qwphys.luau:725) | PENDING | |
| SV_Physics_Noclip | `physicsNoclip` (qwphys.luau:730) | PENDING | |
| SV_CheckWaterTransition | `checkWaterTransition` (qwphys.luau:740) | PENDING | |
| SV_Physics_Toss | `sv_phys.physicsToss` (qwphys.luau:768) | VERIFIED | test_qwsv shotgun path spawns/moves newmis through it; bounce/backoff 1.5/1.0 as C. |
| SV_Physics_Step | `physicsStep` (qwphys.luau:821) | PENDING | Freefall + dland2 hitsound; QW deathmatch has no monsters so only misc step ents exercise it. |
| SV_ProgStartFrame | inlined at top of `sv_phys.physics` (qwphys.luau:854) | VERIFIED | StartFrame exec with self/other/time reset; runs every test frame. |
| SV_RunEntity | movetype dispatch in `sv_phys.physics` (qwphys.luau:872) | VERIFIED | Client slots skipped ("QW: clients move in SV_RunCmd"), which the movement tests depend on. Delta: C's per-entity `lastruntime` throttle (entities run at most every 50 ms between client packets) is absent — entities advance once per server frame like NQ. |
| SV_RunNewmis | inlined after each entity (qwphys.luau:898) + `postRunCmd` | VERIFIED | test_qwsv: missile first-0.05s move via physicsToss (guncock/shell test passes through PlayerPostThink newmis path). |
| SV_Physics | `sv_phys.physics` (qwphys.luau:849) | VERIFIED | test_qwsv/test_qw_loopback every tick; force_retouch decrement; sv.time advanced by qwsv.frame, not here — matches C split. |
| SV_SetMoveVars | movevars built per-cmd in `qwsv.runCmd` (qwsv.luau:674) | SUBSTITUTED | C copies cvars into a global `movevars` once per frame for pmove; port builds the table per RunCmd call from the same cvars — same values, no global. Verified transitively by loopback prediction convergence (server and client pmove use identical movevars). |

Extra NQ-only functions present in qwphys.luau (`checkStuck`, `checkWater`, `wallFriction`, `tryUnstick`,
`walkMove`, `physicsClient`) have **no QW C counterpart** — see the additions section.

## sv_move.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_CheckBottom | NQ-shared `src/shared/engine/server/sv_move.luau` `checkBottom` | UNIMPLEMENTED (broken wiring) | qwbuiltins.luau builtin 40 calls `sv_move.checkBottom` but **qwbuiltins.luau never requires sv_move** — `sv_move` is a dangling global; the builtin errors if a QW mod calls it. Harmless for id1 qwprogs deathmatch (no monsters), fatal for any progs using it. |
| SV_movestep | NQ-shared `sv_move.movestep` | UNIMPLEMENTED (broken wiring) | Same dangling `sv_move` global via builtin 32 (walkmove). Also typed against the NQ `svlib.Server`/NQ world — untested against the QW server object. |
| SV_StepDirection / SV_FixCheckBottom / SV_NewChaseDir / SV_CloseEnough / SV_MoveToGoal | NQ-shared `sv_move.luau` | UNIMPLEMENTED (broken wiring) | builtin 67 (movetogoal) hits the same missing require. |

## sv_nchan.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ClientReliableCheckBlock / ClientReliable_FinishWrite | — | SUBSTITUTED | The backbuf system exists to queue reliable data while a netchan reliable is in flight; the Roblox transport is reliable+ordered, so writers append directly to `client.netchan.message` (8 KB) with a size check. |
| ClientReliableWrite_Begin/Angle/Angle16/Byte/Char/Float/Coord/Long/Short/String/SZ | direct `msg.write*` into `client.netchan.message` (throughout qwsv.luau) | SUBSTITUTED | Same wire bytes, no backbuf indirection; loopback reliable traffic (prints, stats, setangle) verifies the stream itself. |

## sv_ccmds.c

Server operator console commands. No console exists on the Roblox deployment; Studio pokes
`_G.RQ_SERVER` directly. Rows below are UNIMPLEMENTED unless the mechanism exists elsewhere.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_SetMaster_f / SV_Heartbeat_f | — | SUBSTITUTED | No master server. |
| SV_Quit_f / SV_Logfile_f / SV_Fraglogfile_f | — | SUBSTITUTED | Process/file lifecycle absent; fraglog ring replaces the frag logfile. |
| SV_SetPlayer / SV_God_f / SV_Noclip_f / SV_Give_f | — | UNIMPLEMENTED | No cheat commands (no console); could be added via Studio. |
| SV_Map_f | `qwsv.spawnServer` callable; no command/changelevel driver | PENDING | **Gap:** PF_changelevel/localcmd set `svr.changelevelTo`, but nothing in the QW boot (qwserver.luau) consumes it — the NQ path (init.server.luau:400) does. Level change on fraglimit/timelimit dead-ends. Reconnect-on-new-spawncount exists (newF handles it) but is never triggered. |
| SV_Kick_f | — | UNIMPLEMENTED | Roblox `Player:Kick` exists platform-side but no engine command maps to it. |
| SV_Status_f | attribute diagnostics (qwserver.luau Heartbeat) | SUBSTITUTED | SV_Time/SV_Edicts/SV_Origin ServerStorage attributes replace the console status dump for Studio. |
| SV_ConSay_f | — | UNIMPLEMENTED | |
| SV_SendServerInfoChange / SV_Serverinfo_f / SV_Localinfo_f | static `svr.serverinfo` only | UNIMPLEMENTED | serverinfo is fixed at newGame; no runtime change path or svc_serverinfo broadcast. localinfo absent entirely. |
| SV_User_f / SV_Gamedir / SV_Gamedir_f | — | SUBSTITUTED | Single gamedir baked into the asset bundle. |
| SV_Floodprot_f / SV_Floodprotmsg_f | hardcoded values in `say` handler | SUBSTITUTED | Flood protection on (4/4s/10s) but not tunable; C default is off until configured. |
| SV_Snap / SV_Snap_f / SV_SnapAll_f | — | SUBSTITUTED | Depends on the upload protocol (dropped). |
| SV_InitOperatorCommands | — | SUBSTITUTED | No command table to register. |

## world.c

Port file: `src/shared/engine/qw/qwworld.luau` (QW copy of the NQ-verified world port, ABI via qwdefs).
The identical NQ algorithms are ground-truth tested against `tools/trace_truth.c` on the NQ side; QW-side
evidence is transitive through test_qwsv/test_qw_loopback movement, touch triggers and traceline use.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_InitBoxHull | `initBoxHull` (qwworld.luau:99) | VERIFIED | All entity-vs-bbox traces in the verified tests run through it. |
| SV_HullForEntity (+SV_HullForBox) | `world.hullForEntity` / `hullForBox` (qwworld.luau:187,200) | VERIFIED | Hull select by size (hull 0/1/2) for SOLID_BSP; movement tests depend on hull1 selection. |
| SV_CreateAreaNode | `createAreaNode` (qwworld.luau:138) | VERIFIED | depth 4 / AREA_NODES tree as C. |
| SV_ClearWorld | `world.new` (qwworld.luau:167) | VERIFIED | Built per spawnServer in every test. |
| SV_UnlinkEdict | `world.unlinkEdict` (qwworld.luau:427) | VERIFIED | Hooked into vm.unlinkEdict for ED_Free (qwbuiltins.luau:70). |
| SV_TouchLinks | `touchLinks` (qwworld.luau:438) | VERIFIED | test_qwsv item pickup implied by play; trigger touches fire during runCmd linkEdict(touch=true). |
| SV_FindTouchedLeafs | `findTouchedLeafs` (qwworld.luau:497) | VERIFIED | PVS visibility of entities in test_qwsv frames depends on leafnums being right. |
| SV_LinkEdict | `world.linkEdict` (qwworld.luau:528) | VERIFIED | Same tests. |
| SV_HullPointContents | `world.hullPointContents` (qwworld.luau:236) | VERIFIED | Waterlevel checks in settle test. |
| SV_PointContents | `world.pointContents` (qwworld.luau:260) | VERIFIED | Delta: QW C has no CONTENTS_CURRENT truncation (that is NQ); port keeps `truePointContents` split like NQ — both return the same values for id1 maps. |
| SV_RecursiveHullCheck | `world.recursiveHullCheck` (qwworld.luau:290) | VERIFIED | Same midpoint/epsilon algorithm verified against C trace ground truth on the NQ twin; QW copy exercised every test tick. |
| SV_ClipMoveToEntity | `world.clipMoveToEntity` (qwworld.luau:395) | VERIFIED | |
| SV_ClipToLinks | `clipToLinks` (qwworld.luau:616) | VERIFIED | Includes the pass-owner and MOVE_NOMONSTERS rules. |
| SV_MoveBounds | `moveBounds` (qwworld.luau:710) | VERIFIED | |
| SV_Move | `world.move` (qwworld.luau:717) | VERIFIED | QC traceline + all physics use it. |
| (world.h) SV_TestEntityPosition | `world.testEntityPosition` (qwworld.luau:757) | PENDING | Used by pushMove crush logic; untested. |

## pr_cmds.c

Port file: `src/shared/engine/qw/qwbuiltins.luau` (cloned from the verified NQ builtin table with QW
deltas: bprint/sprint levels, logfrag/infokey/stof/multicast). Builtins are exercised end-to-end by
test_qwsv/test_qw_loopback running id1 qwprogs.dat.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| PF_VarString | `varString` (qwbuiltins.luau:35) | VERIFIED | All print builtins go through it in the passing tests. |
| PF_error (10) / PF_objerror (11) | qwbuiltins.luau:155,161 | PENDING | Luau error() instead of SV_Error/ED_Free+abort; not triggered in tests. |
| PF_makevectors (1) | qwbuiltins.luau:75 | VERIFIED | Weapon fire aim in test_qwsv uses v_forward. |
| PF_setorigin (2) | qwbuiltins.luau:82 | VERIFIED | Entity spawn placement in verified boot. |
| PF_setsize (4) / SetMinMaxSize | qwbuiltins.luau:89,126 | VERIFIED | Player hull size drives verified pmove offset math. |
| PF_setmodel (3) | qwbuiltins.luau:99 | VERIFIED | Precache index + brush model min/max; boot depends on it. |
| PF_bprint (23) | qwbuiltins.luau:386 | PENDING | QW signature (level, string) ported; broadcast receipt untested. |
| PF_sprint (24) | qwbuiltins.luau:392 | VERIFIED | QW signature (client, level, string); loopback receives prints. |
| PF_centerprint (73) | qwbuiltins.luau:763 | UNIMPLEMENTED (broken wiring) | Writes to `client.message`, a buffer nothing ever flushes to the wire (the QW send path only drains netchan.message + client.datagram) — centerprints never reach clients. Should route to netchan.message. |
| PF_normalize (9) / PF_vlen (12) / PF_vectoyaw (13) / PF_vectoangles (51) | qwbuiltins.luau:149,170,174,647 | VERIFIED | Aim/movement math in verified play; trunc-toward-zero yaw as C. |
| PF_random (7) | qwbuiltins.luau:135 | VERIFIED | Deterministic LCG (shared with NQ port) — SUBSTITUTED RNG source, same distribution shape; drives item spawns in verified boot. |
| PF_ambientsound (74) | qwbuiltins.luau:775 | VERIFIED | svc_spawnstaticsound into signon; loopback parses signon without error. |
| PF_sound (8) | qwbuiltins.luau:140 | VERIFIED | test_qwsv guncock in soundLog; loopback hears it via PHS. |
| PF_break (6) | qwbuiltins.luau:131 | PENDING | |
| PF_traceline (16) | qwbuiltins.luau:209 | VERIFIED | Shotgun fire traces in test_qwsv. |
| PF_checkpos | — | UNIMPLEMENTED | Stubbed/unused in C too (never registered). |
| PF_newcheckclient / PF_checkclient (17) | qwbuiltins.luau:219,250 | UNIMPLEMENTED (broken wiring) | Logic fully ported but references `bsplib` **which is never required** in qwbuiltins.luau — dangling global, errors if qwprogs calls checkclient. |
| PF_stuffcmd (21) | qwbuiltins.luau:352 | VERIFIED | Handshake "skins"/"cmd spawn" stufftexts drive the verified loopback flow via svr.clientCommands. |
| PF_localcmd (46) | qwbuiltins.luau:605 | PENDING | Only changelevel/restart routed (into changelevelTo, itself unconsumed — see SV_Map_f row); others logged. |
| PF_cvar (45) / PF_cvar_set (72) | qwbuiltins.luau:600,759 | VERIFIED | qwprogs reads deathmatch/teamplay in verified boot. |
| PF_findradius (22) | qwbuiltins.luau:361 | VERIFIED | Explosion/pickup logic in verified play path. |
| PF_dprint (25) | qwbuiltins.luau:404 | VERIFIED | |
| PF_ftos (26) / PF_vtos (27) / PF_fabs (43) | qwbuiltins.luau:408,420,529 | VERIFIED | %5.1f/%d formatting as C. |
| PF_Spawn (14) / PF_Remove (15) | qwbuiltins.luau:188,192 | VERIFIED | Entity lifecycle in verified boot/play. |
| PF_Find (18) | qwbuiltins.luau:283 | VERIFIED | Spawn-point selection in verified spawn. |
| PR_CheckEmptyString | `checkEmptyString` (qwbuiltins.luau:303) | VERIFIED | |
| PF_precache_file (68/77) | qwbuiltins.luau:723 | VERIFIED | No-op returning parm, as C. |
| PF_precache_sound (19/76) / PF_precache_model (20/75) | qwbuiltins.luau:309,328 | VERIFIED | Precache lists feed verified soundlist/modellist; ss_loading gate as C. |
| PF_coredump (28) / PF_traceon (29) / PF_traceoff (30) / PF_eprint (31) | qwbuiltins.luau:426-435 | PENDING | Debug stubs (coredump prints a notice; eprint no-op). |
| PF_walkmove (32) | qwbuiltins.luau:437 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global (no require) — see sv_move.c section. |
| PF_droptofloor (34) | qwbuiltins.luau:461 | VERIFIED | Items settle onto floors in verified boot (item_shells present at valid origins). |
| PF_lightstyle (35) | qwbuiltins.luau:487 | PENDING (partial bug) | Registry write works (spawnF sends styles — loopback "lightstyles received"). **Bug:** the live-broadcast branch compares `svr.state ~= svr.ss_active` where `ss_active` is nil (state is 2), so it always early-returns; and it writes to unflushed `client.message` anyway — runtime style changes never reach connected clients. |
| PF_rint (36) / PF_floor (37) / PF_ceil (38) | qwbuiltins.luau:507-517 | VERIFIED | rint rounds half away from zero as C. |
| PF_checkbottom (40) | qwbuiltins.luau:519 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global. |
| PF_pointcontents (41) | qwbuiltins.luau:524 | VERIFIED | Water checks in verified play. |
| PF_nextent (47) | qwbuiltins.luau:619 | VERIFIED | |
| PF_aim (44) | qwbuiltins.luau:533 | PENDING | Full port incl. teamplay filter and sv_aim cvar; QW id1 sets sv_aim=2 (aim disabled: dist<bestdist never true) so play never exercises the assist branch. |
| PF_changeyaw (49) | qwbuiltins.luau:643 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global. |
| WriteDest / Write_GetClient | `writeDest` (qwbuiltins.luau:674) | PENDING | MSG_MULTICAST added (QW). **Gap:** MSG_ONE returns unflushed `client.message` (C uses ClientReliableWrite → netchan) and MSG_BROADCAST returns `svr.datagram` which is never copied to clients (see SV_UpdateToReliableMessages row) — both destinations are dead ends on the wire. MSG_MULTICAST (the one id1 QW QC actually uses for temp entities) is live and loopback-verified via sounds. |
| PF_WriteByte..PF_WriteEntity (52-59) | qwbuiltins.luau:694-717 | VERIFIED | Temp-entity writes ride MSG_MULTICAST through verified svMulticast; WriteAngle uses NQ byte angle (C QW server also writes byte angles here). |
| PF_makestatic (69) | qwbuiltins.luau:728 | VERIFIED | svc_spawnstatic in signon parsed by loopback client. |
| PF_setspawnparms (78) | qwbuiltins.luau:806 | PENDING | Copies client spawn_parms to parm globals; decoder untested. |
| PF_changelevel (70) | qwbuiltins.luau:750 | PENDING | Sets changelevelTo once (double-issue guard as C); consumer missing in QW boot (see SV_Map_f). |
| PF_logfrag (79) | qwbuiltins.luau:820 | PENDING | Ring buffer via svr.logfrag; format `{killer,killee,time}` instead of C's `\k\d\n` text log. |
| PF_infokey (80) | qwbuiltins.luau:828 | PENDING | serverinfo (ent 0) / client userinfo lookup; C's synthetic keys (ip, ping) absent. |
| PF_stof (81) | qwbuiltins.luau:841 | PENDING | com.atof. |
| PF_multicast (82) | qwbuiltins.luau:845 | VERIFIED | Routes to svMulticast; loopback PHS sound + temp entities. |
| PF_Fixme | error on unknown builtin (vm dispatch) | VERIFIED | VM errors on unregistered builtin numbers. |

## pr_edict.c

Shared NQ port: `src/shared/engine/progs/vm.luau` (+`progs.luau` loader). Verified on the NQ side; QW-side
evidence via test_qwsv/test_qw_loopback which run id1 qwprogs.dat through it with `PROGHEADER_CRC_QW`.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ED_ClearEdict | `clearEdict` (vm.luau:259) | VERIFIED | Entity churn in verified play. |
| ED_Alloc | `vmlib.alloc` (vm.luau:265) | VERIFIED | Slot reuse after 0.5s as C. |
| ED_Free | `vmlib.free` (vm.luau:289) | VERIFIED | Unlink hook + field reset. |
| ED_GlobalAtOfs / ED_FieldAtOfs / ED_FindField / ED_FindGlobal / ED_FindFunction | name maps in progs.luau/`vmlib.findFieldDef`/`vmlib.findFunction` | VERIFIED | qwdefs.build resolves the whole QW ABI by name at load (qwdefs.luau) — boot fails loudly if any required def is missing. |
| GetEdictFieldValue | field lookups via qwdefs `ent` table | SUBSTITUTED | Static name→offset resolution replaces per-call cached lookup. Note: the `gravity`/`maxspeed` optional-field pickup that C does with it is missing (see SV_UpdateToReliableMessages). |
| PR_ValueString / PR_UglyValueString / PR_GlobalString(NoContents) | — | UNIMPLEMENTED | Debug printing (edict dumps) not ported. |
| ED_Print / ED_Write / ED_PrintNum / ED_PrintEdicts / ED_PrintEdict_f / ED_Count / ED_WriteGlobals / ED_ParseGlobals | — | UNIMPLEMENTED | Console debug + savegame globals; QW has no savegames. |
| ED_NewString | inside `vmlib.parseEpair` (vm.luau:607) | VERIFIED | `\n` escape handling. |
| ED_ParseEdict | `vmlib.parseEdict` (vm.luau:650) | VERIFIED | anglehack/light→light_lev handling; e1m1 entities load. |
| ED_LoadFromFile | `vmlib.loadFromFileQW` (vm.luau:791) | VERIFIED | test_qwsv: deathmatch inhibit flags (13 inhibited, no monsters in DM). |
| PR_LoadProgs | `progslib.load` (progs.luau:50) | VERIFIED | CRC gate via defs.PROGHEADER_CRC_QW (qwsv.luau:263). |
| PR_Init | — | SUBSTITUTED | Command/cvar registration replaced by module init. |
| EDICT_NUM / NUM_FOR_EDICT | `vmlib.edictNum` / `ed.num` | VERIFIED | |

## pr_exec.c

Shared NQ port: `src/shared/engine/progs/vm.luau`.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| PR_PrintStatement / PR_StackTrace / PR_Profile_f | — | UNIMPLEMENTED | Profiling/trace printing not ported (vm.trace flag exists but prints nothing). |
| PR_RunError | `runError` (vm.luau:311) | VERIFIED | Errors carry the function name; surfaced through Luau error. |
| PR_EnterFunction / PR_LeaveFunction | `enterFunction`/`leaveFunction` (vm.luau:320,352) | VERIFIED | Parm save/restore across recursion — id1 qwprogs runs full games in the tests. |
| PR_ExecuteProgram | `vmlib.exec` (vm.luau:374) | VERIFIED | Whole opcode interpreter; every test exercises it, incl. OP_STATE through the QW ABI (vm.stateOffsets, qwsv.luau:274). |
| PR_GetString / PR_SetString | `vmlib.getString`/`allocString`/`newString` (vm.luau:123-148) | VERIFIED | Dynamic string table replaces pointer arithmetic (GC platform). |

## model.c

Shared NQ port: `src/shared/engine/bsp/bsp.luau` + `src/shared/engine/models/models.luau` (registry).
QW's server model.c is the brush-only loader; the port loads the same lumps.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Mod_Init / Mod_ClearAll / Mod_FindName / Mod_LoadModel / Mod_ForName | `models.newRegistry`/`models.forName` (models.luau) | VERIFIED | e1m1 + submodels (`*i`) load in every QW test. |
| Mod_PointInLeaf | `bsp.pointInLeaf` (bsp.luau:760) | VERIFIED | PHS multicast + checkclient paths. |
| Mod_DecompressVis / Mod_LeafPVS | `bsp.leafPVS` (bsp.luau:779) | VERIFIED | Fat-PVS entity culling + PHS sound in loopback. |
| Mod_LoadVertexes/Edges/Surfedges/Textures/Lighting/Visibility/Entities/Submodels/Texinfo/Faces/Nodes/Leafs/Clipnodes/Marksurfaces/Planes + CalcSurfaceExtents + Mod_SetParent + Mod_MakeHull0 + Mod_LoadBrushModel | `bsp.load` internals (bsp.luau:187-669) | VERIFIED | Hull/clipnode data is ground-truth checked transitively: test_qw_pmove runs the C pmove's own hull tracing against the port-loaded e1m1 within 0.000122 units. |
| Mod_LoadTextures (rendering payload) | client-side gfx concern | SUBSTITUTED | Server only needs hulls/PVS/entities; texture pixels handled by the render pipeline. |

## mathlib.c / math.s

Shared NQ port: `src/shared/engine/common/mathlib.luau` + native `vector` type.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| AngleVectors | `mathlib.angleVectors` | VERIFIED | pmove ground truth matches C within 1e-4 — angle math must agree. |
| VectorNormalize | `mathlib.normalize` | VERIFIED | Same. |
| DotProduct/VectorAdd/Sub/Copy/Scale/Length etc. | Luau `vector` builtins | SUBSTITUTED | Native SIMD vector type replaces the macro/asm set; correctness bounded by the pmove/trace ground-truth tests. |
| BoxOnPlaneSide (math.s/mathlib.c) | axis-aligned checks in world/bsp code | SUBSTITUTED | Only used for culling paths that the port expresses directly. |

## zone.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Z_*/Hunk_*/Cache_* allocators | — | SUBSTITUTED | Luau GC + `buffer` objects replace manual zone/hunk/cache memory management wholesale. |

## net_chan.c (QW/client, shared with server)

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Netchan_Init | `qwnetchan.new` (qwnetchan.luau:22) | VERIFIED | Loopback handshake + play. Delta: no qport (no NAT rebinding on Roblox). |
| Netchan_OutOfBand / Netchan_OutOfBandPrint | — | SUBSTITUTED | No connectionless packets on the transport. |
| Netchan_Setup | `qwnetchan.new` per client | VERIFIED | |
| Netchan_CanPacket / Netchan_CanReliable | — | SUBSTITUTED | Rate throttling and reliable-in-flight gating meaningless on a reliable+ordered remote; senders always transmit. |
| Netchan_Transmit | `qwnetchan.transmit` (qwnetchan.luau:34) | VERIFIED | Loopback: sequence numbers keep their exact protocol role (frames ring, delta ack). **Substitution:** reliable retransmit/fragment bits replaced by an in-band reliable block `[seq][ack][reliable][datagram]` because Roblox remotes are reliable+ordered — the reliable stream cannot be lost, so no resend state. |
| Netchan_Process | `qwnetchan.process` (qwnetchan.luau:57) | VERIFIED | Stale/duplicate rejection, drop_count (net_drop) feeding SV_RunCmd's dropped-cmd replay — loopback runs with 1 tick latency. Delta: 32-bit sequence wrap unhandled (~2.3y at 60Hz). |

## pmove.c / pmovetst.c (QW/client, executed by the server in SV_RunCmd)

Port file: `src/shared/engine/qw/pmove.luau`. Ground truth: `tools/pmove_truth.c` `#include`s the
VERBATIM `pmove.c`/`pmovetst.c`; `test_qw_pmove.luau` replays the identical 300-tick script on
port-loaded e1m1 and matches within 0.000122 units position / 0.000109 velocity, with onground and
waterlevel agreeing on every tick (fixture covers 238 ground / 62 air ticks; it never enters water).

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Pmove_Init / PM_InitBoxHull | `hullForBox` (pmove.luau:109) | SUBSTITUTED | Fresh 6-clipnode hull per call instead of a mutated static (no globals on a shared-module platform); identical plane math — covered by the ground truth. |
| PM_ClipVelocity | `clipVelocity` (pmove.luau:345) | VERIFIED | test_qw_pmove ground truth (slide-along-wall phases in the script). |
| PM_FlyMove | `flyMove` (pmove.luau:371) | VERIFIED | Ground truth incl. air ticks. |
| PM_GroundMove | `groundMove` (pmove.luau:463) | VERIFIED | Ground truth: 238 ground ticks incl. step-up paths on e1m1. |
| PM_Friction | `friction` (pmove.luau:538) | VERIFIED | Stop phase decelerates identically. |
| PM_Accelerate / PM_AirAccelerate | pmove.luau:584,604 | VERIFIED | Ground truth accel curves. |
| PM_WaterMove | `waterMove` (pmove.luau:628) | PENDING | Ported; fixture never enters water (waterlevel 0 for all 300 ticks) — no ground-truth coverage. |
| PM_AirMove | `airMove` (pmove.luau:661) | VERIFIED | Ground truth. |
| PM_CatagorizePosition | `catagorizePosition` (pmove.luau:697) | VERIFIED | onground agrees every tick; water branches only trivially covered (always empty). |
| JumpButton | `jumpButton` (pmove.luau:745) | VERIFIED | Jump phases (ticks 121-160, 201-240) match; oldbuttons latching. |
| CheckWaterJump | `checkWaterJump` (pmove.luau:788) | PENDING | Ported; unreachable in the fixture (no water). |
| NudgePosition | `nudgePosition` (pmove.luau:818) | VERIFIED | Runs every tick in both C and port (positions stay equal through it). |
| SpectatorMove | `spectatorMove` (pmove.luau:842) | PENDING | Ported; no spectator test anywhere. |
| PlayerMove | `pmove.playerMove` (pmove.luau:894) | VERIFIED | The top-level function the ground-truth test calls 300 times. |
| PM_HullPointContents | `hullPointContents` (pmove.luau:145) | VERIFIED | Ground truth (contents drive categorize). |
| PM_PointContents | `pointContents` (pmove.luau:278) | VERIFIED | Same. |
| PM_RecursiveHullCheck | `recursiveHullCheck` (pmove.luau:165) | VERIFIED | Every trace of every tick matches C to 1e-4. |
| PM_TestPlayerPosition | `testPlayerPosition` (pmove.luau:266) | VERIFIED | NudgePosition calls it each tick. |
| PM_PlayerMove (pmovetst trace) | `playerTrace` (pmove.luau:285) | VERIFIED | Same ground truth. |

## Totals

Counted per manifest row (some rows deliberately merge families of C functions, e.g. the 11
ClientReliableWrite_* variants, the 7 IP-filter commands, the 19 Mod_Load* lump loaders — so the
underlying C function count is higher than the row count in the SUBSTITUTED/VERIFIED buckets):

| Status | Rows |
|---|---|
| VERIFIED | 120 |
| PENDING | 51 |
| SUBSTITUTED | 41 |
| UNIMPLEMENTED | 24 |
| Total rows | 236 |

Headline: the whole gameplay core (pmove vs verbatim-C ground truth, SV_RunCmd, sv_phys frame loop,
world/trace, delta entity codec, netchan-lite, handshake, PVS/PHS multicast, stats) is VERIFIED by four
passing offline tests. The UNIMPLEMENTED bucket is dominated by console/debug tooling plus five
genuinely broken wirings listed below; the PENDING bucket is mostly chat/pause/spectator/setinfo paths
and pusher physics that run in tests but are never asserted.

### Port-side additions with no C counterpart

| Addition | Location | Justification |
|---|---|---|
| `svr.soundLog` / `svr.printLog` / `client.prints` mirrors | qwsv.luau:160-188, 224 | Justified: offline tests assert sounds/prints without a client (test_qwsv guncock check reads soundLog). Unbounded growth in long sessions — soundLog/printLog are never trimmed (fraglog is capped at 512). |
| `svr.startParticle` logging into soundLog | qwsv.luau:220 | Justified as a stub for PF_particle (QW C server sends svc_particle via multicast — wire emission is missing, so this doubles as the gap marker). PENDING wire path. |
| `client.send` transport hook + `send_message` 1:1 reply flag | qwsv.luau:66-67, replyToClient | Justified: replaces UDP socket addressing; the strict one-reply-per-packet lockstep documents why (delta/prediction sequence alignment) and the loopback test depends on it. |
| `svr.changelevelTo`/`changelevelIssued` | qwsv.luau:242 | Justified as the PF_changelevel latch (C calls Cbuf_AddText "map ..."), but no QW consumer exists yet — flagged under SV_Map_f. |
| Deterministic LCG `svr.rand` | qwsv.luau:231 | Justified: reproducible offline tests; same generator as the verified NQ port. |
| `qwsv.connectClient` (alloc+spawn+spawned in one call) | qwsv.luau:453 | Justified: offline-test convenience path bypassing the wire handshake (test_qwsv uses it; loopback uses the real handshake). |
| ServerStorage diagnostics attributes (SV_Time/SV_Edicts/SV_Origin/SV_Engine) | qwserver.luau Heartbeat | Justified: Studio observability; 0.5s throttle; server-only storage, not replicated to clients. |
| `_G.RQ_SERVER` | qwserver.luau | Justified in-code ("studio debugging access"). Debug backdoor — acceptable server-side; clients cannot reach server globals. |
| NQ-only physics carried in qwphys.luau: `checkStuck`, `checkWater`, `wallFriction`, `tryUnstick`, `walkMove`, `physicsClient` | qwphys.luau:464-723 | NO JUSTIFICATION FOUND — QW's sv_phys.c has none of these (players move via pmove; the file header says so itself). Dead code inherited from the NQ clone; `physicsClient` is unreachable (the physics loop skips client slots). Candidates for deletion. |
| `world.truePointContents` in qwworld.luau | qwworld.luau:268 | NO JUSTIFICATION FOUND for the QW copy — QW's world.c has a single SV_PointContents with no CONTENTS_CURRENT clamp; the split is an NQ-ism carried over (harmless, both agree on id1 data). |
| `svr.flushMulticast` legacy hook | qwsv.luau:192 | Marked "legacy" in-code (builtin 82 now routes svMulticast). NO JUSTIFICATION FOUND for keeping it — no remaining caller found in the QW path; deletion candidate. |
| `qwents.parseDelta` / `parsePacketEntities` / qwcl.luau client half | qwents.luau:286+, qwcl.luau | Justified: client-side counterparts (CL_ParseDelta etc.) needed for the loopback test and the Roblox client; out of scope for this server manifest. |

### Known port-side defects found during this audit (cross-referenced above)

1. `qwbuiltins.luau` never requires `bsplib` or `sv_move` — builtins 17 (checkclient), 32 (walkmove),
   40 (checkbottom), 49 (changeyaw), 67 (movetogoal) reference dangling globals and will error at
   runtime if qwprogs calls them (id1 deathmatch happens not to).
2. MSG_ONE (`client.message`) and MSG_BROADCAST (`svr.datagram`) WriteDest targets are never flushed
   to the wire; PF_centerprint shares the dead `client.message` buffer.
3. SV_UpdateToReliableMessages is only partially ported: frags never rebroadcast during play,
   svc_entgravity/svc_maxspeed never sent.
4. PF_lightstyle's live-broadcast branch is dead (`svr.ss_active` is nil) — runtime lightstyle
   changes are invisible until a client respawns.
5. changelevel is latched but never consumed in the QW boot — fraglimit/timelimit end-of-map stalls.
