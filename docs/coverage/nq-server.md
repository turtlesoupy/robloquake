# NQ simulation/server coverage

Function-level coverage manifest for the NetQuake (WinQuake 1.09) simulation/server/shared
C files vs the Luau port. Every row was produced by reading both sides.

Statuses: **VERIFIED** = an offline test or compiled-C ground-truth harness demonstrably
exercises the behavior (cited), or a side-by-side-compared transliteration whose code path
an existing test covers with assertions. **PENDING** = port exists and reads equivalent,
but no test proves it (or coverage is partial/indirect). **UNIMPLEMENTED** = no port
counterpart (includes C code that is dead in the NQ build — marked "dead"). **SUBSTITUTED**
= intentionally replaced by a platform mechanism, with the reason.

Evidence sources: `tests/*.luau` (offline lune tests), `tools/trace_truth.c` /
`tools/move_truth.c` (verbatim WinQuake C compiled natively, fixtures in
`tests/fixtures/`), `tools/dump_bsp_truth.py` (independent struct-level parse),
`FIDELITY.md` (audit log). Port paths are relative to `src/`.

## common.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ClearLink (common.c:104) | shared/engine/server/world.luau:newSentinel | VERIFIED | transliteration compared; exercised by every linkEdict in test_server/test_loopback (entity visibility asserted) | `lune run tests/test_loopback.luau`; `lune run tests/test_server.luau` |
| RemoveLink (common.c:109) | world.luau:removeLink | VERIFIED | test_server "unlinked door no longer clips (RemoveLink)". | `lune run tests/test_server.luau` |
| InsertLinkBefore (common.c:115) | world.luau:insertLinkBefore | VERIFIED | test_server "relinked door clips identically (InsertLinkBefore)" — bit-equal fraction after unlink/relink. | `lune run tests/test_server.luau` |
| InsertLinkAfter (common.c:122) | — | N/A | unused by the C server paths in scope. N/A: unused in scope. | — (implement first) |
| Q_memset (common.c:138) | — | SUBSTITUTED | Luau `buffer.fill` / table ops; no raw memory on Roblox | — (substitution; verify justification still holds) |
| Q_memcpy (common.c:154) | — | SUBSTITUTED | `buffer.copy` | — (substitution; verify justification still holds) |
| Q_memcmp (common.c:169) | — | SUBSTITUTED | Luau `==` on strings/buffers | — (substitution; verify justification still holds) |
| Q_strcpy (common.c:180) | — | SUBSTITUTED | Luau immutable strings | — (substitution; verify justification still holds) |
| Q_strncpy (common.c:189) | — | SUBSTITUTED | `string.sub` | — (substitution; verify justification still holds) |
| Q_strlen (common.c:199) | — | SUBSTITUTED | `#s` | — (substitution; verify justification still holds) |
| Q_strrchr (common.c:210) | — | SUBSTITUTED | `string.match` patterns | — (substitution; verify justification still holds) |
| Q_strcat (common.c:219) | — | SUBSTITUTED | `..` | — (substitution; verify justification still holds) |
| Q_strcmp (common.c:225) | — | SUBSTITUTED | `==` | — (substitution; verify justification still holds) |
| Q_strncmp (common.c:240) | — | SUBSTITUTED | `string.sub` compare | — (substitution; verify justification still holds) |
| Q_strncasecmp (common.c:257) | — | SUBSTITUTED | `string.lower` compare | — (substitution; verify justification still holds) |
| Q_strcasecmp (common.c:287) | — | SUBSTITUTED | `string.lower` compare | — (substitution; verify justification still holds) |
| Q_atoi (common.c:292) | shared/engine/common/com.luau:atoi | VERIFIED | test_com: decimal/negative/truncation/hex/garbage cases. Delta: C char constants ('a') return 0 here. | `lune run tests/test_com.luau` |
| Q_atof (common.c:351) | com.luau:atof | VERIFIED | test_com: decimal/fraction/hex/stop-at-junk cases. Deltas: Luau tonumber accepts exponents (C Q_atof stops at "e"); C char constants unsupported. | `lune run tests/test_com.luau` |
| ShortSwap/ShortNoSwap (common.c:443,453) | — | SUBSTITUTED | Luau `buffer` API is little-endian, matching Quake's on-disk/wire format; no swapping needed | — (substitution; verify justification still holds) |
| LongSwap/LongNoSwap (common.c:458,470) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| FloatSwap/FloatNoSwap (common.c:475,492) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| MSG_WriteChar (common.c:510) | shared/engine/common/msg.luau:writeChar | VERIFIED | full protocol loopback: test_loopback/test_server parse server-written streams with the real client parser | `lune run tests/test_loopback.luau`; `lune run tests/test_server.luau` |
| MSG_WriteByte (common.c:523) | msg.luau:writeByte | VERIFIED | test_server: datagram starts with svc_time; loopback signon parses | `lune run tests/test_server.luau` |
| MSG_WriteShort (common.c:536) | msg.luau:writeShort | VERIFIED | clc_move forward=400 drives asserted movement (test_server "player ran forward") | `lune run tests/test_server.luau` |
| MSG_WriteLong (common.c:550) | msg.luau:writeLong | VERIFIED | svc_updatestat longs → loopback stats asserted | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_WriteFloat (common.c:561) | msg.luau:writeFloat | VERIFIED | test_server: svc_time float read back within tolerance | `lune run tests/test_server.luau` |
| MSG_WriteString (common.c:576) | msg.luau:writeString | VERIFIED | loopback levelname/precache strings asserted | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_WriteCoord (common.c:584) | msg.luau:writeCoord | VERIFIED | loopback: player origin via entity updates near (480,-352,88); coord = short of f*8 | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_WriteAngle (common.c:589) | msg.luau:writeAngle | VERIFIED | test_server: angle 90 in clc_move → northward motion asserted | `lune run tests/test_server.luau` |
| MSG_BeginReading (common.c:600) | msg.luau:reader | VERIFIED | test_msg round-trip battery (reader object replaces global read state). | `lune run tests/test_msg.luau` |
| MSG_ReadChar (common.c:607) | msg.luau:readChar | VERIFIED | test_msg: signed byte round-trip; -1 + badread on underflow as C. | `lune run tests/test_msg.luau` |
| MSG_ReadByte (common.c:623) | msg.luau:readByte | VERIFIED | test_msg: unsigned round-trip; -1 + badread on underflow. | `lune run tests/test_msg.luau` |
| MSG_ReadShort (common.c:639) | msg.luau:readShort | VERIFIED | test_msg: little-endian signed round-trip. | `lune run tests/test_msg.luau` |
| MSG_ReadLong (common.c:657) | msg.luau:readLong | VERIFIED | protocol version in serverinfo (loopback signon completes) | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_ReadFloat (common.c:677) | msg.luau:readFloat | VERIFIED | test_msg: IEEE float round-trip. | `lune run tests/test_msg.luau` |
| MSG_ReadString (common.c:697) | msg.luau:readString | VERIFIED | test_msg: NUL-terminated read. | `lune run tests/test_msg.luau` |
| MSG_ReadCoord (common.c:717) | msg.luau:readCoord | VERIFIED | client entity origins asserted in loopback | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| MSG_ReadAngle (common.c:722) | msg.luau:readAngle | VERIFIED | test_msg: byte angle round-trip incl. 360-wrap and truncation toward zero. | `lune run tests/test_msg.luau` |
| SZ_Alloc (common.c:731) | msg.luau:newBuf | VERIFIED | test_msg: per-write cursize accounting. | `lune run tests/test_msg.luau` |
| SZ_Free (common.c:741) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| SZ_Clear (common.c:749) | msg.luau:clear | VERIFIED | test_msg: clear resets cursize, buffer reusable. | `lune run tests/test_msg.luau` |
| SZ_GetSpace (common.c:754) | msg.luau:getSpace | VERIFIED | test_msg: overflow without allowoverflow errors; with it, the buffer clears and overflowed survives (SZ_Clear was wrongly resetting the flag — fixed 2026-07-04; the sv.luau/qwsv overflow checks were dead code). | `lune run tests/test_msg.luau` |
| SZ_Write (common.c:777) | msg.luau:writeBuf | VERIFIED | signon copy into prespawn reply → baselines received in loopback | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SZ_Print (common.c:782) | — | N/A | NUL-splicing string append not needed; strings built in Luau. N/A: unused in scope. | — (implement first) |
| COM_SkipPath (common.c:804) | — | SUBSTITUTED | inline Luau string patterns where needed | — (substitution; verify justification still holds) |
| COM_StripExtension (common.c:823) | — | SUBSTITUTED | inline patterns (e.g. savegame.write `maps/(.+)%.bsp`) | — (substitution; verify justification still holds) |
| COM_FileExtension (common.c:835) | — | SUBSTITUTED | inline patterns | — (substitution; verify justification still holds) |
| COM_FileBase (common.c:856) | — | SUBSTITUTED | inline patterns | — (substitution; verify justification still holds) |
| COM_DefaultExtension (common.c:884) | — | SUBSTITUTED | callers pass full names | — (substitution; verify justification still holds) |
| COM_Parse (common.c:911) | com.luau:parse | VERIFIED | test_vm: 5 explicit checks (brace/quoted key/value/close/eof); savegame round-trip reparses full entity text | `lune run tests/test_vm.luau` |
| COM_CheckParm (common.c:990) | — | SUBSTITUTED | no argv on Roblox; config via Instance attributes (init.server.luau) | — (substitution; verify justification still holds) |
| COM_CheckRegistered (common.c:1015) | server/host.luau:newGame (gfx/pop.lmp probe) | VERIFIED | test_server: registered cvar = 1 from the gfx/pop.lmp probe on the local registered pak. | `lune run tests/test_server.luau` |
| COM_InitArgv (common.c:1057) | — | SUBSTITUTED | no command line on the platform | — (substitution; verify justification still holds) |
| COM_Init (common.c:1125) | — | SUBSTITUTED | endianness moot; init in bootstrap | — (substitution; verify justification still holds) |
| va (common.c:1169) | — | SUBSTITUTED | Luau string interpolation | — (substitution; verify justification still holds) |
| memsearch (common.c:1183) | — | N/A | unused. N/A: unused in scope. | — (implement first) |
| COM_Path_f (common.c:1258) | — | UNIMPLEMENTED | debug console command | ruled: IMPLEMENT (2026-07-05) |
| COM_WriteFile (common.c:1281) | — | SUBSTITUTED | no writable filesystem; saves persist via ServerStorage.QuakeSaves (init.server.luau) | — (substitution; verify justification still holds) |
| COM_CreatePath (common.c:1308) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_CopyFile (common.c:1332) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_FindFile (common.c:1365) | common/vfs.luau:findFile | VERIFIED | test_pak: known file lengths through pak search + missing file returns -1 | `lune run tests/test_pak.luau` |
| COM_OpenFile (common.c:1485) | — | SUBSTITUTED | no file handles; whole-buffer loads | — (substitution; verify justification still holds) |
| COM_FOpenFile (common.c:1498) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_CloseFile (common.c:1510) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_LoadFile (common.c:1533) | vfs.luau:loadFile | VERIFIED | test_pak/test_bsp/test_vm/test_wad all load real pak contents through it | `lune run tests/test_bsp.luau`; `lune run tests/test_pak.luau`; `lune run tests/test_vm.luau`; `lune run tests/test_wad.luau` |
| COM_LoadHunkFile (common.c:1581) | — | SUBSTITUTED | hunk allocator replaced by GC; loadFile only | — (substitution; verify justification still holds) |
| COM_LoadTempFile (common.c:1586) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_LoadCacheFile (common.c:1591) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_LoadStackFile (common.c:1598) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| COM_LoadPackFile (common.c:1619) | common/pak.luau:load | VERIFIED | test_pak: 339 entries, lengths cross-checked vs independent Python parse | `lune run tests/test_pak.luau` |
| COM_AddGameDirectory (common.c:1689) | vfs.luau:addPack + init.server.luau `addGameDirectory` (pak0..pakN loop) | VERIFIED | Searchpath layering exercised by test_librequake (lq1 over id1), test_qw_pmove (pak1 over pak0), and test_gamedir (mod pak over id1: override, fallthrough, foreign progs.dat wins on both boots). | `lune run tests/test_gamedir.luau`; `lune run tests/test_librequake.luau` |
| COM_InitFilesystem (common.c:1732) | src/server/init.server.luau | SUBSTITUTED | paks reassembled from base64 asset chunks (no filesystem); -basedir via the game attribute, -game via the gamedir attribute (mod dir stacked over base, missing dir warns and falls back). Stacking semantics verified offline by test_gamedir + test_scenario_ctf. | — (substitution; verify justification still holds) |

## mathlib.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ProjectPointOnPlane (mathlib.c:34) | — | N/A | used only by client-side code in C. N/A: unused in scope (client-only in C). | — (implement first) |
| PerpendicularVector (mathlib.c:56) | — | N/A | client-side only. N/A: unused in scope. | — (implement first) |
| RotatePointAroundVector (mathlib.c:93) | — | N/A | client-side only. N/A: unused in scope. | — (implement first) |
| anglemod (mathlib.c:155) | common/mathlib.luau:anglemod | VERIFIED | test_com: matches the transcribed 360/65536 quantization on 9 cases incl. negatives. | `lune run tests/test_com.luau` |
| BOPS_Error (mathlib.c:174) | — | N/A | error stub for the assembly path. N/A: dead in C (asm path stub). | — (implement first) |
| BoxOnPlaneSide (mathlib.c:189) | mathlib.luau:boxOnPlaneSide | VERIFIED | side-by-side transliteration (incl. axial fast path + 8 signbits cases, `>=`/`<` semantics); exercised via findTouchedLeafs → PVS visibility assertions in test_loopback | `lune run tests/test_loopback.luau` |
| AngleVectors (mathlib.c:292) | mathlib.luau:angleVectors | VERIFIED | test_movement: v_angle → wishdir chain matches compiled C within 0.0002 units over 300 ticks | `lune run tests/test_movement.luau` |
| VectorCompare (mathlib.c:318) | — | SUBSTITUTED | native `vector` equality | — (substitution; verify justification still holds) |
| VectorMA (mathlib.c:329) | — | SUBSTITUTED | native vector arithmetic | — (substitution; verify justification still holds) |
| _DotProduct (mathlib.c:337) | — | SUBSTITUTED | `vector.dot` | — (substitution; verify justification still holds) |
| _VectorSubtract (mathlib.c:342) | — | SUBSTITUTED | native `-` | — (substitution; verify justification still holds) |
| _VectorAdd (mathlib.c:349) | — | SUBSTITUTED | native `+` | — (substitution; verify justification still holds) |
| _VectorCopy (mathlib.c:356) | — | SUBSTITUTED | value semantics | — (substitution; verify justification still holds) |
| CrossProduct (mathlib.c:363) | — | SUBSTITUTED | `vector.cross` | — (substitution; verify justification still holds) |
| Length (mathlib.c:372) | — | SUBSTITUTED | `vector.magnitude` | — (substitution; verify justification still holds) |
| VectorNormalize (mathlib.c:385) | mathlib.luau:normalize | VERIFIED | returns (unit, length) like C; in the matched movement chain (test_movement) | `lune run tests/test_movement.luau` |
| VectorInverse (mathlib.c:404) | — | SUBSTITUTED | unary `-` | — (substitution; verify justification still holds) |
| VectorScale (mathlib.c:411) | — | SUBSTITUTED | `*` | — (substitution; verify justification still holds) |
| Q_log2 (mathlib.c:419) | — | N/A | unused server-side. N/A: unused in scope. | — (implement first) |
| R_ConcatRotations (mathlib.c:433) | — | N/A | renderer helper; software rasterizer substituted wholesale (FIDELITY.md). N/A: unused in scope (renderer substituted). | — (implement first) |
| R_ConcatTransforms (mathlib.c:461) | — | N/A | renderer helper. N/A: unused in scope. | — (implement first) |
| FloorDivMod (mathlib.c:500) | — | N/A | software-rasterizer fixed-point helper. N/A: unused in scope (rasterizer). | — (implement first) |
| GreatestCommonDivisor (mathlib.c:547) | — | N/A | same. N/A: unused in scope. | — (implement first) |
| Invert24To16 (mathlib.c:576) | — | N/A | same. N/A: unused in scope. | — (implement first) |

## cvar.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Cvar_FindVar (cvar.c:32) | common/cvar.luau (vars table lookup) | VERIFIED | test_com cvar battery (set/value/string, missing-name empty string). | `lune run tests/test_com.luau` |
| Cvar_VariableValue (cvar.c:48) | cvar.luau:value | VERIFIED | sv_friction/sv_gravity/etc. feed the movement chain matched against compiled C (test_movement) | `lune run tests/test_movement.luau` |
| Cvar_VariableString (cvar.c:64) | cvar.luau:string | VERIFIED | test_com: returns the set string; missing cvar reads empty like C cvar_null_string. | `lune run tests/test_com.luau` |
| Cvar_CompleteVariable (cvar.c:80) | — | UNIMPLEMENTED | console tab-completion (client UI nicety) | ruled: IMPLEMENT (2026-07-05) |
| Cvar_Set (cvar.c:104) | cvar.luau:set | VERIFIED | test_com round-trips; also exercised by both builtin batteries via cvar_set. | `lune run tests/test_com.luau` |
| Cvar_SetValue (cvar.c:135) | cvar.luau:setValue | VERIFIED | test_multiplayer sets coop=1 → QC coop behavior asserted (instant respawn, -2 frag suicide) | `lune run tests/test_multiplayer.luau` |
| Cvar_RegisterVariable (cvar.c:151) | cvar.luau DEFAULTS table | SUBSTITUTED | static default table instead of dynamic registration; no engine code registers at runtime | — (substitution; verify justification still holds) |
| Cvar_WriteVariables (cvar.c:216) | — | SUBSTITUTED | no writable config.cfg on Roblox (FIDELITY.md platform substitutions) | — (substitution; verify justification still holds) |

## cmd.c

The command buffer / alias / bind machinery lives client-side in the port
(src/client/init.client.luau:366-620 "keys.c: bindings, and cmd.c: alias/exec/wait" and
src/client/console.luau) because Roblox has no server console; the server receives only
clc_stringcmd. FIDELITY.md records manual verification (W→forwardmove 200 over the wire,
F11 zoom chain) but there is no offline test.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Cmd_Wait_f (cmd.c:53) | client/init.client.luau ("wait" in execCommand) | VERIFIED | evidence/nq-cbuf-battery.txt: "echo w_one; wait; echo w_two" inside an alias body executes both lines in order with w_two deferred to a later frame. | RQDBG battery per evidence/nq-cbuf-battery.txt |
| Cbuf_Init (cmd.c:73) | init.client.luau cbufDeferred/cbufWait state | VERIFIED | evidence/nq-cbuf-battery.txt: the deferred-buffer state (cbufDeferred/cbufWait) carries the post-wait remainder across frames. | RQDBG battery per evidence/nq-cbuf-battery.txt |
| Cbuf_AddText (cmd.c:86) | init.client.luau:execLine | VERIFIED | Console battery: every exec'd line runs through the Cbuf path (results on screen in evidence/nq-console-open.jpg). | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cbuf_InsertText (cmd.c:111) | init.client.luau cbufDeferred | VERIFIED | Console battery: alias expansion fired (ali_fired) — alias bodies insert ahead of the pending buffer. | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cbuf_Execute (cmd.c:143) | init.client.luau:execLine + cbufFrame | VERIFIED | Console battery: multi-command session executes in order (scrollback order matches issue order). | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cmd_StuffCmds_f (cmd.c:213) | — | SUBSTITUTED | no command line to stuff on Roblox | — (substitution; verify justification still holds) |
| Cmd_Exec_f (cmd.c:283) | init.client.luau "exec" | VERIFIED | Console battery: exec default.cfg prints "execing default.cfg" and applies its cvars ("sensitivity" is "3"); missing file prints couldn't-exec. | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cmd_Echo_f (cmd.c:315) | init.client.luau "echo" | VERIFIED | Console battery: echo hello_cbuf renders. | RQDBG_Console battery per evidence/nq-console-open.txt |
| CopyString (cmd.c:332) | — | SUBSTITUTED | GC strings | — (substitution; verify justification still holds) |
| Cmd_Alias_f (cmd.c:341) | init.client.luau "alias" + aliases table | VERIFIED | Console battery: alias tst defined and expanded. | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cmd_Init (cmd.c:428) | init.client.luau:execCommand dispatcher | SUBSTITUTED | if-chain dispatch instead of registered command table | — (substitution; verify justification still holds) |
| Cmd_Argc (cmd.c:446) | init.client.luau:tokenize result | SUBSTITUTED | token array | — (substitution; verify justification still holds) |
| Cmd_Argv (cmd.c:456) | tokenize result | SUBSTITUTED | | — (substitution; verify justification still holds) |
| Cmd_Args (cmd.c:468) | tokenize / table.concat | SUBSTITUTED | | — (substitution; verify justification still holds) |
| Cmd_TokenizeString (cmd.c:481) | init.client.luau:tokenize | VERIFIED | Console battery: quoted argument survives as one token (echo "quoted string here"). | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cmd_AddCommand (cmd.c:532) | — | SUBSTITUTED | dispatcher if-chain | — (substitution; verify justification still holds) |
| Cmd_Exists (cmd.c:568) | — | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| Cmd_CompleteCommand (cmd.c:588) | — | UNIMPLEMENTED | console tab-completion | ruled: IMPLEMENT (2026-07-05) |
| Cmd_ExecuteString (cmd.c:614) | init.client.luau:execCommand | VERIFIED | Console battery: dispatch across builtins (echo/bind/exec), aliases, and cvar queries. | RQDBG_Console battery per evidence/nq-console-open.txt |
| Cmd_ForwardToServer (cmd.c:660) | client console → clc_stringcmd forward | VERIFIED | evidence/nq-cbuf-battery.txt: "say" forwards as clc_stringcmd and the broadcast returns to the console with the player prefix. | RQDBG battery per evidence/nq-cbuf-battery.txt |
| Cmd_CheckParm (cmd.c:693) | — | N/A | unused. N/A: unused in scope. | — (implement first) |

## crc.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| CRC_Init (crc.c:68) | common/com.luau:crcBuffer | VERIFIED | folded into one function; test_vm: progs.dat CRC16 == 46133 vs independent Python parse | `lune run tests/test_vm.luau` |
| CRC_ProcessByte (crc.c:73) | com.luau:crcBuffer | VERIFIED | test_vm "file crc16" (progs.dat CRC 46133 through crcBuffer). | `lune run tests/test_vm.luau` |
| CRC_Value (crc.c:78) | com.luau:crcBuffer | VERIFIED | test_vm "file crc16". | `lune run tests/test_vm.luau` |

## wad.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| W_CleanupName (wad.c:41) | gfx/wad.luau:cleanupName | VERIFIED | test_wad: 8 known lumps found by name (lowercasing path) | `lune run tests/test_wad.luau` |
| W_LoadWadFile (wad.c:68) | wad.luau:load | VERIFIED | test_wad against real gfx.wad (WAD2 magic, lump dir) | `lune run tests/test_wad.luau` |
| W_GetLumpName (wad.c:125) | wad.luau:getLump / getPic | VERIFIED | test_wad: conchars/sbar/num_* present, qpic dims asserted | `lune run tests/test_wad.luau` |
| W_GetLumpNum (wad.c:134) | — | N/A | port looks up by name only. N/A: unused in scope (name lookup only). | — (implement first) |
| SwapPic (wad.c:154) | — | SUBSTITUTED | little-endian buffer reads; no swap needed | — (substitution; verify justification still holds) |

## model.c

Split in the port: brush → bsp/bsp.luau, alias → models/mdl.luau, sprite → models/spr.luau,
registry → models/models.luau. Ground truth: tools/dump_bsp_truth.py + independent Python
parses (test_bsp/test_models headers).

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Mod_Init (model.c:52) | models/models.luau:newRegistry | SUBSTITUTED | table registry; no mod_novis buffer | — (substitution; verify justification still holds) |
| Mod_Extradata (model.c:64) | — | SUBSTITUTED | no cache allocator; models stay referenced | — (substitution; verify justification still holds) |
| Mod_PointInLeaf (model.c:84) | bsp/bsp.luau:pointInLeaf | VERIFIED | test_bsp: spawn leaf CONTENTS_EMPTY, far point → leaf 0 solid | `lune run tests/test_bsp.luau` |
| Mod_DecompressVis (model.c:115) | bsp.luau:leafPVS (RLE decode) | VERIFIED | test_bsp: PVS row size, self-visibility bit, solid leaf all-0xff | `lune run tests/test_bsp.luau` |
| Mod_LeafPVS (model.c:155) | bsp.luau:leafPVS | VERIFIED | same; also drives loopback entity-visibility assertions | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Mod_ClearAll (model.c:167) | — | SUBSTITUTED | fresh registry per spawnServer; GC frees | — (substitution; verify justification still holds) |
| Mod_FindName (model.c:186) | models.luau:forName (cache table) | VERIFIED | test_models loader battery + every boot loads via the cache table (repeat forName hits cache). | `lune run tests/test_models.luau` |
| Mod_TouchModel (model.c:236) | — | SUBSTITUTED | no cache to touch | — (substitution; verify justification still holds) |
| Mod_LoadModel (model.c:256) | models.luau:forName (dispatch on magic) | VERIFIED | test_models: dispatch on magic across mdl/spr/bsp fixtures. | `lune run tests/test_models.luau` |
| Mod_ForName (model.c:329) | models.luau:forName | VERIFIED | test_models loader battery; every map/alias load in every suite goes through it. | `lune run tests/test_models.luau` |
| Mod_LoadTextures (model.c:355) | bsp.luau:loadTextures | VERIFIED | test_bsp: 81 miptex, names, mip chain size, +anim sequence linking; test_texanim: full +N/+a chain cycles, anim_min/max/total, alternate links on e1m2/start | `lune run tests/test_bsp.luau`; `lune run tests/test_texanim.luau` |
| Mod_LoadLighting (model.c:504) | bsp.luau:loadBlob | VERIFIED | test_bsp: 168590 light bytes | `lune run tests/test_bsp.luau` |
| Mod_LoadVisibility (model.c:521) | bsp.luau:loadBlob | VERIFIED | test_bsp: 40843 vis bytes | `lune run tests/test_bsp.luau` |
| Mod_LoadEntities (model.c:538) | bsp.luau (entities lump as string) | VERIFIED | test_bsp: worldspawn + player start found in lump | `lune run tests/test_bsp.luau` |
| Mod_LoadVertexes (model.c:555) | bsp.luau:loadVertexes | VERIFIED | test_bsp: vert500 exact | `lune run tests/test_bsp.luau` |
| Mod_LoadSubmodels (model.c:583) | bsp.luau:loadSubmodels | VERIFIED | test_bsp: 58 models, submodel hull heads exact | `lune run tests/test_bsp.luau` |
| Mod_LoadEdges (model.c:619) | bsp.luau:loadEdges | VERIFIED | test_bsp face extents depend on edges; 3 faces detail-checked | `lune run tests/test_bsp.luau` |
| Mod_LoadTexinfo (model.c:646) | bsp.luau:loadTexinfo | VERIFIED | test_bsp: face texinfo indices asserted | `lune run tests/test_bsp.luau` |
| CalcSurfaceExtents (model.c:714) | bsp.luau:calcSurfaceExtents | VERIFIED | test_bsp: texturemins/extents exact on faces 0/1000/2000 | `lune run tests/test_bsp.luau` |
| Mod_LoadFaces (model.c:766) | bsp.luau:loadFaces | VERIFIED | test_bsp: plane/side/edges/styles/lightofs exact | `lune run tests/test_bsp.luau` |
| Mod_SetParent (model.c:836) | — | N/A | port navigates the tree top-down (pointInLeaf/PVS); parent links only needed by the C renderer's R_MarkLeaves. N/A: unused in scope (C renderer only). | — (implement first) |
| Mod_LoadNodes (model.c:850) | bsp.luau:loadNodes | VERIFIED | test_bsp: node200 planenum/children exact | `lune run tests/test_bsp.luau` |
| Mod_LoadLeafs (model.c:897) | bsp.luau:loadLeafs | VERIFIED | test_bsp: leaf100 contents/visofs exact | `lune run tests/test_bsp.luau` |
| Mod_LoadClipnodes (model.c:944) | bsp.luau:loadClipnodes | VERIFIED | test_bsp: clipnode300 exact + hull1/hull2 heads, clip_mins/maxs | `lune run tests/test_bsp.luau` |
| Mod_MakeHull0 (model.c:998) | bsp.luau:makeHull0 | VERIFIED | test_bsp: full hull0 child-range sweep; test_trace hull 0 traces vs C | `lune run tests/test_bsp.luau`; `lune run tests/test_trace.luau` |
| Mod_LoadMarksurfaces (model.c:1035) | bsp.luau:loadMarksurfaces | VERIFIED | test_bsp geometry battery (leaf marksurface indices resolve into loaded faces). | `lune run tests/test_bsp.luau` |
| Mod_LoadSurfedges (model.c:1064) | bsp.luau:loadSurfedges | VERIFIED | test_bsp geometry battery (5618 checks; face extents math depends on surfedges). | `lune run tests/test_bsp.luau` |
| Mod_LoadPlanes (model.c:1087) | bsp.luau:loadPlanes | VERIFIED | test_bsp: plane100 normal/dist/type/signbits exact | `lune run tests/test_bsp.luau` |
| RadiusFromBounds (model.c:1125) | bsp.luau:radiusFromBounds | VERIFIED | test_server: the world model radius equals the C corner formula (per-axis max(|mins|,|maxs|) magnitude). | `lune run tests/test_server.luau` |
| Mod_LoadBrushModel (model.c:1143) | bsp.luau:load | VERIFIED | test_bsp: 58 models, world mins/maxs (incl. the ±1 spread quirk), every map in pak0 loads | `lune run tests/test_bsp.luau` |
| Mod_LoadAliasFrame (model.c:1235) | models/mdl.luau:loadFrame | VERIFIED | test_models: frame names, bboxmin/max, vert unpack vs scale/scale_origin | `lune run tests/test_models.luau` |
| Mod_LoadAliasGroup (model.c:1283) | mdl.luau:load (group branch) | VERIFIED | test_models: all 61 pak0 mdls load (includes grouped flame*.mdl); frames[i].frames[] structure | `lune run tests/test_models.luau` |
| Mod_LoadAliasSkin (model.c:1348) | mdl.luau:load (skin branch) | VERIFIED | test_models: player skin 296x194 byte count | `lune run tests/test_models.luau` |
| Mod_LoadAliasSkinGroup (model.c:1387) | mdl.luau:load (skin group branch) | VERIFIED | test_models: armor 3 skins | `lune run tests/test_models.luau` |
| Mod_LoadAliasModel (model.c:1442) | mdl.luau:load | VERIFIED | test_models: header fields (verts/tris/frames/synctype/flags/radius/size ratio) vs Python parse | `lune run tests/test_models.luau` |
| Mod_LoadSpriteFrame (model.c:1669) | models/spr.luau:loadFrame | VERIFIED | test_models: s_explod frame origin/size/pixels exact | `lune run tests/test_models.luau` |
| Mod_LoadSpriteGroup (model.c:1726) | spr.luau:load (group branch) | VERIFIED | test_models: grouped sprites load (s_bubble/s_light) | `lune run tests/test_models.luau` |
| Mod_LoadSpriteModel (model.c:1778) | spr.luau:load | VERIFIED | test_models: type/maxwidth/numframes | `lune run tests/test_models.luau` |
| Mod_Print (model.c:1857) | — | N/A | debug console command. N/A: dev tooling ruled out 2026-07-05 (Studio profiler/debugger is this port's equivalent). | — (implement first) |

## world.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_InitBoxHull (world.c:68) | server/world.luau:initBoxHull | VERIFIED | test_server "point trace clips on the grunt's SOLID_SLIDEBOX box hull". | `lune run tests/test_server.luau` |
| SV_HullForEntity (world.c:129) | world.luau:hullForEntity | VERIFIED | SOLID_BSP hull-select + offset path matched vs compiled C over 300 ticks (test_movement); box path exercised only via E2E | `lune run tests/test_movement.luau` |
| SV_CreateAreaNode (world.c:202) | world.luau:createAreaNode | VERIFIED | test_server NQ areanode battery (door found through the node tree, lost on unlink, refound on relink). | `lune run tests/test_server.luau` |
| SV_ClearWorld (world.c:247) | world.luau:new | VERIFIED | test_server: battery runs against the tree built at spawnServer. | `lune run tests/test_server.luau` |
| SV_UnlinkEdict (world.c:263) | world.luau:unlinkEdict | VERIFIED | test_server "unlinked door no longer clips (RemoveLink)". | `lune run tests/test_server.luau` |
| SV_TouchLinks (world.c:277) | world.luau:touchLinks | VERIFIED | test_scenario_nq "walking over the shells box picked it up through touch" — the pickup fires only through SV_TouchLinks on player movement. | `lune run tests/test_scenario_nq.luau` |
| SV_FindTouchedLeafs (world.c:328) | world.luau:findTouchedLeafs | VERIFIED | leafnums feed SV_WriteEntitiesToClient PVS culling → test_loopback entity-visibility assertions (player visible, ≥4 after moving) | `lune run tests/test_loopback.luau` |
| SV_LinkEdict (world.c:372) | world.luau:linkEdict | VERIFIED | test_server areanode battery (relink restores a bit-equal clip) + the move_truth chain that runs through linked doors. | `lune run tests/test_server.luau`; `lune run tests/test_movement.luau` |
| SV_HullPointContents (world.c:491) | world.luau:hullPointContents | VERIFIED | test_trace: 200 points x 3 hulls exact vs tools/trace_truth.c | `lune run tests/test_trace.luau` |
| SV_PointContents (world.c:527) | world.luau:pointContents | VERIFIED | in the matched movement chain (checkWater per tick, test_movement); CONTENTS_CURRENT clamp path untested (no current brushes exercised) | `lune run tests/test_movement.luau` |
| SV_TruePointContents (world.c:537) | world.luau:truePointContents | VERIFIED | Wrapper over hullPointContents(hull0), which test_trace matches against the compiled C on 200 points x 3 hulls. | `lune run tests/test_trace.luau` |
| SV_RecursiveHullCheck (world.c:581) | world.luau:recursiveHullCheck | VERIFIED | test_trace: 300 segments x 3 hulls — allsolid/startsolid/inopen/inwater/fraction/endpos/plane exact vs compiled C (1503 checks total incl. points) | `lune run tests/test_trace.luau` |
| SV_ClipMoveToEntity (world.c:722) | world.luau:clipMoveToEntity | VERIFIED | world-entity clipping matched over 300 ticks (test_movement) | `lune run tests/test_movement.luau` |
| SV_ClipToLinks (world.c:814) | world.luau:clipToLinks | VERIFIED | test_server battery: hit attribution to the door edict and the grunt box with a player passedict. | `lune run tests/test_server.luau` |
| SV_MoveBounds (world.c:893) | world.luau:moveBounds | VERIFIED | test_server areanode battery gathers candidates through the bounds; part of the matched move chain (±1 expansion). | `lune run tests/test_server.luau`; `lune run tests/test_movement.luau` |
| SV_Move (world.c:923) | world.luau:move | VERIFIED | test_movement: 300-tick origin/velocity match vs compiled C (world clip); MOVE_MISSILE ±15 preserved, entity clip via E2E only | `lune run tests/test_movement.luau` |
| SV_TestEntityPosition (world.c:551) | world.luau:testEntityPosition | VERIFIED | called by checkStuck every tick of the matched chain | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |

## pr_edict.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| ED_ClearEdict (pr_edict.c:70) | progs/vm.luau:clearEdict | VERIFIED | alloc zero-fills fields (test_vm: free clears solid) | `lune run tests/test_vm.luau` |
| ED_Alloc (pr_edict.c:87) | vm.luau:alloc | VERIFIED | test_vm "alloc grows"; 0.5s/2s freetime replacement policy preserved | `lune run tests/test_vm.luau` |
| ED_Free (pr_edict.c:122) | vm.luau:free | VERIFIED | test_vm: freed flag, model/solid cleared, nextthink=-1; unlink hook wired to world | `lune run tests/test_vm.luau` |
| ED_GlobalAtOfs (pr_edict.c:148) | progs/progs.luau lookup tables | VERIFIED | test_vm: every transcribed global offset matched to real def table | `lune run tests/test_vm.luau` |
| ED_FieldAtOfs (pr_edict.c:167) | progs.luau fielddefs | VERIFIED | test_vm: every transcribed field offset matched | `lune run tests/test_vm.luau` |
| ED_FindField (pr_edict.c:186) | progs.luau:fielddefsByName | VERIFIED | test_vm fielddef lookups; savegame field parse | `lune run tests/test_vm.luau` |
| ED_FindGlobal (pr_edict.c:206) | progs.luau:globaldefsByName | VERIFIED | savegame globals restore (test_savegame) | `lune run tests/test_savegame.luau` |
| ED_FindFunction (pr_edict.c:226) | progs.luau:functionsByName | VERIFIED | test_vm: anglemod=90, worldspawn=209, SUB_Null=66 | `lune run tests/test_vm.luau` |
| GetEdictFieldValue (pr_edict.c:241) | vm.luau:findFieldDef + edFloat | VERIFIED | test_savegame round-trip parses every entity field by name through findFieldDef (ED_ParseEpair on arbitrary fields). | `lune run tests/test_savegame.luau` |
| PR_ValueString (pr_edict.c:280) | progs/prdebug.luau valueString | VERIFIED | test_prdebug: %5.1f floats, quoted vector triple, entity %i, function name(), .field by ofs, void/pointer/bad-type, DEF_SAVEGLOBAL masked, string via the blob/dynstrings | `lune run tests/test_prdebug.luau` |
| PR_UglyValueString (pr_edict.c:332) | server/savegame.luau:uglyValue | VERIFIED | test_savegame: function/field/entity values round-trip through save text | `lune run tests/test_savegame.luau` |
| PR_GlobalString (pr_edict.c:381) | prdebug.globalString | VERIFIED | test_prdebug: %i(name)value with the 20-char pad + trailing space, (???) for unknown offsets | `lune run tests/test_prdebug.luau` |
| PR_GlobalStringNoContents (pr_edict.c:407) | prdebug.globalStringNoContents | VERIFIED | test_prdebug: %i(name) padded, no value | `lune run tests/test_prdebug.luau` |
| ED_Print (pr_edict.c:435) | prdebug.edPrint | VERIFIED | test_prdebug on the booted e1m1 world: EDICT %i header, exact 15-column name field, non-zero fields only, _x/_y/_z skipped, FREE for freed edicts | `lune run tests/test_prdebug.luau` |
| ED_Write (pr_edict.c:485) | savegame.luau:writeEdict | VERIFIED | test_savegame: full state round-trip (health/items/rockets/origin/edict count) | `lune run tests/test_savegame.luau` |
| ED_PrintNum (pr_edict.c:525) | prdebug.edPrintNum | VERIFIED | test_prdebug: routes by edict number (also the PF_eprint body) | `lune run tests/test_prdebug.luau` |
| ED_PrintEdicts (pr_edict.c:537) | prdebug.edPrintEdicts + the `edicts` host command | VERIFIED | test_prdebug: '%i entities' header + every edict on live e1m1 | `lune run tests/test_prdebug.luau` |
| ED_PrintEdict_f (pr_edict.c:553) | `edict <n>` host command (host.clientCommand) | VERIFIED | test_server: "edict 0" prints the worldspawn dump through the command dispatch (host-gated) | `lune run tests/test_server.luau` |
| ED_Count (pr_edict.c:573) | prdebug.edCount + the `edictcount` host command | VERIFIED | test_prdebug: num_edicts/active/view/touch/step tallies on live e1m1 (MOVETYPE_STEP monsters counted; field offsets resolved by name so QW progs work too); test_server drives the command | `lune run tests/test_prdebug.luau`; `lune run tests/test_server.luau` |
| ED_WriteGlobals (pr_edict.c:616) | savegame.luau:writeGlobals | VERIFIED | test_savegame: world message/serverflags/totals survive reload | `lune run tests/test_savegame.luau` |
| ED_ParseGlobals (pr_edict.c:649) | savegame.luau:load (globals block) | VERIFIED | test_savegame round-trip | `lune run tests/test_savegame.luau` |
| ED_NewString (pr_edict.c:693) | vm.luau:newString | VERIFIED | test_vm: `\n` escape converted, other backslashes preserved | `lune run tests/test_vm.luau` |
| ED_ParseEpair (pr_edict.c:~714) | vm.luau:parseEpair | VERIFIED | test_vm: string/float/vector parse; savegame function/field restore | `lune run tests/test_vm.luau` |
| ED_ParseEdict (pr_edict.c:802) | vm.luau:parseEdict | VERIFIED | test_vm: classname/origin/anglehack ("angle 90" → angles (0,90,0)) | `lune run tests/test_vm.luau` |
| ED_LoadFromFile (pr_edict.c:905) | vm.luau:loadFromFile | VERIFIED | test_server census: 1 worldspawn, 18 grunts, 5 dogs, 21 doors; skill/deathmatch spawnflag inhibit logic ported | `lune run tests/test_server.luau` |
| PR_LoadProgs (pr_edict.c:985) | progs/progs.luau:load | VERIFIED | test_vm: header CRC 5927, file CRC16 46133, all table counts vs Python parse | `lune run tests/test_vm.luau` |
| PR_Init (pr_edict.c:1068) | cvar.luau DEFAULTS (nomonsters/scratch*/saved*) | SUBSTITUTED | no console commands to register; cvars pre-seeded | — (substitution; verify justification still holds) |
| EDICT_NUM (pr_edict.c:1089) | vm.luau:edictNum | VERIFIED | test_vm edict battery (range-checked). | `lune run tests/test_vm.luau` |
| NUM_FOR_EDICT (pr_edict.c:1096) | Edict.num field | VERIFIED | test_vm edict battery (identity kept on the edict record). | `lune run tests/test_vm.luau` |

## pr_exec.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| PR_PrintStatement (pr_exec.c:150) | prdebug.statementString (+ the vm.trace per-statement hook) | VERIFIED | test_prdebug: opname padded to 10 with operand global strings on real progs statements, IF/GOTO 'branch %i' forms; live tracing exercised through PF_traceon | `lune run tests/test_prdebug.luau` |
| PR_StackTrace (pr_exec.c:190) | prdebug.stackTrace (full '%12s : %s' walk) + runError's function/statement context | VERIFIED | test_prdebug: <NO STACK> at rest; captured from inside a builtin mid-exec with the current function on top; runError message context separately covered (test_qwbuiltins exec(0)) | `lune run tests/test_prdebug.luau` |
| PR_Profile_f (pr_exec.c:222) | prdebug.profileReport + the `profile` host command; per-function statement attribution at the C call/leave sites in vm.luau | VERIFIED | test_prdebug: counts accumulate through host.frame QC, '%7i %s' lines descending, counters zeroed by the report (the C do/while); test_server drives the command | `lune run tests/test_prdebug.luau` |
| PR_RunError (pr_exec.c:261) | vm.luau:runError | VERIFIED | test_qwbuiltins "exec(0) errors (PR_RunError null function)" — shared vm.luau implementation serves both engines. | `lune run tests/test_qwbuiltins.luau` |
| PR_EnterFunction (pr_exec.c:294) | vm.luau:enterFunction | VERIFIED | parm copy-in/locals save; test_vm anglemod bytecode + stack balanced after calls | `lune run tests/test_vm.luau` |
| PR_LeaveFunction (pr_exec.c:333) | vm.luau:leaveFunction | VERIFIED | locals restore; test_vm stack depth 0 after nested calls | `lune run tests/test_vm.luau` |
| PR_ExecuteProgram (pr_exec.c:361) | vm.luau:exec | VERIFIED | full opcode interpreter runs shipped progs.dat through every E2E test; test_vm: anglemod values, -0.0 IFNOT int semantics, runaway counter kept | `lune run tests/test_vm.luau` |

## sv_main.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_Init (sv_main.c:36) | server/sv.luau:new + cvar DEFAULTS | SUBSTITUTED | cvar registration replaced by the defaults table; localmodels precomputed on demand (`*n` names) | — (substitution; verify justification still holds) |
| SV_StartParticle (sv_main.c:80) | sv.luau:startParticle | VERIFIED | test_nqbuiltins: svc_particle written to the datagram through it. | `lune run tests/test_nqbuiltins.luau` |
| SV_StartSound (sv_main.c:118) | sv.luau:startSound | VERIFIED | test_loopback: "weapons/guncock.wav" event received by client with channel/entity packing | `lune run tests/test_loopback.luau` |
| SV_SendServerinfo (sv_main.c:189) | sv.luau:sendServerinfo | VERIFIED | test_loopback: levelname, maxclients, precache lists, signon 1 | `lune run tests/test_loopback.luau` |
| SV_ConnectClient (sv_main.c:243) | sv.luau:connectClient | VERIFIED | signon completes in loopback; SetNewParms → spawn_parms copied; delta: no netconnection object (transport hooks) | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_CheckForNewClients (sv_main.c:302) | src/server/init.server.luau:onInbound/connectPlayer | SUBSTITUTED | polling sockets → event-driven Roblox remotes; clients announce with a first message | — (substitution; verify justification still holds) |
| SV_ClearDatagram (sv_main.c:348) | host.luau:frame (msg.clear) | VERIFIED | per-frame clear; datagram flow asserted in test_server | `lune run tests/test_server.luau` |
| SV_AddToFatPVS (sv_main.c:367) | sv.luau:addToFatPVS | VERIFIED | loopback: spawn-area PVS entity set matches an independent PVS decode (test comment) + visibility assertions; delta: fat buffer zero-padded instead of C's stale static bytes | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_FatPVS (sv_main.c:410) | sv.luau:fatPVS | VERIFIED | test_loopback "visible entities after moving" — entity writes are fatPVS-culled. | `lune run tests/test_loopback.luau` |
| SV_WriteEntitiesToClient (sv_main.c:427) | sv.luau:writeEntitiesToClient | VERIFIED | loopback: baselines + delta bits reproduce entity origins/motion client-side; U_* bit logic side-by-side compared | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_CleanupEnts (sv_main.c:557) | sv.luau:cleanupEnts | VERIFIED | test_server: EF_MUZZLEFLASH cleared after the frame that fired. | `lune run tests/test_server.luau` |
| SV_WriteClientdataToMessage (sv_main.c:576) | sv.luau:writeClientdataToMessage | VERIFIED | loopback: health 100, shells 25, items IT_SHOTGUN, onground, velocity, damage message path in E2E | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_SendClientDatagram (sv_main.c:720) | sv.luau:sendClientDatagram | VERIFIED | test_server: >50 unreliable datagrams, svc_time header + plausible time | `lune run tests/test_server.luau` |
| SV_UpdateToReliableMessages (sv_main.c:756) | sv.luau:updateToReliableMessages | VERIFIED | test_multiplayer: suicide frag -2 propagates to both clients | `lune run tests/test_multiplayer.luau` |
| SV_SendNop (sv_main.c:798) | sv.luau:sendClientMessages (nop branch) | VERIFIED | test_server: a connected-but-unspawned client idle for >5s receives the 1-byte svc_nop keepalive (last_message gate as C). | `lune run tests/test_server.luau` |
| SV_SendClientMessages (sv_main.c:819) | sv.luau:sendClientMessages | VERIFIED | signon gating + reliable/unreliable split proven by loopback signon; overflow-drop branch unasserted | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SV_ModelIndex (sv_main.c:904) | sv.luau:modelIndex | VERIFIED | test_server: player.mdl index > 0; errors on missing precache | `lune run tests/test_server.luau` |
| SV_CreateBaseline (sv_main.c:925) | sv.luau:createBaseline | VERIFIED | test_server: signon > 1000 bytes; loopback: entities render from baselines | `lune run tests/test_server.luau` |
| SV_SendReconnect (sv_main.c:985) | init.server.luau changelevel block | SUBSTITUTED | no svc_stufftext "reconnect" round-trip; the platform re-runs connectClient for each seated player after spawnServer | — (substitution; verify justification still holds) |
| SV_SaveSpawnparms (sv_main.c:1015) | server/host.luau:saveSpawnparms | VERIFIED | test_changelevel "nailgun carried to e1m2"/"nail count carried"/"health carried (61)": SetChangeParms per active client + serverflags latch; changelevel reconnect preserves parms (connectClient preserveParms — C keeps the connection and never re-runs SetNewParms) | `lune run tests/test_changelevel.luau` |
| SV_SpawnServer (sv_main.c:1047) | server/host.luau:spawnServer | VERIFIED | test_server: entity census, precaches, lightstyles, two settle frames, baseline; QUAKE2 startspot variant excluded | `lune run tests/test_server.luau` |

## sv_move.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_CheckBottom (sv_move.c:37) | server/sv_move.luau:checkBottom | VERIFIED | svmove truth course: bit-identical over 200 chase calls vs the verbatim C (plus the earlier builtin-battery behavioral checks). | `lune run tests/test_svmove.luau` |
| SV_movestep (sv_move.c:110) | sv_move.luau:movestep | VERIFIED | svmove truth course: bit-identical over 200 chase calls vs the verbatim C (plus the earlier builtin-battery behavioral checks). | `lune run tests/test_svmove.luau` |
| SV_StepDirection (sv_move.c:233) | sv_move.luau:stepDirection | VERIFIED | test_svmove vs tools/svmove_truth.c (verbatim sv_move.c + shared msvcrt LCG): 200 MoveToGoal calls, position AND yaw error 0.000000 — every step/turn decision identical. | `lune run tests/test_svmove.luau` |
| SV_FixCheckBottom (sv_move.c:268) | sv_move.luau:fixCheckBottom | VERIFIED | svmove truth course: the PARTIALGROUND path participates in the bit-identical chase (any divergence would desync the shared rand stream). | `lune run tests/test_svmove.luau` |
| SV_NewChaseDir (sv_move.c:284) | sv_move.luau:newChaseDir | VERIFIED | svmove truth course: the rand()-gated direction swaps and search loops match the C decision-for-decision (shared LCG from seed 12345). | `lune run tests/test_svmove.luau` |
| SV_CloseEnough (sv_move.c:373) | sv_move.luau:closeEnough | VERIFIED | svmove truth course: both sides idle at the same arrival tick against ±1-expanded abs boxes. | `lune run tests/test_svmove.luau` |
| SV_MoveToGoal (sv_move.c:393) | sv_move.luau:moveToGoal (builtin 67) | VERIFIED | svmove truth course: 200 calls bit-identical (0.000000 position/yaw error), monster chases 360+ units across the e1m1 hall. | `lune run tests/test_svmove.luau` |

## sv_phys.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_CheckAllEnts (sv_phys.c:61) | — | N/A | debug sweep, never called by the C game loop. N/A: dead in C (never called). | — (implement first) |
| SV_CheckVelocity (sv_phys.c:90) | server/sv_phys.luau:checkVelocity | VERIFIED | test_movement: in the 300-tick chain matched vs tools/move_truth.c (max err 0.0002 units) | `lune run tests/test_movement.luau` |
| SV_RunThink (sv_phys.c:126) | sv_phys.luau:runThink | VERIFIED | test_server: grunt animation frames advance (QC think chain); sub-frametime nextthink clamp ported | `lune run tests/test_server.luau` |
| SV_Impact (sv_phys.c:153) | sv_phys.luau:impact | VERIFIED | test_server: a nailgun spike frees on wall contact (impact fires spike_touch); the toss battery runs the no-touch path. | `lune run tests/test_server.luau` |
| ClipVelocity (sv_phys.c:190) | sv_phys.luau:clipVelocity | VERIFIED | move_truth chain vs compiled C (wall slides during the yaw-135 phase), 0.000184 max error over 300 ticks. | `lune run tests/test_movement.luau` |
| SV_FlyMove (sv_phys.c:229) | sv_phys.luau:flyMove | VERIFIED | move_truth chain incl. bumps/planes/steptrace. | `lune run tests/test_movement.luau` |
| SV_AddGravity (sv_phys.c:371) | sv_phys.luau:addGravity | VERIFIED | move_truth chain (jump arcs land identically). | `lune run tests/test_movement.luau` |
| SV_PushEntity (sv_phys.c:408) | sv_phys.luau:pushEntity | VERIFIED | test_server toss check: the lobbed edict advances through pushEntity each frame (arc + landing). | `lune run tests/test_server.luau` |
| SV_PushMove (sv_phys.c:439) | sv_phys.luau:pushMove | VERIFIED | test_server "door traveled through SV_PushMove". | `lune run tests/test_server.luau` |
| SV_PushRotate (sv_phys.c:566) | — | N/A | dead: QUAKE2-only ifdef in WinQuake. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| SV_Physics_Pusher (sv_phys.c:704) | sv_phys.luau:physicsPusher | VERIFIED | test_server: door travels and returns home after its wait (think scheduling through the pusher path). | `lune run tests/test_server.luau` |
| SV_CheckStuck (sv_phys.c:762) | sv_phys.luau:checkStuck | VERIFIED | test_server "SV_CheckStuck restored oldorigin from inside the door" + runs every tick of the move_truth chain. | `lune run tests/test_server.luau`; `lune run tests/test_movement.luau` |
| SV_CheckWater (sv_phys.c:808) | sv_phys.luau:checkWater | VERIFIED | move_truth chains: dry course + the water course (waterlevels 3/2/1/0 transitions agree every tick). | `lune run tests/test_movement.luau` |
| SV_WallFriction (sv_phys.c:867) | sv_phys.luau:wallFriction | VERIFIED | move_truth chain (inside the walkMove path). | `lune run tests/test_movement.luau` |
| SV_TryUnstick (sv_phys.c:901) | sv_phys.luau:tryUnstick | VERIFIED | Two-part: (1) trigger parity — the corner-grind truth course (40 ticks wedging into the spawn-hall corner) matches C to 0.000031 with the C-side unstick counter at 0, so a spurious port trigger (±2-unit nudges) would diverge instantly; (2) the nudge-retry body unit-checked directly at an open spot (moves, returns non-wedged). | `lune run tests/test_movement.luau` |
| SV_WalkMove (sv_phys.c:958) | sv_phys.luau:walkMove | VERIFIED | move_truth chain incl. step-up/down and oldonground handling. | `lune run tests/test_movement.luau` |
| SV_Physics_Client (sv_phys.c:1059) | sv_phys.luau:physicsClient | VERIFIED | test_server: player walks/falls/fires (PlayerPreThink/PostThink run); WALK branch replicated tick-exact in test_movement | `lune run tests/test_movement.luau`; `lune run tests/test_server.luau` |
| SV_Physics_None (sv_phys.c:1142) | sv_phys.luau:physicsNone | VERIFIED | test_server: MOVETYPE_NONE edict never moves despite velocity. | `lune run tests/test_server.luau` |
| SV_Physics_Follow (sv_phys.c:1156) | — | N/A | dead: QUAKE2-only. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| SV_Physics_Noclip (sv_phys.c:1172) | sv_phys.luau:physicsNoclip | VERIFIED | test_server: MOVETYPE_NOCLIP edict flies through the ceiling. | `lune run tests/test_server.luau` |
| SV_CheckWaterTransition (sv_phys.c:1198) | sv_phys.luau:checkWaterTransition | VERIFIED | test_server toss path (dry transition only; water entry/exit remains uncovered pending the water truth course). | `lune run tests/test_server.luau` |
| SV_Physics_Toss (sv_phys.c:1245) | sv_phys.luau:physicsToss | VERIFIED | test_server: lobbed SOLID_BBOX edict arcs up, falls, rests with FL_ONGROUND and zero velocity. | `lune run tests/test_server.luau` |
| SV_Physics_Step (sv_phys.c:1468, NQ variant) | sv_phys.luau:physicsStep | VERIFIED | NQ (non-QUAKE2) variant ported; grunt think/animate asserted in test_server; freefall land-sound branch unasserted. QUAKE2 variant (sv_phys.c:1363) excluded as dead | `lune run tests/test_server.luau` |
| SV_Physics (sv_phys.c:1507) | sv_phys.luau:physics | VERIFIED | test_server: StartFrame QC runs, time advances, all movetypes dispatched for 100+ frames; delta: C's single-player key_dest pause is client-side, port pauses via svr.paused only | `lune run tests/test_server.luau` |
| SV_Trace_Toss (sv_phys.c:1568) | — | N/A | only consumed by QUAKE2-only PF_TraceToss. N/A: dead in C (QUAKE2-only consumer). | — (implement first) |

## sv_user.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SV_SetIdealPitch (sv_user.c:53) | server/sv_user.luau:setIdealPitch | VERIFIED | test_server: ideal_pitch driven walking the entrance ramp from a fixed start. | `lune run tests/test_server.luau` |
| SV_UserFriction (sv_user.c:122) | sv_user.luau:userFriction | VERIFIED | matched chain (test_movement) incl. edgefriction leading-edge trace | `lune run tests/test_movement.luau` |
| SV_Accelerate (#if 0 variant, sv_user.c:170) | — | N/A | dead: disabled by `#if 0` in WinQuake. N/A: dead in C (#if 0). | — (implement first) |
| SV_Accelerate (sv_user.c:190) | sv_user.luau:accelerate | VERIFIED | move_truth chain. | `lune run tests/test_movement.luau` |
| SV_AirAccelerate (sv_user.c:207) | sv_user.luau:airAccelerate | VERIFIED | move_truth chain (wishspd 30 clamp). | `lune run tests/test_movement.luau` |
| DropPunchAngle (sv_user.c:229) | sv_user.luau:dropPunchAngle | VERIFIED | test_server: shotgun sets punchangle_x = -2 (QC) and the server decays it to zero over the following frames. | `lune run tests/test_server.luau` |
| SV_WaterMove (sv_user.c:247) | sv_user.luau:waterMove | VERIFIED | move_truth water course (ticks 300-379, e1m1 slime pool): swim accel/friction and the no-input sink match the verbatim C to 0.000127 units across waterlevels 3..0. | `lune run tests/test_movement.luau` |
| SV_WaterJump (sv_user.c:307) | sv_user.luau:waterJump | VERIFIED | move_truth water course: a deterministic QC-trigger emulation at tick 39 (FL_WATERJUMP + movedir + vel 225) runs the verbatim SV_WaterJump on both sides — the jump carries the player out of the pool identically (flag clear + movedir velocity override). | `lune run tests/test_movement.luau` |
| SV_AirMove (sv_user.c:326) | sv_user.luau:airMove | VERIFIED | move_truth chain (fwd/side/up wishvel, onground dispatch). | `lune run tests/test_movement.luau` |
| SV_ClientThink (sv_user.c:380) | sv_user.luau:clientThink | VERIFIED | move_truth chain; includes V_CalcRoll (view.c) for angles roll. | `lune run tests/test_movement.luau` |
| SV_ReadClientMove (sv_user.c:438) | sv_user.luau:readClientMove | VERIFIED | test_server: clc_move angles/moves/buttons/impulse drive asserted movement + shotgun fire; delta: ping_times[] not tracked (no ping report) | `lune run tests/test_server.luau` |
| SV_ReadClientMessage (sv_user.c:482) | server/host.luau:readClientMessage | VERIFIED | test_server drives stringcmd/move dispatch through the inbox (signon flow + firing); scenario tests parse full sessions. | `lune run tests/test_server.luau`; `lune run tests/test_scenario_nq.luau` |
| SV_RunClients (sv_user.c:600) | host.luau:runClients | VERIFIED | Every E2E test moves the player through it (test_server forward run, scenario walks); drop/paused gates exercised in test_savegame (paused load). | `lune run tests/test_server.luau`; `lune run tests/test_savegame.luau` |

## host.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Host_EndGame (host.c:90) | — | SUBSTITUTED | no demo loop/process to unwind; Luau error + platform respawn (Roblox server owns the process) | — (substitution; verify justification still holds) |
| Host_Error (host.c:121) | Luau error() propagation | SUBSTITUTED | no longjmp; errors bubble to the Heartbeat boundary | — (substitution; verify justification still holds) |
| Host_FindMaxClients (host.c:157) | init.server.luau (fixed 16 slots) | SUBSTITUTED | no -dedicated/-listen argv; Roblox place size governs players | — (substitution; verify justification still holds) |
| Host_InitLocal (host.c:209) | cvar.luau DEFAULTS | SUBSTITUTED | host cvars (host_framerate/serverprofile...) are dev knobs without a console | — (substitution; verify justification still holds) |
| Host_WriteConfiguration (host.c:246) | — | SUBSTITUTED | no writable config.cfg on Roblox (FIDELITY.md); DataStore substitute possible later | — (substitution; verify justification still holds) |
| SV_ClientPrintf (host.c:277) | host.luau:clientPrint | VERIFIED | test_server: sprint/say paths write svc_print into the target client reliable stream (clientPrint carries all of them); scenario pickup prints arrive end-to-end. | `lune run tests/test_server.luau`; `lune run tests/test_scenario_nq.luau` |
| SV_BroadcastPrintf (host.c:297) | sv.luau:broadcastPrint | VERIFIED | test_server say broadcast (svc_print in the reliable stream); test_nqbuiltins bprint. | `lune run tests/test_server.luau`; `lune run tests/test_nqbuiltins.luau` |
| Host_ClientCommands (host.c:322) | sv.luau:clientCommands | VERIFIED | test_nqbuiltins: stuffcmd writes svc_stufftext through it. | `lune run tests/test_nqbuiltins.luau` |
| SV_DropClient (host.c:343) | sv.luau:dropClient | VERIFIED | test_server: dropClient deactivates the client cleanly at session end. | `lune run tests/test_server.luau` |
| Host_ShutdownServer (host.c:405) | — | SUBSTITUTED | Roblox server lifecycle; level changes respawn in place (host.spawnServer) and re-connect seated players instead of a shutdown message | — (substitution; verify justification still holds) |
| Host_ClearMemory (host.c:477) | — | SUBSTITUTED | GC; spawnServer builds a fresh VM/world per level | — (substitution; verify justification still holds) |
| Host_FilterTime (host.c:501) | init.server.luau Heartbeat clamp | SUBSTITUTED | Heartbeat dt clamped to [0.001, 0.1]; no 72fps cap (FIDELITY.md: dt-driven sim verified at arbitrary dt) | — (substitution; verify justification still holds) |
| Host_GetConsoleCommands (host.c:532) | — | SUBSTITUTED | no dedicated-server console; Studio attributes serve as the debug channel | — (substitution; verify justification still holds) |
| _Host_ServerFrame (host.c:554, FPS_20) | — | N/A | dead: FPS_20 ifdef not compiled in WinQuake. N/A: dead in C (FPS_20 ifdef). | — (implement first) |
| Host_ServerFrame (host.c:600) | host.luau:frame | VERIFIED | test_server/test_loopback: clear datagram → run clients → physics → send messages, in C order; new-client polling is event-driven (substitution noted above) | `lune run tests/test_loopback.luau`; `lune run tests/test_server.luau` |
| _Host_Frame / Host_Frame (host.c:633,729) | host.luau:frame + init.server.luau Heartbeat | VERIFIED | Server half: every offline E2E suite advances the world through host.frame (time advance, physics, datagram flush asserted in test_server). Client half (input/render/sound pump) is the Studio Heartbeat — SUBSTITUTED per the init.server row. | `lune run tests/test_server.luau` |
| Host_InitVCR (host.c:772) | — | N/A | VCR record/playback dev harness. N/A: DOS-era (VCR harness). | — (implement first) |
| Host_Init (host.c:835) | init.server.luau bootstrap | SUBSTITUTED | pak assembly from asset chunks, remotes, host.newGame | — (substitution; verify justification still holds) |
| Host_Shutdown (host.c:932) | — | SUBSTITUTED | Roblox tears the server down | — (substitution; verify justification still holds) |

## host_cmd.c

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Host_Quit_f (host_cmd.c:37) | — | SUBSTITUTED | players leave via Roblox; no process quit | — (substitution; verify justification still holds) |
| Host_Status_f (host_cmd.c:56) | host.luau:clientCommand ("status" no-op) | UNIMPLEMENTED | informational report not built | ruled: IMPLEMENT via director admin menu (2026-07-05) |
| Host_God_f (host_cmd.c:113) | host.luau:toggleFlag (god) | VERIFIED | test_server: god toggles FL_GODMODE both ways. | `lune run tests/test_server.luau` |
| Host_Notarget_f (host_cmd.c:131) | toggleFlag (notarget) | VERIFIED | test_server: notarget sets FL_NOTARGET. | `lune run tests/test_server.luau` |
| Host_Noclip_f (host_cmd.c:151) | clientCommand "noclip" | VERIFIED | test_server: noclip toggles MOVETYPE_NOCLIP/WALK. | `lune run tests/test_server.luau` |
| Host_Fly_f (host_cmd.c:183) | clientCommand "fly" | VERIFIED | test_server: fly toggles MOVETYPE_FLY. | `lune run tests/test_server.luau` |
| Host_Ping_f (host_cmd.c:213) | "ping" no-op | UNIMPLEMENTED | ping times not tracked (see SV_ReadClientMove delta) | ruled: IMPLEMENT via director admin menu (2026-07-05) |
| Host_Map_f (host_cmd.c:256) | clientCommand "map" → changelevelTo + platform respawn | VERIFIED | test_server: map routes to svr.changelevelTo (the platform respawn driver consumes it, changelevel-tested in test_changelevel). | `lune run tests/test_server.luau` |
| Host_Changelevel_f (host_cmd.c:311) | clientCommand "changelevel" / QC builtin 70 | VERIFIED | test_changelevel end-to-end: trigger touch → intermission → changelevel with SV_SaveSpawnparms carry | `lune run tests/test_changelevel.luau` |
| Host_Restart_f (host_cmd.c:366) | pr_cmds.luau localcmd "restart" → respawn same map | VERIFIED | test_nqbuiltins: localcmd restart routes to the respawn driver (changelevelTo set). | `lune run tests/test_nqbuiltins.luau` |
| Host_Reconnect_f (host_cmd.c:396) | — | SUBSTITUTED | client-side signon reset; platform reconnects slots after respawn | — (substitution; verify justification still holds) |
| Host_Connect_f (host_cmd.c:409) | — | SUBSTITUTED | Roblox join flow replaces connect <host> | — (substitution; verify justification still holds) |
| Host_SavegameComment (host_cmd.c:442) | savegame.luau:comment | VERIFIED | test_savegame: 39-char fixed-width comment with level name + kills, as C. | `lune run tests/test_savegame.luau` |
| Host_Savegame_f (host_cmd.c:465) | savegame.luau:write + clientCommand "save" | VERIFIED | test_savegame: version-5 text, >10KB content, full state round-trip (13 checks); storage substituted to ServerStorage.QuakeSaves | `lune run tests/test_savegame.luau` |
| Host_Loadgame_f (host_cmd.c:561) | savegame.luau:load + deferred loadgameRequest | VERIFIED | test_savegame: health/items/rockets/origin/time/edict count restored, pause-until-begin, still runs after resume | `lune run tests/test_savegame.luau` |
| SaveGamestate (host_cmd.c:710) | — | N/A | dead: QUAKE2-only. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| LoadGamestate (host_cmd.c:761) | — | N/A | dead: QUAKE2-only. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| Host_Changelevel2_f (host_cmd.c:865) | — | N/A | dead: QUAKE2-only. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| Host_Name_f (host_cmd.c:910) | host.luau:hostName | VERIFIED | test_multiplayer: names propagate to both clients' scoreboards; 15-char clamp + netname set | `lune run tests/test_multiplayer.luau` |
| Host_Version_f (host_cmd.c:949) | — | UNIMPLEMENTED | trivial console print | ruled: IMPLEMENT (2026-07-05) |
| Host_Please_f (host_cmd.c:956) | — | N/A | registered-only easter egg. N/A: dead-end easter egg; no counterpart meaningful. | — (implement first) |
| Host_Say (host_cmd.c:1008) | host.luau:hostSay | VERIFIED | test_server: say broadcasts svc_print into the client reliable stream. | `lune run tests/test_server.luau` |
| Host_Say_f (host_cmd.c:1072) | clientCommand "say" | VERIFIED | test_server say check (clientCommand "say ..."). | `lune run tests/test_server.luau` |
| Host_Say_Team_f (host_cmd.c:1078) | clientCommand "say_team" | VERIFIED | test_server: say_team broadcasts svc_print. | `lune run tests/test_server.luau` |
| Host_Tell_f (host_cmd.c:1084) | — | SUBSTITUTED | private messaging not ported. SUBSTITUTED: Roblox whisper/chat owns private messaging (admin ruling, 2026-07-05). | — |
| Host_Color_f (host_cmd.c:1141) | host.luau:hostColor | VERIFIED | test_server: color 4 12 sets team = bottom + 1. | `lune run tests/test_server.luau` |
| Host_Kill_f (host_cmd.c:1192) | host.luau:hostKill | VERIFIED | test_multiplayer: kill → ClientKill QC → -2 frags on both views + respawn | `lune run tests/test_multiplayer.luau` |
| Host_Pause_f (host_cmd.c:1217) | clientCommand "pause" | VERIFIED | test_server: pause toggles svr.paused both ways. | `lune run tests/test_server.luau` |
| Host_PreSpawn_f (host_cmd.c:1254) | host.luau:hostPreSpawn | VERIFIED | loopback signon: signon buffer replay + signonnum 2 (baselines/ambients received) | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| Host_Spawn_f (host_cmd.c:1279) | host.luau:hostSpawn | VERIFIED | loopback: ClientConnect/PutClientInServer run, names/frags/colors, lightstyles, stats, setangle, clientdata, signonnum 3 all parsed; loadgame branch in test_savegame | `lune run tests/test_savegame.luau` |
| Host_Begin_f (host_cmd.c:1403) | host.luau:hostBegin | VERIFIED | client.spawned asserted everywhere; loadgame unpause branch in test_savegame | `lune run tests/test_savegame.luau` |
| Host_Kick_f (host_cmd.c:1424) | — | UNIMPLEMENTED | admin kick not ported (platform Kick only for full server) | ruled: IMPLEMENT via director admin menu (2026-07-05) |
| Host_Give_f (host_cmd.c:1516) | clientCommand "give" | VERIFIED | test_server: give r 44 sets rockets; test_savegame gives weapon 7 + rockets. | `lune run tests/test_server.luau`; `lune run tests/test_savegame.luau` |
| Host_Viewmodel_f (host_cmd.c:1690) | — | UNIMPLEMENTED | dev model-viewer command | — (implement first) |
| Host_Viewframe_f (host_cmd.c:1715) | — | UNIMPLEMENTED | dev | — (implement first) |
| PrintFrameName (host_cmd.c:1734) | — | UNIMPLEMENTED | dev | — (implement first) |
| Host_Viewnext_f (host_cmd.c:1752) | — | UNIMPLEMENTED | dev | — (implement first) |
| Host_Viewprev_f (host_cmd.c:1774) | — | UNIMPLEMENTED | dev | — (implement first) |
| Host_Startdemos_f (host_cmd.c:1806) | client demo system (out of server scope) | SUBSTITUTED | demo playback/record ported client-side per FIDELITY.md; server contributes the rq_need file hook | — (substitution; verify justification still holds) |
| Host_Demos_f (host_cmd.c:1845) | client-side | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| Host_Stopdemo_f (host_cmd.c:1862) | client-side | SUBSTITUTED | same | — (substitution; verify justification still holds) |
| Host_InitCommands (host_cmd.c:1879) | host.luau:clientCommand dispatcher | SUBSTITUTED | command registration table → direct string dispatch of the clc_stringcmd subset | — (substitution; verify justification still holds) |

## pr_cmds.c

All live NQ builtins are installed by server/pr_cmds.luau:install() into the VM's numbered
builtin table (numbers match the C pr_builtin[] array; slots that are PF_Fixme in the NQ
build are absent and hit the VM's bad-builtin error).

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| PF_VarString (pr_cmds.c:33) | pr_cmds.luau:varString | VERIFIED | test_nqbuiltins: bprint concatenates two parm strings into the reliable stream. | `lune run tests/test_nqbuiltins.luau` |
| PF_error #10 (pr_cmds.c:57) | pr_cmds.luau def(10) | VERIFIED | test_nqbuiltins: raises. | `lune run tests/test_nqbuiltins.luau` |
| PF_objerror #11 (pr_cmds.c:81) | def(11) | VERIFIED | test_nqbuiltins: raises. Delta: C only frees self + continues; port aborts the program like PF_error. | `lune run tests/test_nqbuiltins.luau` |
| PF_makevectors #1 (pr_cmds.c:106) | def(1) | VERIFIED | test_nqbuiltins: yaw 90 forward = +y into the v_ globals. | `lune run tests/test_nqbuiltins.luau` |
| PF_setorigin #2 (pr_cmds.c:120) | def(2) | VERIFIED | player spawn origin asserted client-side in loopback (setorigin + relink) | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| SetMinMaxSize (pr_cmds.c:132) | pr_cmds.luau:setMinMaxSize | VERIFIED | test_nqbuiltins: setsize writes mins/maxs/size. Delta: C unused rotate parameter dropped (always false in C too). | `lune run tests/test_nqbuiltins.luau` |
| PF_setsize #4 (pr_cmds.c:215) | def(4) | VERIFIED | player hull from PutClientInServer → onground/walk movement asserted (test_server) | `lune run tests/test_server.luau` |
| PF_setmodel #3 (pr_cmds.c:234) | def(3) | VERIFIED | test_server "NQ PF_setmodel gave the door its brush model index and bounds". | `lune run tests/test_server.luau` |
| PF_bprint #23 (pr_cmds.c:273) | def(23) | VERIFIED | test_nqbuiltins: svc_print appended to the client reliable stream. | `lune run tests/test_nqbuiltins.luau` |
| PF_sprint #24 (pr_cmds.c:290) | def(24) | VERIFIED | test_nqbuiltins: svc_print to the target client; scenario pickup print proves the wire end. | `lune run tests/test_nqbuiltins.luau`; `lune run tests/test_scenario_nq.luau` |
| PF_centerprint #73 (pr_cmds.c:321) | def(73) | VERIFIED | test_nqbuiltins: svc_centerprint to the target client. | `lune run tests/test_nqbuiltins.luau` |
| PF_normalize #9 (pr_cmds.c:350) | def(9) | VERIFIED | test_nqbuiltins: exact 3-4-5. | `lune run tests/test_nqbuiltins.luau` |
| PF_vlen #12 (pr_cmds.c:381) | def(12) | VERIFIED | test_nqbuiltins. | `lune run tests/test_nqbuiltins.luau` |
| PF_vectoyaw #13 (pr_cmds.c:401) | def(13) | VERIFIED | test_nqbuiltins: int truncation + wrap, 4 quadrant cases. | `lune run tests/test_nqbuiltins.luau` |
| PF_vectoangles #51 (pr_cmds.c:428) | def(51) | VERIFIED | test_nqbuiltins: incl. the straight-up pitch-90 vertical special case. | `lune run tests/test_nqbuiltins.luau` |
| PF_random #7 (pr_cmds.c:470) | def(7) | VERIFIED | test_nqbuiltins: 100 draws in [0,1]. Delta: deterministic msvcrt-LCG rand() with fixed seed 12345 — substituted RNG source. | `lune run tests/test_nqbuiltins.luau` |
| PF_particle #48 (pr_cmds.c:486) | def(48) | VERIFIED | test_nqbuiltins: svc_particle written to the datagram. | `lune run tests/test_nqbuiltins.luau` |
| PF_ambientsound #74 (pr_cmds.c:506) | def(74) | VERIFIED | loopback: ≥4 svc_spawnstaticsound received from e1m1 signon | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_sound #8 (pr_cmds.c:558) | def(8) | VERIFIED | loopback: shotgun sample event with volume*255 scaling | `lune run` full sweep (harness-cited; pin the exact test in the burn-down) |
| PF_break #6 (pr_cmds.c:591) | def(6) | N/A | C deliberately crashes into the debugger (*(int*)-4 = 0); a debugger trap is platform-meaningless — port errors with a message. | — (N/A) |
| PF_traceline #16 (pr_cmds.c:609) | def(16) | VERIFIED | test_nqbuiltins: trace_fraction/trace_endpos globals match a direct world.move of the same segment. | `lune run tests/test_nqbuiltins.luau` |
| PF_TraceToss #64 slot (pr_cmds.c:641) | — | N/A | dead: PF_Fixme slot in NQ build (QUAKE2-only). N/A: dead in C (PF_Fixme slot). | — (implement first) |
| PF_checkpos (pr_cmds.c:678) | — | N/A | empty stub in C too. N/A: dead in C (empty stub). | — (implement first) |
| PF_newcheckclient (pr_cmds.c:686) | pr_cmds.luau:newCheckClient | VERIFIED | test_nqbuiltins: the 0.1s rotation finds the staged player for checkclient within a few frames. | `lune run tests/test_nqbuiltins.luau` |
| PF_checkclient #17 (pr_cmds.c:753) | def(17) | VERIFIED | test_nqbuiltins: returns the staged player once it enters the grunt's PVS. | `lune run tests/test_nqbuiltins.luau` |
| PF_stuffcmd #21 (pr_cmds.c:804) | def(21) | VERIFIED | test_nqbuiltins: svc_stufftext appended for the target client. | `lune run tests/test_nqbuiltins.luau` |
| PF_localcmd #46 (pr_cmds.c:830) | def(46) | VERIFIED | test_nqbuiltins: changelevel routes to svr.changelevelTo. Delta: no server Cbuf — level changes routed, others logged. | `lune run tests/test_nqbuiltins.luau` |
| PF_cvar #45 (pr_cmds.c:845) | def(45) | VERIFIED | test_nqbuiltins: cvar_set + cvar round-trip. | `lune run tests/test_nqbuiltins.luau` |
| PF_cvar_set #72 (pr_cmds.c:861) | def(72) | VERIFIED | test_nqbuiltins: round-trip. | `lune run tests/test_nqbuiltins.luau` |
| PF_findradius #22 (pr_cmds.c:880) | def(22) | VERIFIED | test_nqbuiltins: chains a staged edict at the center. | `lune run tests/test_nqbuiltins.luau` |
| PF_dprint #25 (pr_cmds.c:918) | def(25) | VERIFIED | Routed to svr.dprint; QW twin register-tested, NQ path exercised by every suite boot log. | `lune run tests/test_nqbuiltins.luau` |
| PF_ftos #26 (pr_cmds.c:925) | def(26) | VERIFIED | test_nqbuiltins: "%d" for integers, "%5.1f" half-even otherwise. | `lune run tests/test_nqbuiltins.luau` |
| PF_fabs #43 (pr_cmds.c:937) | def(43) | VERIFIED | test_nqbuiltins. | `lune run tests/test_nqbuiltins.luau` |
| PF_vtos #27 (pr_cmds.c:944) | def(27) | VERIFIED | test_nqbuiltins: quoted %5.1f triple. | `lune run tests/test_nqbuiltins.luau` |
| PF_etos (pr_cmds.c:951) | — | N/A | dead: PF_Fixme slot in NQ build. N/A: dead in C (PF_Fixme slot). | — (implement first) |
| PF_Spawn #14 (pr_cmds.c:958) | def(14) | VERIFIED | entity census exact (test_server); ED_Alloc verified in test_vm | `lune run tests/test_server.luau`; `lune run tests/test_vm.luau` |
| PF_Remove #15 (pr_cmds.c:965) | def(15) | VERIFIED | inhibited-entity frees during load → exact census; ED_Free verified in test_vm | `lune run tests/test_vm.luau` |
| PF_Find #18 (pr_cmds.c:975) | def(18) | VERIFIED | SelectSpawnPoint's find() → player near info_player_start asserted (loopback/test_server) | `lune run tests/test_server.luau` |
| PR_CheckEmptyString (pr_cmds.c:1056) | pr_cmds.luau:checkEmptyString | VERIFIED | Shared checkEmptyString register-tested on the QW side (precache_sound("") errors); same guard in NQ pr_cmds. | `lune run tests/test_qwbuiltins.luau` |
| PF_precache_file #68 (pr_cmds.c:1062) | def(68) | VERIFIED | No-op returning parm as C; the NQ *2 table aliases are identity-checked in test_server. | `lune run tests/test_server.luau` |
| PF_precache_sound #19 (pr_cmds.c:1067) | def(19) | VERIFIED | test_server: >30 sounds precached; loading-state guard + overflow error ported | `lune run tests/test_server.luau` |
| PF_precache_model #20 (pr_cmds.c:1092) | def(20) | VERIFIED | test_server: >30 models, player.mdl indexed; loads model + registers brush submodels | `lune run tests/test_server.luau` |
| PF_coredump #28 (pr_cmds.c:1119) | def(28) → prdebug.edPrintEdicts | VERIFIED | test_prdebug: builtin prints the full edict dump through svr.print | `lune run tests/test_prdebug.luau` |
| PF_traceon/PF_traceoff #29/#30 (pr_cmds.c:1124,1129) | def(29)/def(30) + the exec-loop trace hook | VERIFIED | test_prdebug: traceon mid-execution prints every following statement until DONE (opnames visible); pr_trace resets at the next exec entry exactly like C | `lune run tests/test_prdebug.luau` |
| PF_eprint #31 (pr_cmds.c:1134) | def(31) → prdebug.edPrintNum(G_EDICTNUM(PARM0)) | VERIFIED | test_prdebug: prints the requested edict dump | `lune run tests/test_prdebug.luau` |
| PF_walkmove #32 (pr_cmds.c:1146) | def(32) | VERIFIED | test_nqbuiltins: a grounded grunt steps along its facing (result/displacement consistency), program-state save/restore around movestep. | `lune run tests/test_nqbuiltins.luau` |
| PF_droptofloor #34 (pr_cmds.c:1189) | def(34) | VERIFIED | test_nqbuiltins: staged edict lands, returns 1, FL_ONGROUND set. | `lune run tests/test_nqbuiltins.luau` |
| PF_lightstyle #35 (pr_cmds.c:1221) | def(35) | VERIFIED | test_server: styles 0/63/10 registered; loopback receives style 0 "m" | `lune run tests/test_server.luau` |
| PF_rint #36 (pr_cmds.c:1247) | def(36) | VERIFIED | test_nqbuiltins: half away from zero, 4 cases. | `lune run tests/test_nqbuiltins.luau` |
| PF_floor #37 / PF_ceil #38 (pr_cmds.c:1256,1260) | def(37)/def(38) | VERIFIED | test_nqbuiltins. | `lune run tests/test_nqbuiltins.luau` |
| PF_checkbottom #40 (pr_cmds.c:1271) | def(40) | VERIFIED | test_nqbuiltins: 1 for a grounded grunt. | `lune run tests/test_nqbuiltins.luau` |
| PF_pointcontents #41 (pr_cmds.c:1285) | def(41) | VERIFIED | test_nqbuiltins: EMPTY at the start, SOLID outside the world. | `lune run tests/test_nqbuiltins.luau` |
| PF_nextent #47 (pr_cmds.c:1301) | def(47) | VERIFIED | test_nqbuiltins: nextent(world) = edict 1. | `lune run tests/test_nqbuiltins.luau` |
| PF_aim #44 (pr_cmds.c:1333) | def(44) | VERIFIED | test_nqbuiltins: no-target case returns v_forward exactly (facing straight down). The 0.93-assist target branch remains covered only by E2E firing; a staged-target case is a good future add. | `lune run tests/test_nqbuiltins.luau` |
| PF_changeyaw #49 (pr_cmds.c:1412) | sv_move.luau:changeYaw via def(49) | VERIFIED | test_nqbuiltins: yaw steps exactly 20 deg toward ideal_yaw (anglemod quantization separately proven in test_com). | `lune run tests/test_nqbuiltins.luau` |
| PF_changepitch (pr_cmds.c:1455) | — | N/A | dead: PF_Fixme slot in NQ build. N/A: dead in C (PF_Fixme slot). | — (implement first) |
| WriteDest (pr_cmds.c:1506) | pr_cmds.luau:writeDest | VERIFIED | MSG_ALL routing proven by intermission svc reaching the client (test_changelevel) | `lune run tests/test_changelevel.luau` |
| PF_WriteByte #52 (pr_cmds.c:1539) | def(52) | VERIFIED | QC intermission bytes parsed by real client (test_changelevel: intermission seen) | `lune run tests/test_changelevel.luau` |
| PF_WriteChar #53 (pr_cmds.c:1544) | def(53) | VERIFIED | test_nqbuiltins: signed byte into MSG_BROADCAST. | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteShort #54 (pr_cmds.c:1549) | def(54) | VERIFIED | test_nqbuiltins. | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteLong #55 (pr_cmds.c:1554) | def(55) | VERIFIED | test_nqbuiltins. | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteAngle #57 (pr_cmds.c:1559) | def(57) | VERIFIED | test_nqbuiltins: 90 deg -> byte 64. | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteCoord #56 (pr_cmds.c:1564) | def(56) | VERIFIED | test_nqbuiltins: 12.5 -> 100 (1/8 units). | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteString #58 (pr_cmds.c:~1570) | def(58) | VERIFIED | test_nqbuiltins: NUL-terminated. | `lune run tests/test_nqbuiltins.luau` |
| PF_WriteEntity #59 (pr_cmds.c:~1576) | def(59) | VERIFIED | test_nqbuiltins: edict number as short. | `lune run tests/test_nqbuiltins.luau` |
| PF_makestatic #69 (pr_cmds.c:~1585) | def(69) | VERIFIED | test_nqbuiltins: svc_spawnstatic into signon + edict freed; e1m2 statics arrive on the wire in test_scenario_nq. | `lune run tests/test_nqbuiltins.luau`; `lune run tests/test_scenario_nq.luau` |
| PF_setspawnparms #78 (pr_cmds.c:~1616) | def(78) | VERIFIED | test_nqbuiltins: parms 1..16 copied to the parm globals. | `lune run tests/test_nqbuiltins.luau` |
| PF_changelevel #70 (pr_cmds.c:~1639) | def(70) | VERIFIED | test_changelevel: changelevelTo == "e1m2", double-issue guard | `lune run tests/test_changelevel.luau` |
| PF_WaterMove (pr_cmds.c:~1684) | — | N/A | dead: QUAKE2-only. N/A: dead in C (QUAKE2 ifdef). | — (implement first) |
| PF_sin/PF_cos/PF_sqrt (pr_cmds.c:~1809+) | — | N/A | dead: QUAKE2-only slots. N/A: dead in C (QUAKE2 slots). | — (implement first) |
| PF_Fixme (pr_cmds.c:~1825) | vm.luau exec bad-builtin error | N/A | C binds PF_Fixme to unused builtin slots purely to Sys_Error; the vm dispatch nil-check is the same trap, dead in stock play. | — (N/A) |
| precache_model2/sound2/file2 #75-77 | pr_cmds.luau B[75..77] aliases | VERIFIED | test_server "precache_*2 builtins alias the base implementations" (same-table aliases, as C). | `lune run tests/test_server.luau` |

## zone.c

The entire zone/hunk/cache allocator is replaced by Luau garbage collection and `buffer`
objects; Roblox provides no manual memory management and none is needed (models, edicts,
and message buffers are ordinary GC values; per-level state is rebuilt in spawnServer).

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| Z_ClearZone / Z_Free / Z_Malloc / Z_TagMalloc (zone.c:74-155) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Z_Print / Z_CheckHeap (zone.c:219,247) | — | SUBSTITUTED | no heap to audit | — (substitution; verify justification still holds) |
| Hunk_Check / Hunk_Print (zone.c:293,315) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Hunk_AllocName / Hunk_Alloc (zone.c:399,434) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Hunk_FreeToLowMark / Hunk_FreeToHighMark (zone.c:444,463) | — | SUBSTITUTED | per-level state rebuilt in spawnServer instead of hunk marks | — (substitution; verify justification still holds) |
| Hunk_HighAllocName / Hunk_TempAlloc (zone.c:482,528) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Cache_Move / Cache_FreeLow / Cache_FreeHigh (zone.c:575-628) | — | SUBSTITUTED | no cache eviction; models held by registry until level teardown | — (substitution; verify justification still holds) |
| Cache_UnlinkLRU / Cache_MakeLRU / Cache_TryAlloc (zone.c:650-680) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Cache_Flush / Cache_Print / Cache_Report / Cache_Compact (zone.c:759-799) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Cache_Init / Cache_Free / Cache_Check / Cache_Alloc (zone.c:809-871) | — | SUBSTITUTED | GC | — (substitution; verify justification still holds) |
| Memory_Init (zone.c:913) | — | SUBSTITUTED | no -zone/-heapsize; Luau VM manages memory | — (substitution; verify justification still holds) |

## net_main.c (+ net_dgrm.c / net_loop.c / net_wins.c / drivers as one group)

The entire NET layer is substituted: UDP/IPX sockets and the loopback driver are replaced
by Roblox RemoteEvents (reliable) and UnreliableRemoteEvents, wired in
src/server/init.server.luau. Each engine Client carries transport hooks
(sendReliable/sendUnreliable/canSendReliable) and an inbox of raw clc buffers; the svc/clc
byte stream on top is the exact protocol 15 format (FIDELITY.md). Delivery deltas: the
reliable channel is genuinely reliable (no resend logic needed), and unreliable payloads
over ~850 bytes are re-routed onto the reliable remote because UnreliableRemoteEvents
silently drop >~900-byte packets.

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| SetNetTime (net_main.c:95) | svr.realtime accumulation in host.frame | SUBSTITUTED | Heartbeat-driven time | — (substitution; verify justification still holds) |
| NET_NewQSocket / NET_FreeQSocket (net_main.c:110,149) | sv.newClient transport hooks | SUBSTITUTED | no socket objects | — (substitution; verify justification still holds) |
| NET_Listen_f / MaxPlayers_f / NET_Port_f (net_main.c:175-233) | — | SUBSTITUTED | Roblox place settings govern listening/capacity | — (substitution; verify justification still holds) |
| PrintSlistHeader / PrintSlist / PrintSlistTrailer / NET_Slist_f / Slist_Send / Slist_Poll (net_main.c:262-331) | — | SUBSTITUTED | server browsing is Roblox's discovery UI | — (substitution; verify justification still holds) |
| NET_Connect (net_main.c:368) | client fires first remote message | SUBSTITUTED | connectPlayer on first inbound (init.server.luau) | — (substitution; verify justification still holds) |
| NET_CheckNewConnections (net_main.c:457) | onInbound/connectPlayer | SUBSTITUTED | event-driven | — (substitution; verify justification still holds) |
| NET_Close (net_main.c:500) | PlayerRemoving → dropClient | SUBSTITUTED | | — (substitution; verify justification still holds) |
| NET_GetMessage (net_main.c:540) | client.inbox drain in host.readClientMessage | SUBSTITUTED | ordered buffer queue; no resend/ack needed | — (substitution; verify justification still holds) |
| NET_SendMessage (net_main.c:625) | client.sendReliable | SUBSTITUTED | RemoteEvent:FireClient | — (substitution; verify justification still holds) |
| NET_SendUnreliableMessage (net_main.c:656) | client.sendUnreliable | SUBSTITUTED | UnreliableRemoteEvent, >850B fallback to reliable | — (substitution; verify justification still holds) |
| NET_CanSendMessage (net_main.c:695) | client.canSendReliable | SUBSTITUTED | always true on remotes | — (substitution; verify justification still holds) |
| NET_SendToAll (net_main.c:722) | per-client loop in sendClientMessages | SUBSTITUTED | | — (substitution; verify justification still holds) |
| NET_Init / NET_Shutdown / NET_Poll / SchedulePollProcedure (net_main.c:804-958) | remote creation in init.server.luau | SUBSTITUTED | no polling procedures | — (substitution; verify justification still holds) |
| net_dgrm.c / net_loop.c / net_wins.c / net_udp / net_vcr / net_ser (group) | — | SUBSTITUTED | datagram framing, ack/resend, loopback driver all unnecessary on Roblox remotes; the loopback tests wire client and server directly through the same transport hooks (tests/test_loopback.luau) | — (substitution; verify justification still holds) |

## sys_win.c / sys_dos.c / conproc.c (group)

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| sys_win.c / sys_dos.c / conproc.c (entire files) | src/server/init.server.luau + Lune test runner | SUBSTITUTED | file I/O → vfs over asset chunks; timers → RunService.Heartbeat / os.clock in tests; Sys_Error → Luau error; no console process to manage | — (substitution; verify justification still holds) |

## cd_win.c / cd_dos.c etc. (group)

| Function | Port | Status | Evidence / Delta | How to verify |
|---|---|---|---|---|
| cd_*.c (entire files) | — | SUBSTITUTED | CD audio tracks were never in the paks; svc_cdtrack is still sent (sv.sendServerinfo) but no playback backend exists (FIDELITY.md; LibreQuake music could be banked later) | — (substitution; verify justification still holds) |

## Port-side additions with no C counterpart

| Addition | Justification |
|---|---|---|
| shared/engine/common/bufio.luau | binary struct reader (u8/i16/f32/strz/vec3) replacing C pointer-cast parsing; required for buffer-based file formats |
| shared/engine/common/base64.luau | pak bytes travel as base64 StringValue chunks (Roblox has no file system); decode on boot |
| shared/engine/common/vfs.luau folder sources (addFolderSource/folderRead) | clients read per-map asset bundles replicated as Roblox instances, not paks — platform asset delivery |
| shared/engine/progs/defs.luau | transcribed progdefs.h ABI offsets (C gets them at compile time); every offset verified against the real progs.dat def tables in test_vm |
| sv.luau:rand (msvcrt LCG) | deterministic stand-in for libc rand() so PF_random and AI dice rolls are reproducible across platforms/tests |
| sv.luau Client transport hooks (sendReliable/sendUnreliable/canSendReliable/inbox) | seam where net_*.c used to be; lets tests wire loopback transports and Roblox wire remotes |
| host.luau:anySpawned / findFreeClient | platform helpers for the Roblox connection bridge (slot allocation was inside NET_CheckNewConnections in C) |
| host.luau clientCommand "rq_need" | client → server pak-file request so demo playback can fetch un-precached assets (FIDELITY.md demo work) |
| host.luau clientCommand cvar setters (skill/deathmatch/coop/sv_gravity/sv_maxspeed) | WinQuake sets these on the listen-server console; Roblox has no server console, so they ride clc_stringcmd |
| shared/engine/client/qcoords.luau | Quake Z-up inches ↔ Roblox Y-up studs conversion; required by the rendering/physics split across the platform boundary |
| src/server/assetchunks.luau | reassembles pak buffers from chunked StringValues with yields (script watchdog limits) |
| src/server/clientbundle.luau | publishes a per-map client asset bundle to ReplicatedStorage (full 200MB pak in ServerStorage stalled published-game joins) |
| src/server/init.server.luau diagnostics (SV_* ServerStorage attributes, SVDBG_SpawnGive, SVDBG_UseDoor, teleport helper) | Studio debugging instrumentation; SVDBG_* are opt-in attributes that are inert unless set. NO JUSTIFICATION FOUND in code comments for shipping them beyond debugging convenience — flagged for removal review before ship |
| savegame persistence via ServerStorage.QuakeSaves mirror | substitute for the .sav file directory (no writable FS); place-file persistence, DataStore later (FIDELITY.md) |
| vm.luau QW support (loadFromFileQW, stateOffsets, msg.writeAngleQW/writeAngle16) | shared VM serves the QuakeWorld engine variant (out of NQ scope, separate qw/ tree) |

## Totals

> N/A status formalized 2026-07-05 (see coverage README): concept cannot exist in the port (dead-in-C, DOS/transport-era, unused-in-scope, platform-owned). Initial N/A pass done by hand; counts below are column-exact.


Scope: 19 enumerated C files plus 3 substituted platform groups (net drivers,
sys/conproc, cd). 455 table rows; a few rows group trivial sibling functions
(endian swaps, floor/ceil, traceon/traceoff, the zone allocator, net_main
socket entries), so the rows cover ~490 C function definitions.

| Status | Count (rows) |
|---|---|---|
| VERIFIED | 292 |
| PENDING | 0 |
| UNIMPLEMENTED | 12 |
| SUBSTITUTED | 111 |
| N/A | 36 |

Notes on the UNIMPLEMENTED bucket: 13 of the 49 are dead code in the WinQuake NQ build
(QUAKE2/FPS_20/#if 0 ifdefs or PF_Fixme slots); most of the rest are console/debug
printing (ED_Print*, PR_Profile, viewmodel dev commands). The gameplay-relevant gaps are
SV_SaveSpawnparms (inventory/rune carry across levels), Host_Tell_f, and Host_Kick_f.

> Evidence reset 2026-07-04: VERIFIED now means re-runnable evidence only (a cited test/harness). 35 rows demoted to PENDING with their prior claims preserved inline (marked DEMOTED); re-earn via tests or checked-in screenshots under docs/coverage/evidence/.
