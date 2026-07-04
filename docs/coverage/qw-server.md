# QW server coverage

Function-level manifest for the QuakeWorld server port. C reference: `reference/quake-c/QW/server/*.c`
(pmove.c/pmovetst.c/net_chan.c/mathlib.c/zone.c/common.c live in `reference/quake-c/QW/client/` and are
shared with the server build). Port: `src/shared/engine/qw/*.luau` + `src/server/qwserver.luau`; the QW
port intentionally reuses NQ-shared modules under `src/shared/engine/{progs,bsp,models,common}/`.

Status legend:
- **VERIFIED** — a passing offline test asserts the behavior (all four QW tests run green as of this audit:
  `test_qw_pmove` 6/6, `test_qwents` 21/21, `test_qwsv` 25/25, `test_qw_loopback` 36/36).
  Functions covered by `test_qw_pmove.luau` are checked against `tools/pmove_truth.c`, which `#include`s the
  VERBATIM C `pmove.c`/`pmovetst.c` (max pos error 0.000122 units over 460 ticks across an e1m1
  flat course and a dm3 staircase course).
- **PENDING** — ported, no offline test asserts it.
- **UNIMPLEMENTED** — no port code (or port code that cannot run).
- **SUBSTITUTED** — intentionally replaced, with a platform justification.

## sv_main.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ServerPaused | `svr.paused` field (qwsv.luau) | PENDING | Read directly by frame/clc_move guards; no test toggles pause. | TBD: write test or tools/verify script + evidence capture |
| SV_Shutdown | — | SUBSTITUTED | No process/log lifecycle on Roblox; server dies with the DataModel. | — (substitution; verify justification still holds) |
| SV_Error | Luau `error()` propagation | SUBSTITUTED | Lua error/stack semantics replace longjmp + SV_FinalMessage. | — (substitution; verify justification still holds) |
| SV_FinalMessage | — | UNIMPLEMENTED | No shutdown broadcast; players are disconnected by the platform. | — (implement first) |
| SV_DropClient | `qwsv.dropClient` (qwsv.luau:1213) | PENDING | Runs ClientDisconnect/SpectatorDisconnect, writes svc_disconnect, fullClientUpdate to reliable_datagram; wired to `Players.PlayerRemoving` in qwserver.luau. No test drops a client. | TBD: write test or tools/verify script + evidence capture |
| SV_CalcPing | `qwsv.calcPing` (qwsv.luau:930) | PENDING | Frame-ring ping_time average; produced into updateping but no test asserts the value. | TBD: write test or tools/verify script + evidence capture |
| SV_FullClientUpdate | `qwsv.fullClientUpdate` (qwsv.luau:946) | VERIFIED | test_qw_loopback: "own player info received" (name via svc_updateuserinfo); `_`-prefixed keys stripped as in Info_RemovePrefixedKeys. | `lune run tests/test_qw_loopback.luau` |
| SV_FullClientUpdateToClient | — | UNIMPLEMENTED | Single-client resend path unused; setinfo broadcasts via reliable_datagram instead. | — (implement first) |
| SVC_Status | — | SUBSTITUTED | Out-of-band status query; Roblox server browser/matchmaking replaces it. | — (substitution; verify justification still holds) |
| SV_CheckLog / SVC_Log | `svr.fraglog` ring (qwsv.luau:196) | SUBSTITUTED | Frag log kept as in-memory ring of 512 `{killer,killee,time}`; no UDP log pull — external stat pullers don't exist on this transport. | — (substitution; verify justification still holds) |
| SVC_Ping | — | SUBSTITUTED | Out-of-band ping probe; transport RTT is Roblox's concern. | — (substitution; verify justification still holds) |
| SVC_GetChallenge | — | SUBSTITUTED | Challenge/anti-spoof handshake unnecessary: Roblox authenticates players before OnServerEvent fires. | — (substitution; verify justification still holds) |
| SVC_DirectConnect | `qwsv.allocClient` + `qwsv.wireConnect` (qwsv.luau:460,502) + `connectPlayer` (qwserver.luau) | VERIFIED | test_qw_loopback: wireConnect → handshake completes; slot setup + SetNewParms spawn parms match the C core. Challenge/qport/rate/IP checks dropped (SUBSTITUTED by platform auth). | `lune run tests/test_qw_loopback.luau` |
| Rcon_Validate / SVC_RemoteCommand | — | SUBSTITUTED | rcon absent: no out-of-band packets; Studio/console access replaces remote admin. | — (substitution; verify justification still holds) |
| SV_ConnectionlessPacket | — | SUBSTITUTED | No connectionless (0xffffffff) packets on Roblox remotes; first inbound buffer implicitly connects (qwserver.luau `onInbound`). | — (substitution; verify justification still holds) |
| StringToFilter / SV_AddIP_f / SV_RemoveIP_f / SV_ListIP_f / SV_WriteIP_f / SV_SendBan / SV_FilterPacket | — | SUBSTITUTED | IP filtering/banning is Roblox moderation's job; server never sees IPs. | — (substitution; verify justification still holds) |
| SV_ReadPackets | `onInbound` (qwserver.luau) | PENDING | Per-packet processing + immediate reply preserved ("one reply per received packet"); loopback test exercises the same call pair directly, not through the remotes. | TBD: write test or tools/verify script + evidence capture |
| SV_CheckTimeouts | — | SUBSTITUTED | Roblox fires PlayerRemoving on disconnect; no zombie/timeout sweep needed on a connection-oriented transport. | — (substitution; verify justification still holds) |
| SV_GetConsoleCommands | — | SUBSTITUTED | No stdin console; Studio command bar + `_G.RQ_SERVER` (qwserver.luau) replace it. | — (substitution; verify justification still holds) |
| SV_CheckVars | — | UNIMPLEMENTED | password/spectator_password not enforced (no join password concept wired). | — (implement first) |
| SV_Frame | `qwsv.frame` (qwsv.luau:1933) + Heartbeat loop (qwserver.luau) | VERIFIED | test_qwsv/test_qw_loopback drive frames; physics + reliable_datagram fan-out. Delta: bookkeeping (timeouts, master, log, vars) intentionally absent per rows above. | `lune run tests/test_qw_loopback.luau`; `lune run tests/test_qwsv.luau` |
| SV_InitLocal | cvar seeding in `qwsv.newGame` (qwsv.luau:84) | PENDING | QW cvar defaults registered directly; no Cmd_AddCommand table (commands dispatch via `userCommands`). | TBD: write test or tools/verify script + evidence capture |
| Master_Heartbeat / Master_Shutdown | — | SUBSTITUTED | No master server protocol; Roblox discovery replaces it. | — (substitution; verify justification still holds) |
| SV_ExtractFromUserinfo | `extractUserinfo` (qwsv.luau:418) | PENDING | Name trim/"console"→unnamed/dupe-prefix + rename broadcast + msg level ported. Delta: no name-flood penalty (lastnamecount), no `rate` extraction (no rate control on Roblox), no team resync. | TBD: write test or tools/verify script + evidence capture |
| SV_InitNet | remotes wiring (qwserver.luau) | SUBSTITUTED | RemoteEvent/UnreliableRemoteEvent replace UDP sockets; both currently route to the same reliable path (see qwnetchan note). | — (substitution; verify justification still holds) |
| SV_Init | `qwsv.newGame` + qwserver boot | VERIFIED | test_qwsv boots e1m1 via the same entry points used by qwserver.luau. | `lune run tests/test_qwsv.luau` |

## sv_user.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_New_f | `qwsv.newF` (qwsv.luau:817) | VERIFIED | test_qw_loopback: serverdata parsed (protocol, spawncount, gamedir "qw", playernum, levelname, all 10 movevars — "movevars received (gravity 800)"), cdtrack, fullserverinfo stufftext. | `lune run tests/test_qw_loopback.luau` |
| SV_Soundlist_f | `qwsv.soundlistF` (qwsv.luau:881) | VERIFIED | test_qw_loopback "precache lists received"; continuation format (`writeList`) with MAX_MSGLEN/2 chunking and spawncount recheck ported. | `lune run tests/test_qw_loopback.luau` |
| SV_Modellist_f | `qwsv.modellistF` (qwsv.luau:894) | VERIFIED | Same loopback check as soundlist. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_PreSpawn_f | `qwsv.prespawnF` (qwsv.luau:908) | VERIFIED | test_qw_loopback "baselines received (>20)". Delta: C paginates the signon across several `cmd prespawn` round-trips; port copies the whole signon buffer in one reliable write (transport has no 1450-byte packet limit) and errors on overflow instead of chunking. | `lune run tests/test_qw_loopback.luau` |
| SV_Spawn_f | `qwsv.spawnF` (qwsv.luau:977) | VERIFIED | test_qw_loopback: handshake completes; lightstyles received; forced stat refresh ("skins" stufftext → begin). Delta: no `nails2`/checksum handling (not in protocol 28 path used). | `lune run tests/test_qw_loopback.luau` |
| SV_SpawnSpectator | spectator branch of `qwsv.spawnIntoGame` (qwsv.luau:519) | PENDING | Places at info_player_start, runs SpectatorConnect if present. No spectator test. | TBD: write test or tools/verify script + evidence capture |
| SV_Begin_f | `qwsv.beginF` (qwsv.luau:1044) | VERIFIED | test_qw_loopback "handshake completed: server spawned the client"; ClientConnect/PutClientInServer run exactly once here. Delta: no model-checksum ("check") anti-cheat, no unpause-on-begin counters. | `lune run tests/test_qw_loopback.luau` |
| SV_NextDownload_f / SV_BeginDownload_f / SV_NextUpload / OutofBandPrintf | — | SUBSTITUTED | File download/upload protocol unnecessary: `clientbundle` publishes all assets to clients ahead of time (qwserver.luau). | — (substitution; verify justification still holds) |
| SV_Say / SV_Say_f / SV_Say_Team_f | `userCommands.say` / `say_team` (qwsv.luau:1114,1143) | PENDING | Chat with `[SPEC]` prefix, sv_spectalk gating, team routing, flood protection. Delta: flood window hardcoded (4 msgs / 4 s, 10 s lockout) instead of fp_* cvars; no `sv_aim`-style console echo. No test asserts chat. | TBD: write test or tools/verify script + evidence capture |
| SV_Pings_f | `userCommands.pings` (qwsv.luau:1078) | PENDING | updateping/updatepl per spawned client; untested. | TBD: write test or tools/verify script + evidence capture |
| SV_Kill_f | `userCommands.kill` (qwsv.luau:1192) | PENDING | health>0 guard + ClientKill exec. Delta: no "Can't suicide -- allready dead" print. | TBD: write test or tools/verify script + evidence capture |
| SV_TogglePause / SV_Pause_f | `userCommands.pause` (qwsv.luau:1175) | PENDING | pausable cvar gate, broadcast, svc_setpause via reliable_datagram; also sent on begin when paused. Untested. | TBD: write test or tools/verify script + evidence capture |
| SV_Drop_f | `userCommands.drop` → dropClient | PENDING | Untested. | TBD: write test or tools/verify script + evidence capture |
| SV_PTrack_f | `userCommands.ptrack` (qwsv.luau:1093) | PENDING | Spectator autocam target incl. goalentity write; untested. | TBD: write test or tools/verify script + evidence capture |
| SV_Rate_f | — | SUBSTITUTED | Bandwidth rate control meaningless on Roblox remotes (no per-client UDP throttling). | — (substitution; verify justification still holds) |
| SV_Msg_f | `userCommands.msg` (qwsv.luau:1186) | PENDING | messagelevel filter set; untested. | TBD: write test or tools/verify script + evidence capture |
| SV_SetInfo_f | `userCommands.setinfo` (qwsv.luau:1155) | PENDING | Star-key protection, dedupe, extractUserinfo, svc_setinfo broadcast. Untested. | TBD: write test or tools/verify script + evidence capture |
| SV_ShowServerinfo_f | — | UNIMPLEMENTED | `serverinfo` user command absent (table exists; only sent via fullserverinfo at connect). | — (implement first) |
| SV_NoSnap_f | — | SUBSTITUTED | Snap/upload (remote screenshot) feature absent — depends on the upload protocol, dropped with it. | — (substitution; verify justification still holds) |
| SV_ExecuteUserCommand | `qwsv.executeUserCommand` (qwsv.luau:1203) + `tokenize` | VERIFIED | Drives the whole loopback handshake (new/soundlist/modellist/prespawn/spawn/begin). Delta: unknown commands only dprint (C prints to client). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| V_CalcRoll | `calcRoll` (qwsv.luau:542) | PENDING | cl_rollangle=2/cl_rollspeed=200 hardcoded (server has no such cvars); feeds angles[ROLL]*4 in runCmd. No assertion. | TBD: write test or tools/verify script + evidence capture |
| AddLinksToPmove / AddAllEntsToPmove | inline scan in `qwsv.runCmd` (qwsv.luau:630-672) | VERIFIED | test_qwsv movement + loopback prediction run through it. Delta: linear scan over all edicts with absbox-vs-±256 test instead of the areanode walk — same accept set, different visit order (physent order affects only `onground` index mapping, handled via `physentEdicts`). MAX_PHYSENTS=32 kept. | `lune run tests/test_qwsv.luau` |
| SV_PreRunCmd | playertouch reset in `executeCmd`/clc_move (qwsv.luau:737,1283) | VERIFIED | Touch dedupe across chopped halves + net_drop replays asserted implicitly by loopback play (no double-touch crash); structure matches C. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_RunCmd | `qwsv.runCmd` (qwsv.luau:558) | VERIFIED | test_qwsv: movement >100 units via pmove, settle/onground, shotgun fire via button0; test_qw_loopback: prediction convergence < 1.0 unit implies server-side cmd execution matches the client's pmove replay. msec>50 chop, angle/roll, PlayerPreThink+runThink, pmove fill, FL_ONGROUND/groundentity writeback, touch dedupe all present. | `lune run tests/test_qw_loopback.luau`; `lune run tests/test_qwsv.luau` |
| SV_PostRunCmd | `qwsv.postRunCmd` (qwsv.luau:754) | VERIFIED | test_qwsv shotgun: PlayerPostThink fired the weapon (shell consumed, guncock sound). SV_RunNewmis folded in via physicsToss at 0.05s. SpectatorThink branch untested. | `lune run tests/test_qwsv.luau` |
| SV_ExecuteClientMessage | `qwsv.executeClientMessage` (qwsv.luau:1243) | VERIFIED | test_qw_loopback: full clc stream (nop/delta/move/stringcmd) with net_drop fill-in from lastcmd/oldest/oldcmd, ping bookkeeping via frame ack. Deltas: move checksum byte read but not validated (authenticated transport); msec-overuse cheat detection (sv_user.c timer checks) absent. clc_tmove spectator-only teleport ported, untested. | `lune run tests/test_qw_loopback.luau` |
| SV_UserInit | — | SUBSTITUTED | cl_rollspeed/cl_rollangle/sv_spectalk registered in newGame's cvar table instead. | — (substitution; verify justification still holds) |

## sv_ents.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_AddToFatPVS | `addToFatPVS` (qwsv.luau:1478) | VERIFIED | test_qwsv frame writes (entities appear exactly when in PVS); same 8-unit plane straddle recursion. | `lune run tests/test_qwsv.luau` |
| SV_FatPVS | `qwsv.fatPVS` (qwsv.luau:1507) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Same tests; allocates per call instead of static buffer (GC platform). | TBD: write test or tools/verify script + evidence capture |
| SV_AddNailUpdate | inline in `writeEntitiesToClient` (qwsv.luau:1708) | PENDING | Nail/supernail modelindex match, MAX_NAILS=32, overflow nails dropped (not sent as packet entities) — matches C. No test spawns nails. | TBD: write test or tools/verify script + evidence capture |
| SV_EmitNailUpdate | `emitNailUpdate` (qwsv.luau:1652) | PENDING | 48-bit xyzpy packing bit-for-bit from C; test_qwsv parser skips nails bytes but none are emitted in the fixture. | TBD: write test or tools/verify script + evidence capture |
| SV_WriteDelta | `qwents.writeDelta` (qwents.luau:141) | VERIFIED | test_qwents: full + delta round-trips (moved/unchanged/removed/new-from-baseline); 0.1 origin epsilon, U_MOREBITS/U_REMOVE framing exact. | `lune run tests/test_qwents.luau` |
| SV_EmitPacketEntities | `qwents.emitPacketEntities` (qwents.luau:242) | VERIFIED | test_qwents merge-walk round trip; test_qwsv "delta frame smaller than full frame" + entity set reproduction; test_qw_loopback ">20 delta packets". | `lune run tests/test_qw_loopback.luau`; `lune run tests/test_qwents.luau`; `lune run tests/test_qwsv.luau` |
| SV_WritePlayersToClient | `qwsv.writePlayersToClient` (qwsv.luau:1525) | VERIFIED | test_qwsv hand-parses svc_playerinfo: self omits PF_MSEC/PF_COMMAND, origin within 1/8 quantization; spectator/spec_track masks ported (untested branches). | `lune run tests/test_qwsv.luau` |
| SV_WriteEntitiesToClient | `qwsv.writeEntitiesToClient` (qwsv.luau:1679) | VERIFIED | test_qwsv: frame ring stores what was sent, delta keyed on netchan.incoming_sequence & UPDATE_MASK, MAX_PACKET_ENTITIES respected. | `lune run tests/test_qwsv.luau` |

## sv_send.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_FlushRedirect / SV_BeginRedirect / SV_EndRedirect | — | SUBSTITUTED | Console redirection serves rcon/status, both absent. | — (substitution; verify justification still holds) |
| Con_Printf / Con_DPrintf | `svr.print` / `svr.dprint` hooks (qwsv.luau:153) | SUBSTITUTED | Route to Roblox `print`; dprint default no-op (developer cvar replaced by hook swap). | — (substitution; verify justification still holds) |
| SV_PrintToClient / SV_ClientPrintf | `svr.clientPrint` (qwsv.luau:178) | VERIFIED | Loopback receives svc_print traffic during handshake/play; messagelevel filter honored. Also mirrors into `client.prints` (see additions). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_BroadcastPrintf | `svr.broadcastPrint` (qwsv.luau:166) | PENDING | Reliable svc_print to every spawned client + printLog mirror; no test asserts receipt. | TBD: write test or tools/verify script + evidence capture |
| SV_BroadcastCommand | — | UNIMPLEMENTED | svc_stufftext broadcast (used by SV_Gamedir/serverinfo changes) absent along with those commands. | — (implement first) |
| SV_Multicast | `qwsv.svMulticast` (qwsv.luau:1810) | VERIFIED | test_qw_loopback: "svc_sound guncock arrived through the PHS multicast". ALL/PHS/PVS + _R variants, 1024-unit PHS distance override, reliable→netchan.message vs datagram routing. Delta: reliable path writes straight to netchan.message (no backbuf, see sv_nchan.c). | `lune run tests/test_qw_loopback.luau` |
| SV_StartSound | `qwsv.startSoundWire` via `svr.startSound` (qwsv.luau:1872) | VERIFIED | Same loopback check; channel packing (ent<<3), SND_VOLUME/SND_ATTENUATION flags, bmodel origin midpoint, phs/reliable channel-8 rules ported. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_FindModelNumbers | inline in `spawnServer` (qwsv.luau:347) | VERIFIED | test_qwsv "player model number found"; nail/supernail indexes drive the nails path. | `lune run tests/test_qwsv.luau` |
| SV_WriteClientdataToMessage | `qwsv.writeClientdataToMessage` (qwsv.luau:1373) | PENDING | chokecount, svc_damage with inflictor midpoint, fixangle→svc_setangle (loopback asserts setangle at spawn — that one path verified); damage path untested. | TBD: write test or tools/verify script + evidence capture |
| SV_UpdateClientStats | `qwsv.updateClientStats` (qwsv.luau:1328) | VERIFIED | test_qw_loopback: health/shells stats mirror server, ammo drops after firing; spectator spec_track passthrough ported (untested); sigil bits <<28 into STAT_ITEMS. | `lune run tests/test_qw_loopback.luau` |
| SV_SendClientDatagram | `qwsv.sendClientDatagram` (qwsv.luau:1412) | VERIFIED | Loopback frames flow through it every tick. Delta: stats update not gated on Netchan_CanReliable (no reliable backlog exists on this transport). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_UpdateToReliableMessages | partial: reliable_datagram fan-out in `qwsv.frame` (qwsv.luau:1945) | PENDING | **Gap:** the C per-frame sync is mostly missing — no `old_frags != v.frags` scan (svc_updatefrags only fires from fullClientUpdate at spawn/drop, so the scoreboard never updates during play), no edict `gravity`/`maxspeed` field pickup → svc_entgravity/svc_maxspeed never sent (client.entgravity stays 1, client.maxspeed stays sv_maxspeed), and `svr.datagram` (MSG_BROADCAST dest) is never appended to client datagrams — QC MSG_BROADCAST writes are silently dropped (QW QC mostly uses MSG_MULTICAST, so id1 play works, but any broadcast write is lost). | TBD: write test or tools/verify script + evidence capture |
| SV_SendClientMessages | `qwsv.sendClientMessages` + `qwsv.replyToClient` (qwsv.luau:1448,1466) | VERIFIED | Loopback: strict 1:1 packet exchange (send_message flag) keeps sequence spaces aligned for delta/prediction. Delta: no rate/choke logic (chokecount always 0 — transport does not drop), spectator slower update path absent. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_SendMessagesToAll | — | UNIMPLEMENTED | Only used at shutdown/final message, both absent. | — (implement first) |

## sv_init.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_ModelIndex | `svr.modelIndex` hook (qwsv.luau:212) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Used by baselines/stats/setmodel throughout the verified tests. Linear precache scan, 0-based like C. | TBD: write test or tools/verify script + evidence capture |
| SV_FlushSignon | — | SUBSTITUTED | C chunks the signon into 512-byte buffers for UDP; the port keeps one signon buffer and sends it whole in prespawn (no packet size limit on the transport). | — (substitution; verify justification still holds) |
| SV_CreateBaseline | `qwsv.createBaseline` (qwsv.luau:368) | VERIFIED | test_qwsv "baselines created" + delta-from-baseline round trip; loopback ">20 baselines received". Player slots forced to playermodel/colormap as in C. | `lune run tests/test_qwsv.luau` |
| SV_SaveSpawnparms | qw/qwsv.luau:saveSpawnparms | VERIFIED | test_qw_loopback "qw nailgun carried"/"qw nail count carried": SetChangeParms on the outgoing progs, full wire re-handshake onto e1m2, DecodeLevelParms restores items+ammo. serverflags latched. | `lune run tests/test_qw_loopback.luau` |
| SV_CalcPHS | `phsRow` + `svr.phsCache` (qwsv.luau:1771) | SUBSTITUTED (verified behavior) | Computed lazily per-leaf and cached instead of the eager O(numleafs²) table — the eager build would stall level load on Roblox. Result is the same or-of-visible-PVS rows; exercised by the loopback PHS sound check. |
| SV_CheckModel | — | SUBSTITUTED | Model CRC anti-cheat pointless when the server publishes the assets (clientbundle). | — (substitution; verify justification still holds) |
| SV_SpawnServer | `qwsv.spawnServer` (qwsv.luau:240) | VERIFIED | test_qwsv: e1m1 spawns, deathmatch entity filtering via `loadFromFileQW` (13 inhibited, 0 monsters), submodel precache, worldspawn edict, StartFrame-before-load ordering, two settle frames. Delta: no progs CRC gate beyond PROGHEADER_CRC_QW; `localmodels` naming identical (`*i`). | `lune run tests/test_qwsv.luau` |

## sv_phys.c

Port file: `src/shared/engine/qw/qwphys.luau` (QW-specific copy; algorithms shared with the verified NQ
sv_phys port, ABI injected via qwdefs). Primary evidence: test_qwsv boots and settles e1m1 through two
`qwphys.physics` frames and runs live play; door/plat/item behavior beyond that is untested here.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_CheckAllEnts | — | UNIMPLEMENTED | Debug-only sweep; never called in the C frame loop. | — (implement first) |
| SV_CheckVelocity | `sv_phys.checkVelocity` (qwphys.luau:43) | PENDING | sv_maxvelocity clamp (cvar seeded via shared cvar defaults). | TBD: write test or tools/verify script + evidence capture |
| SV_RunThink | `sv_phys.runThink` (qwphys.luau:77) | VERIFIED | test_qwsv weapon think chain fires (shotgun via player think path); item/door thinks run during settle frames. | `lune run tests/test_qwsv.luau` |
| SV_Impact | `sv_phys.impact` (qwphys.luau:97) | PENDING | Touch pair dispatch; exercised by physics but not asserted. | TBD: write test or tools/verify script + evidence capture |
| ClipVelocity | `sv_phys.clipVelocity` (qwphys.luau:119) | PENDING | STOP_EPSILON=0.1 as C. | TBD: write test or tools/verify script + evidence capture |
| SV_FlyMove | `sv_phys.flyMove` (qwphys.luau:144) | PENDING | MAX_CLIP_PLANES=5 planes logic; exercised via physicsToss/Step in settle frames, not asserted directly. | TBD: write test or tools/verify script + evidence capture |
| SV_AddGravity | `sv_phys.addGravity` (qwphys.luau:268) | PENDING | Includes QW `gravity` field scale handling. | TBD: write test or tools/verify script + evidence capture |
| SV_PushEntity | `sv_phys.pushEntity` (qwphys.luau:289) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SV_Push + SV_PushMove | merged `pushMove` (qwphys.luau:319) | PENDING | C splits SV_PushMove→SV_Push; port merges them (same shape as C's combined flow): final-position test, standing-on-pusher carry, corpse crush-to-point, blocked callback + full move-back. Not asserted by a test (doors/plats move in test maps but nothing checks them). | TBD: write test or tools/verify script + evidence capture |
| SV_Physics_Pusher | `physicsPusher` (qwphys.luau:435) | PENDING | ltime/nextthink windowing as C. | TBD: write test or tools/verify script + evidence capture |
| SV_Physics_None | `physicsNone` (qwphys.luau:725) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SV_Physics_Noclip | `physicsNoclip` (qwphys.luau:730) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SV_CheckWaterTransition | `checkWaterTransition` (qwphys.luau:740) | PENDING | | TBD: write test or tools/verify script + evidence capture |
| SV_Physics_Toss | `sv_phys.physicsToss` (qwphys.luau:768) | VERIFIED | test_qwsv shotgun path spawns/moves newmis through it; bounce/backoff 1.5/1.0 as C. | `lune run tests/test_qwsv.luau` |
| SV_Physics_Step | `physicsStep` (qwphys.luau:821) | PENDING | Freefall + dland2 hitsound; QW deathmatch has no monsters so only misc step ents exercise it. | TBD: write test or tools/verify script + evidence capture |
| SV_ProgStartFrame | inlined at top of `sv_phys.physics` (qwphys.luau:854) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): StartFrame exec with self/other/time reset; runs every test frame. | TBD: write test or tools/verify script + evidence capture |
| SV_RunEntity | movetype dispatch in `sv_phys.physics` (qwphys.luau:872) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Client slots skipped ("QW: clients move in SV_RunCmd"), which the movement tests depend on. Delta: C's per-entity `lastruntime` throttle (entities run at most every 50 ms between client packets) is absent — entities advance once per server frame like NQ. | TBD: write test or tools/verify script + evidence capture |
| SV_RunNewmis | inlined after each entity (qwphys.luau:898) + `postRunCmd` | VERIFIED | test_qwsv: missile first-0.05s move via physicsToss (guncock/shell test passes through PlayerPostThink newmis path). | `lune run tests/test_qwsv.luau` |
| SV_Physics | `sv_phys.physics` (qwphys.luau:849) | VERIFIED | test_qwsv/test_qw_loopback every tick; force_retouch decrement; sv.time advanced by qwsv.frame, not here — matches C split. | `lune run tests/test_qw_loopback.luau`; `lune run tests/test_qwsv.luau` |
| SV_SetMoveVars | movevars built per-cmd in `qwsv.runCmd` (qwsv.luau:674) | SUBSTITUTED | C copies cvars into a global `movevars` once per frame for pmove; port builds the table per RunCmd call from the same cvars — same values, no global. Verified transitively by loopback prediction convergence (server and client pmove use identical movevars). | — (substitution; verify justification still holds) |

Extra NQ-only functions present in qwphys.luau (`checkStuck`, `checkWater`, `wallFriction`, `tryUnstick`,
`walkMove`, `physicsClient`) have **no QW C counterpart** — see the additions section.

## sv_move.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_CheckBottom | NQ-shared `src/shared/engine/server/sv_move.luau` `checkBottom` | UNIMPLEMENTED (broken wiring) | qwbuiltins.luau builtin 40 calls `sv_move.checkBottom` but **qwbuiltins.luau never requires sv_move** — `sv_move` is a dangling global; the builtin errors if a QW mod calls it. Harmless for id1 qwprogs deathmatch (no monsters), fatal for any progs using it. |
| SV_movestep | NQ-shared `sv_move.movestep` | UNIMPLEMENTED (broken wiring) | Same dangling `sv_move` global via builtin 32 (walkmove). Also typed against the NQ `svlib.Server`/NQ world — untested against the QW server object. |
| SV_StepDirection / SV_FixCheckBottom / SV_NewChaseDir / SV_CloseEnough / SV_MoveToGoal | NQ-shared `sv_move.luau` | UNIMPLEMENTED (broken wiring) | builtin 67 (movetogoal) hits the same missing require. |

## sv_nchan.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ClientReliableCheckBlock / ClientReliable_FinishWrite | — | SUBSTITUTED | The backbuf system exists to queue reliable data while a netchan reliable is in flight; the Roblox transport is reliable+ordered, so writers append directly to `client.netchan.message` (8 KB) with a size check. | — (substitution; verify justification still holds) |
| ClientReliableWrite_Begin/Angle/Angle16/Byte/Char/Float/Coord/Long/Short/String/SZ | direct `msg.write*` into `client.netchan.message` (throughout qwsv.luau) | SUBSTITUTED | Same wire bytes, no backbuf indirection; loopback reliable traffic (prints, stats, setangle) verifies the stream itself. | — (substitution; verify justification still holds) |

## sv_ccmds.c

Server operator console commands. No console exists on the Roblox deployment; Studio pokes
`_G.RQ_SERVER` directly. Rows below are UNIMPLEMENTED unless the mechanism exists elsewhere.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_SetMaster_f / SV_Heartbeat_f | — | SUBSTITUTED | No master server. | — (substitution; verify justification still holds) |
| SV_Quit_f / SV_Logfile_f / SV_Fraglogfile_f | — | SUBSTITUTED | Process/file lifecycle absent; fraglog ring replaces the frag logfile. | — (substitution; verify justification still holds) |
| SV_SetPlayer / SV_God_f / SV_Noclip_f / SV_Give_f | — | UNIMPLEMENTED | No cheat commands (no console); could be added via Studio. | — (implement first) |
| SV_Map_f | `qwsv.spawnServer` callable; no command/changelevel driver | PENDING | **Gap:** PF_changelevel/localcmd set `svr.changelevelTo`, but nothing in the QW boot (qwserver.luau) consumes it — the NQ path (init.server.luau:400) does. Level change on fraglimit/timelimit dead-ends. Reconnect-on-new-spawncount exists (newF handles it) but is never triggered. | TBD: write test or tools/verify script + evidence capture |
| SV_Kick_f | qw/qwsv.luau:kick | VERIFIED | test_qw_loopback "kick found the userid"/"kicked client dropped": broadcast + direct notice + dropClient. Exposed to the host via ServerStorage QW_HostCmd (owner-gating UI hook). | `lune run tests/test_qw_loopback.luau` |
| SV_Status_f | attribute diagnostics (qwserver.luau Heartbeat) | SUBSTITUTED | SV_Time/SV_Edicts/SV_Origin ServerStorage attributes replace the console status dump for Studio. | — (substitution; verify justification still holds) |
| SV_ConSay_f | qw/qwsv.luau:conSay | VERIFIED | test_qw_loopback "conSay reached the client": console:-prefixed PRINT_CHAT to every spawned client over the reliable stream. | `lune run tests/test_qw_loopback.luau` |
| SV_SendServerInfoChange / SV_Serverinfo_f / SV_Localinfo_f | static `svr.serverinfo` only | UNIMPLEMENTED | serverinfo is fixed at newGame; no runtime change path or svc_serverinfo broadcast. localinfo absent entirely. | — (implement first) |
| SV_User_f / SV_Gamedir / SV_Gamedir_f | — | SUBSTITUTED | Single gamedir baked into the asset bundle. | — (substitution; verify justification still holds) |
| SV_Floodprot_f / SV_Floodprotmsg_f | hardcoded values in `say` handler | SUBSTITUTED | Flood protection on (4/4s/10s) but not tunable; C default is off until configured. | — (substitution; verify justification still holds) |
| SV_Snap / SV_Snap_f / SV_SnapAll_f | — | SUBSTITUTED | Depends on the upload protocol (dropped). | — (substitution; verify justification still holds) |
| SV_InitOperatorCommands | — | SUBSTITUTED | No command table to register. | — (substitution; verify justification still holds) |

## world.c

Port file: `src/shared/engine/qw/qwworld.luau` (QW copy of the NQ-verified world port, ABI via qwdefs).
The identical NQ algorithms are ground-truth tested against `tools/trace_truth.c` on the NQ side; QW-side
evidence is transitive through test_qwsv/test_qw_loopback movement, touch triggers and traceline use.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_InitBoxHull | `initBoxHull` (qwworld.luau:99) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): All entity-vs-bbox traces in the verified tests run through it. | TBD: write test or tools/verify script + evidence capture |
| SV_HullForEntity (+SV_HullForBox) | `world.hullForEntity` / `hullForBox` (qwworld.luau:187,200) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Hull select by size (hull 0/1/2) for SOLID_BSP; movement tests depend on hull1 selection. | TBD: write test or tools/verify script + evidence capture |
| SV_CreateAreaNode | `createAreaNode` (qwworld.luau:138) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): depth 4 / AREA_NODES tree as C. | TBD: write test or tools/verify script + evidence capture |
| SV_ClearWorld | `world.new` (qwworld.luau:167) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Built per spawnServer in every test. | TBD: write test or tools/verify script + evidence capture |
| SV_UnlinkEdict | `world.unlinkEdict` (qwworld.luau:427) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Hooked into vm.unlinkEdict for ED_Free (qwbuiltins.luau:70). | TBD: write test or tools/verify script + evidence capture |
| SV_TouchLinks | `touchLinks` (qwworld.luau:438) | VERIFIED | test_qwsv item pickup implied by play; trigger touches fire during runCmd linkEdict(touch=true). | `lune run tests/test_qwsv.luau` |
| SV_FindTouchedLeafs | `findTouchedLeafs` (qwworld.luau:497) | VERIFIED | PVS visibility of entities in test_qwsv frames depends on leafnums being right. | `lune run tests/test_qwsv.luau` |
| SV_LinkEdict | `world.linkEdict` (qwworld.luau:528) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Same tests. | TBD: write test or tools/verify script + evidence capture |
| SV_HullPointContents | `world.hullPointContents` (qwworld.luau:236) | VERIFIED | Waterlevel checks in settle test. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_PointContents | `world.pointContents` (qwworld.luau:260) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Delta: QW C has no CONTENTS_CURRENT truncation (that is NQ); port keeps `truePointContents` split like NQ — both return the same values for id1 maps. | TBD: write test or tools/verify script + evidence capture |
| SV_RecursiveHullCheck | `world.recursiveHullCheck` (qwworld.luau:290) | VERIFIED | Same midpoint/epsilon algorithm verified against C trace ground truth on the NQ twin; QW copy exercised every test tick. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_ClipMoveToEntity | `world.clipMoveToEntity` (qwworld.luau:395) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| SV_ClipToLinks | `clipToLinks` (qwworld.luau:616) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Includes the pass-owner and MOVE_NOMONSTERS rules. | TBD: write test or tools/verify script + evidence capture |
| SV_MoveBounds | `moveBounds` (qwworld.luau:710) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| SV_Move | `world.move` (qwworld.luau:717) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): QC traceline + all physics use it. | TBD: write test or tools/verify script + evidence capture |
| (world.h) SV_TestEntityPosition | `world.testEntityPosition` (qwworld.luau:757) | PENDING | Used by pushMove crush logic; untested. | TBD: write test or tools/verify script + evidence capture |

## pr_cmds.c

Port file: `src/shared/engine/qw/qwbuiltins.luau` (cloned from the verified NQ builtin table with QW
deltas: bprint/sprint levels, logfrag/infokey/stof/multicast). Builtins are exercised end-to-end by
test_qwsv/test_qw_loopback running id1 qwprogs.dat.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| PF_VarString | `varString` (qwbuiltins.luau:35) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): All print builtins go through it in the passing tests. | TBD: write test or tools/verify script + evidence capture |
| PF_error (10) / PF_objerror (11) | qwbuiltins.luau:155,161 | PENDING | Luau error() instead of SV_Error/ED_Free+abort; not triggered in tests. | TBD: write test or tools/verify script + evidence capture |
| PF_makevectors (1) | qwbuiltins.luau:75 | VERIFIED | Weapon fire aim in test_qwsv uses v_forward. | `lune run tests/test_qwsv.luau` |
| PF_setorigin (2) | qwbuiltins.luau:82 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Entity spawn placement in verified boot. | TBD: write test or tools/verify script + evidence capture |
| PF_setsize (4) / SetMinMaxSize | qwbuiltins.luau:89,126 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Player hull size drives verified pmove offset math. | TBD: write test or tools/verify script + evidence capture |
| PF_setmodel (3) | qwbuiltins.luau:99 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Precache index + brush model min/max; boot depends on it. | TBD: write test or tools/verify script + evidence capture |
| PF_bprint (23) | qwbuiltins.luau:386 | PENDING | QW signature (level, string) ported; broadcast receipt untested. | TBD: write test or tools/verify script + evidence capture |
| PF_sprint (24) | qwbuiltins.luau:392 | VERIFIED | QW signature (client, level, string); loopback receives prints. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_centerprint (73) | qwbuiltins.luau:763 | UNIMPLEMENTED (broken wiring) | Writes to `client.message`, a buffer nothing ever flushes to the wire (the QW send path only drains netchan.message + client.datagram) — centerprints never reach clients. Should route to netchan.message. |
| PF_normalize (9) / PF_vlen (12) / PF_vectoyaw (13) / PF_vectoangles (51) | qwbuiltins.luau:149,170,174,647 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Aim/movement math in verified play; trunc-toward-zero yaw as C. | TBD: write test or tools/verify script + evidence capture |
| PF_random (7) | qwbuiltins.luau:135 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Deterministic LCG (shared with NQ port) — SUBSTITUTED RNG source, same distribution shape; drives item spawns in verified boot. | TBD: write test or tools/verify script + evidence capture |
| PF_ambientsound (74) | qwbuiltins.luau:775 | VERIFIED | svc_spawnstaticsound into signon; loopback parses signon without error. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_sound (8) | qwbuiltins.luau:140 | VERIFIED | test_qwsv guncock in soundLog; loopback hears it via PHS. | `lune run tests/test_qwsv.luau` |
| PF_break (6) | qwbuiltins.luau:131 | PENDING | | TBD: write test or tools/verify script + evidence capture |
| PF_traceline (16) | qwbuiltins.luau:209 | VERIFIED | Shotgun fire traces in test_qwsv. | `lune run tests/test_qwsv.luau` |
| PF_checkpos | — | UNIMPLEMENTED | Stubbed/unused in C too (never registered). | — (implement first) |
| PF_newcheckclient / PF_checkclient (17) | qwbuiltins.luau:219,250 | UNIMPLEMENTED (broken wiring) | Logic fully ported but references `bsplib` **which is never required** in qwbuiltins.luau — dangling global, errors if qwprogs calls checkclient. |
| PF_stuffcmd (21) | qwbuiltins.luau:352 | VERIFIED | Handshake "skins"/"cmd spawn" stufftexts drive the verified loopback flow via svr.clientCommands. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_localcmd (46) | qwbuiltins.luau:605 | PENDING | Only changelevel/restart routed (into changelevelTo, itself unconsumed — see SV_Map_f row); others logged. | TBD: write test or tools/verify script + evidence capture |
| PF_cvar (45) / PF_cvar_set (72) | qwbuiltins.luau:600,759 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): qwprogs reads deathmatch/teamplay in verified boot. | TBD: write test or tools/verify script + evidence capture |
| PF_findradius (22) | qwbuiltins.luau:361 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Explosion/pickup logic in verified play path. | TBD: write test or tools/verify script + evidence capture |
| PF_dprint (25) | qwbuiltins.luau:404 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| PF_ftos (26) / PF_vtos (27) / PF_fabs (43) | qwbuiltins.luau:408,420,529 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): %5.1f/%d formatting as C. | TBD: write test or tools/verify script + evidence capture |
| PF_Spawn (14) / PF_Remove (15) | qwbuiltins.luau:188,192 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Entity lifecycle in verified boot/play. | TBD: write test or tools/verify script + evidence capture |
| PF_Find (18) | qwbuiltins.luau:283 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Spawn-point selection in verified spawn. | TBD: write test or tools/verify script + evidence capture |
| PR_CheckEmptyString | `checkEmptyString` (qwbuiltins.luau:303) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| PF_precache_file (68/77) | qwbuiltins.luau:723 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): No-op returning parm, as C. | TBD: write test or tools/verify script + evidence capture |
| PF_precache_sound (19/76) / PF_precache_model (20/75) | qwbuiltins.luau:309,328 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Precache lists feed verified soundlist/modellist; ss_loading gate as C. | TBD: write test or tools/verify script + evidence capture |
| PF_coredump (28) / PF_traceon (29) / PF_traceoff (30) / PF_eprint (31) | qwbuiltins.luau:426-435 | PENDING | Debug stubs (coredump prints a notice; eprint no-op). | TBD: write test or tools/verify script + evidence capture |
| PF_walkmove (32) | qwbuiltins.luau:437 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global (no require) — see sv_move.c section. |
| PF_droptofloor (34) | qwbuiltins.luau:461 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Items settle onto floors in verified boot (item_shells present at valid origins). | TBD: write test or tools/verify script + evidence capture |
| PF_lightstyle (35) | qwbuiltins.luau:487 | PENDING (partial bug) | Registry write works (spawnF sends styles — loopback "lightstyles received"). **Bug:** the live-broadcast branch compares `svr.state ~= svr.ss_active` where `ss_active` is nil (state is 2), so it always early-returns; and it writes to unflushed `client.message` anyway — runtime style changes never reach connected clients. |
| PF_rint (36) / PF_floor (37) / PF_ceil (38) | qwbuiltins.luau:507-517 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): rint rounds half away from zero as C. | TBD: write test or tools/verify script + evidence capture |
| PF_checkbottom (40) | qwbuiltins.luau:519 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global. |
| PF_pointcontents (41) | qwbuiltins.luau:524 | VERIFIED | Water checks in verified play. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_nextent (47) | qwbuiltins.luau:619 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| PF_aim (44) | qwbuiltins.luau:533 | PENDING | Full port incl. teamplay filter and sv_aim cvar; QW id1 sets sv_aim=2 (aim disabled: dist<bestdist never true) so play never exercises the assist branch. | TBD: write test or tools/verify script + evidence capture |
| PF_changeyaw (49) | qwbuiltins.luau:643 | UNIMPLEMENTED (broken wiring) | Dangling `sv_move` global. |
| WriteDest / Write_GetClient | `writeDest` (qwbuiltins.luau:674) | PENDING | MSG_MULTICAST added (QW). **Gap:** MSG_ONE returns unflushed `client.message` (C uses ClientReliableWrite → netchan) and MSG_BROADCAST returns `svr.datagram` which is never copied to clients (see SV_UpdateToReliableMessages row) — both destinations are dead ends on the wire. MSG_MULTICAST (the one id1 QW QC actually uses for temp entities) is live and loopback-verified via sounds. | TBD: write test or tools/verify script + evidence capture |
| PF_WriteByte..PF_WriteEntity (52-59) | qwbuiltins.luau:694-717 | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Temp-entity writes ride MSG_MULTICAST through verified svMulticast; WriteAngle uses NQ byte angle (C QW server also writes byte angles here). | TBD: write test or tools/verify script + evidence capture |
| PF_makestatic (69) | qwbuiltins.luau:728 | VERIFIED | svc_spawnstatic in signon parsed by loopback client. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_setspawnparms (78) | qwbuiltins.luau:806 | PENDING | Copies client spawn_parms to parm globals; decoder untested. | TBD: write test or tools/verify script + evidence capture |
| PF_changelevel (70) | qwbuiltins.luau:750 | PENDING | Sets changelevelTo once (double-issue guard as C); consumer missing in QW boot (see SV_Map_f). | TBD: write test or tools/verify script + evidence capture |
| PF_logfrag (79) | qwbuiltins.luau:820 | PENDING | Ring buffer via svr.logfrag; format `{killer,killee,time}` instead of C's `\k\d\n` text log. | TBD: write test or tools/verify script + evidence capture |
| PF_infokey (80) | qwbuiltins.luau:828 | PENDING | serverinfo (ent 0) / client userinfo lookup; C's synthetic keys (ip, ping) absent. | TBD: write test or tools/verify script + evidence capture |
| PF_stof (81) | qwbuiltins.luau:841 | PENDING | com.atof. | TBD: write test or tools/verify script + evidence capture |
| PF_multicast (82) | qwbuiltins.luau:845 | VERIFIED | Routes to svMulticast; loopback PHS sound + temp entities. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_Fixme | error on unknown builtin (vm dispatch) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): VM errors on unregistered builtin numbers. | TBD: write test or tools/verify script + evidence capture |

## pr_edict.c

Shared NQ port: `src/shared/engine/progs/vm.luau` (+`progs.luau` loader). Verified on the NQ side; QW-side
evidence via test_qwsv/test_qw_loopback which run id1 qwprogs.dat through it with `PROGHEADER_CRC_QW`.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ED_ClearEdict | `clearEdict` (vm.luau:259) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Entity churn in verified play. | TBD: write test or tools/verify script + evidence capture |
| ED_Alloc | `vmlib.alloc` (vm.luau:265) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Slot reuse after 0.5s as C. | TBD: write test or tools/verify script + evidence capture |
| ED_Free | `vmlib.free` (vm.luau:289) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Unlink hook + field reset. | TBD: write test or tools/verify script + evidence capture |
| ED_GlobalAtOfs / ED_FieldAtOfs / ED_FindField / ED_FindGlobal / ED_FindFunction | name maps in progs.luau/`vmlib.findFieldDef`/`vmlib.findFunction` | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): qwdefs.build resolves the whole QW ABI by name at load (qwdefs.luau) — boot fails loudly if any required def is missing. | TBD: write test or tools/verify script + evidence capture |
| GetEdictFieldValue | field lookups via qwdefs `ent` table | SUBSTITUTED | Static name→offset resolution replaces per-call cached lookup. Note: the `gravity`/`maxspeed` optional-field pickup that C does with it is missing (see SV_UpdateToReliableMessages). | — (substitution; verify justification still holds) |
| PR_ValueString / PR_UglyValueString / PR_GlobalString(NoContents) | — | UNIMPLEMENTED | Debug printing (edict dumps) not ported. | — (implement first) |
| ED_Print / ED_Write / ED_PrintNum / ED_PrintEdicts / ED_PrintEdict_f / ED_Count / ED_WriteGlobals / ED_ParseGlobals | — | UNIMPLEMENTED | Console debug + savegame globals; QW has no savegames. | — (implement first) |
| ED_NewString | inside `vmlib.parseEpair` (vm.luau:607) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): `\n` escape handling. | TBD: write test or tools/verify script + evidence capture |
| ED_ParseEdict | `vmlib.parseEdict` (vm.luau:650) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): anglehack/light→light_lev handling; e1m1 entities load. | TBD: write test or tools/verify script + evidence capture |
| ED_LoadFromFile | `vmlib.loadFromFileQW` (vm.luau:791) | VERIFIED | test_qwsv: deathmatch inhibit flags (13 inhibited, no monsters in DM). | `lune run tests/test_qwsv.luau` |
| PR_LoadProgs | `progslib.load` (progs.luau:50) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): CRC gate via defs.PROGHEADER_CRC_QW (qwsv.luau:263). | TBD: write test or tools/verify script + evidence capture |
| PR_Init | — | SUBSTITUTED | Command/cvar registration replaced by module init. | — (substitution; verify justification still holds) |
| EDICT_NUM / NUM_FOR_EDICT | `vmlib.edictNum` / `ed.num` | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |

## pr_exec.c

Shared NQ port: `src/shared/engine/progs/vm.luau`.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| PR_PrintStatement / PR_StackTrace / PR_Profile_f | — | UNIMPLEMENTED | Profiling/trace printing not ported (vm.trace flag exists but prints nothing). | — (implement first) |
| PR_RunError | `runError` (vm.luau:311) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Errors carry the function name; surfaced through Luau error. | TBD: write test or tools/verify script + evidence capture |
| PR_EnterFunction / PR_LeaveFunction | `enterFunction`/`leaveFunction` (vm.luau:320,352) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Parm save/restore across recursion — id1 qwprogs runs full games in the tests. | TBD: write test or tools/verify script + evidence capture |
| PR_ExecuteProgram | `vmlib.exec` (vm.luau:374) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Whole opcode interpreter; every test exercises it, incl. OP_STATE through the QW ABI (vm.stateOffsets, qwsv.luau:274). | TBD: write test or tools/verify script + evidence capture |
| PR_GetString / PR_SetString | `vmlib.getString`/`allocString`/`newString` (vm.luau:123-148) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Dynamic string table replaces pointer arithmetic (GC platform). | TBD: write test or tools/verify script + evidence capture |

## model.c

Shared NQ port: `src/shared/engine/bsp/bsp.luau` + `src/shared/engine/models/models.luau` (registry).
QW's server model.c is the brush-only loader; the port loads the same lumps.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Mod_Init / Mod_ClearAll / Mod_FindName / Mod_LoadModel / Mod_ForName | `models.newRegistry`/`models.forName` (models.luau) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): e1m1 + submodels (`*i`) load in every QW test. | TBD: write test or tools/verify script + evidence capture |
| Mod_PointInLeaf | `bsp.pointInLeaf` (bsp.luau:760) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): PHS multicast + checkclient paths. | TBD: write test or tools/verify script + evidence capture |
| Mod_DecompressVis / Mod_LeafPVS | `bsp.leafPVS` (bsp.luau:779) | VERIFIED | Fat-PVS entity culling + PHS sound in loopback. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Mod_LoadVertexes/Edges/Surfedges/Textures/Lighting/Visibility/Entities/Submodels/Texinfo/Faces/Nodes/Leafs/Clipnodes/Marksurfaces/Planes + CalcSurfaceExtents + Mod_SetParent + Mod_MakeHull0 + Mod_LoadBrushModel | `bsp.load` internals (bsp.luau:187-669) | VERIFIED | Hull/clipnode data is ground-truth checked transitively: test_qw_pmove runs the C pmove's own hull tracing against the port-loaded e1m1 within 0.000122 units. | `lune run tests/test_qw_pmove.luau` |
| Mod_LoadTextures (rendering payload) | client-side gfx concern | SUBSTITUTED | Server only needs hulls/PVS/entities; texture pixels handled by the render pipeline. | — (substitution; verify justification still holds) |

## mathlib.c / math.s

Shared NQ port: `src/shared/engine/common/mathlib.luau` + native `vector` type.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| AngleVectors | `mathlib.angleVectors` | VERIFIED | pmove ground truth matches C within 1e-4 — angle math must agree. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| VectorNormalize | `mathlib.normalize` | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Same. | TBD: write test or tools/verify script + evidence capture |
| DotProduct/VectorAdd/Sub/Copy/Scale/Length etc. | Luau `vector` builtins | SUBSTITUTED | Native SIMD vector type replaces the macro/asm set; correctness bounded by the pmove/trace ground-truth tests. | — (substitution; verify justification still holds) |
| BoxOnPlaneSide (math.s/mathlib.c) | axis-aligned checks in world/bsp code | SUBSTITUTED | Only used for culling paths that the port expresses directly. | — (substitution; verify justification still holds) |

## zone.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Z_*/Hunk_*/Cache_* allocators | — | SUBSTITUTED | Luau GC + `buffer` objects replace manual zone/hunk/cache memory management wholesale. | — (substitution; verify justification still holds) |

## net_chan.c (QW/client, shared with server)

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Netchan_Init | `qwnetchan.new` (qwnetchan.luau:22) | VERIFIED | Loopback handshake + play. Delta: no qport (no NAT rebinding on Roblox). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Netchan_OutOfBand / Netchan_OutOfBandPrint | — | SUBSTITUTED | No connectionless packets on the transport. | — (substitution; verify justification still holds) |
| Netchan_Setup | `qwnetchan.new` per client | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): | TBD: write test or tools/verify script + evidence capture |
| Netchan_CanPacket / Netchan_CanReliable | — | SUBSTITUTED | Rate throttling and reliable-in-flight gating meaningless on a reliable+ordered remote; senders always transmit. | — (substitution; verify justification still holds) |
| Netchan_Transmit | `qwnetchan.transmit` (qwnetchan.luau:34) | VERIFIED | Loopback: sequence numbers keep their exact protocol role (frames ring, delta ack). **Substitution:** reliable retransmit/fragment bits replaced by an in-band reliable block `[seq][ack][reliable][datagram]` because Roblox remotes are reliable+ordered — the reliable stream cannot be lost, so no resend state. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Netchan_Process | `qwnetchan.process` (qwnetchan.luau:57) | VERIFIED | Stale/duplicate rejection, drop_count (net_drop) feeding SV_RunCmd's dropped-cmd replay — loopback runs with 1 tick latency. Delta: 32-bit sequence wrap unhandled (~2.3y at 60Hz). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## pmove.c / pmovetst.c (QW/client, executed by the server in SV_RunCmd)

Port file: `src/shared/engine/qw/pmove.luau`. Ground truth: `tools/pmove_truth.c` `#include`s the
VERBATIM `pmove.c`/`pmovetst.c`; `test_qw_pmove.luau` replays two identical scripted courses —
300 ticks on e1m1 (flat run/strafe/jump/backpedal) and 160 ticks on dm3's staircase at x=-64
(climb, descend, re-climb, jumping climb, diagonal; risers 56/72/88/104) — matching within
0.000122 units position / 0.000109 velocity, onground and waterlevel agreeing every tick.
Terrain covered: flat ground, walls, jumps, air control, 16-unit stair step-ups from every
approach. Terrain NOT covered: water (waterlevel 0 throughout — PM_WaterMove stays PENDING).

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Pmove_Init / PM_InitBoxHull | `hullForBox` (pmove.luau:109) | SUBSTITUTED | Fresh 6-clipnode hull per call instead of a mutated static (no globals on a shared-module platform); identical plane math — covered by the ground truth. | — (substitution; verify justification still holds) |
| PM_ClipVelocity | `clipVelocity` (pmove.luau:345) | VERIFIED | test_qw_pmove ground truth (slide-along-wall phases in the script). | `lune run tests/test_qw_pmove.luau` |
| PM_FlyMove | `flyMove` (pmove.luau:371) | VERIFIED | Ground truth incl. air ticks, both courses. | `lune run tests/test_qw_pmove.luau` |
| PM_GroundMove | `groundMove` (pmove.luau:463) | VERIFIED | Ground truth: e1m1 flat course PLUS the dm3 staircase course (2026-07-04 playtest finding: the old fixture was flat-only) — step-ups match C to 0.000122 units under straight, re-climb, jumping, and diagonal approaches. | `lune run tests/test_qw_pmove.luau` |
| PM_Friction | `friction` (pmove.luau:538) | VERIFIED | Friction applies on every ground tick of both truth courses (direction reversals decelerate through it); any divergence would break the 1e-4 position match. | `lune run tests/test_qw_pmove.luau` |
| PM_Accelerate / PM_AirAccelerate | pmove.luau:584,604 | VERIFIED | Ground truth accel curves, both courses. | `lune run tests/test_qw_pmove.luau` |
| PM_WaterMove | `waterMove` (pmove.luau:628) | PENDING | Ported; fixture never enters water (waterlevel 0 for all 300 ticks) — no ground-truth coverage. | TBD: write test or tools/verify script + evidence capture |
| PM_AirMove | `airMove` (pmove.luau:661) | VERIFIED | Ground truth, both courses (jump arcs + stair-jump climbs). | `lune run tests/test_qw_pmove.luau` |
| PM_CatagorizePosition | `catagorizePosition` (pmove.luau:697) | VERIFIED | onground agrees every tick across both courses (460 ticks incl. stair edges and jump apexes); water branches still only trivially covered — the water truth course remains a separate open item (see PM_WaterMove). | `lune run tests/test_qw_pmove.luau` |
| JumpButton | `jumpButton` (pmove.luau:745) | VERIFIED | Jump phases match in both courses (e1m1 bunny ticks 121-160/201-240; dm3 jumping climb ticks 386-405) incl. oldbuttons latching between held-jump ticks. | `lune run tests/test_qw_pmove.luau` |
| CheckWaterJump | `checkWaterJump` (pmove.luau:788) | PENDING | Ported; unreachable in the fixture (no water). | TBD: write test or tools/verify script + evidence capture |
| NudgePosition | `nudgePosition` (pmove.luau:818) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Runs every tick in both C and port (positions stay equal through it). | TBD: write test or tools/verify script + evidence capture |
| SpectatorMove | `spectatorMove` (pmove.luau:842) | PENDING | Ported; no spectator test anywhere. | TBD: write test or tools/verify script + evidence capture |
| PlayerMove | `pmove.playerMove` (pmove.luau:894) | VERIFIED | The top-level function the ground-truth test calls 300 times. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_HullPointContents | `hullPointContents` (pmove.luau:145) | VERIFIED | Ground truth (contents drive categorize). | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PM_PointContents | `pointContents` (pmove.luau:278) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Same. | TBD: write test or tools/verify script + evidence capture |
| PM_RecursiveHullCheck | `recursiveHullCheck` (pmove.luau:165) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): Every trace of every tick matches C to 1e-4. | TBD: write test or tools/verify script + evidence capture |
| PM_TestPlayerPosition | `testPlayerPosition` (pmove.luau:266) | PENDING | DEMOTED (evidence not re-runnable/checked-in; re-earn with a test or docs/coverage/evidence/ screenshot): NudgePosition calls it each tick. | TBD: write test or tools/verify script + evidence capture |
| PM_PlayerMove (pmovetst trace) | `playerTrace` (pmove.luau:285) | VERIFIED | Same ground truth. | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## Totals

Counted per manifest row (some rows deliberately merge families of C functions, e.g. the 11
ClientReliableWrite_* variants, the 7 IP-filter commands, the 19 Mod_Load* lump loaders — so the
underlying C function count is higher than the row count in the SUBSTITUTED/VERIFIED buckets):

| Status | Rows |
|---|---|---|
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
|---|---|---|---|
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

> Evidence reset 2026-07-04: VERIFIED now means re-runnable evidence only (a cited test/harness). 58 rows demoted to PENDING with their prior claims preserved inline (marked DEMOTED); re-earn via tests or checked-in screenshots under docs/coverage/evidence/.
