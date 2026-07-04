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

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ClearLink (common.c:104) | shared/engine/server/world.luau:newSentinel | VERIFIED | transliteration compared; exercised by every linkEdict in test_server/test_loopback (entity visibility asserted) |
| RemoveLink (common.c:109) | world.luau:removeLink | VERIFIED | same as above |
| InsertLinkBefore (common.c:115) | world.luau:insertLinkBefore | VERIFIED | same as above |
| InsertLinkAfter (common.c:122) | — | UNIMPLEMENTED | unused by the C server paths in scope |
| Q_memset (common.c:138) | — | SUBSTITUTED | Luau `buffer.fill` / table ops; no raw memory on Roblox |
| Q_memcpy (common.c:154) | — | SUBSTITUTED | `buffer.copy` |
| Q_memcmp (common.c:169) | — | SUBSTITUTED | Luau `==` on strings/buffers |
| Q_strcpy (common.c:180) | — | SUBSTITUTED | Luau immutable strings |
| Q_strncpy (common.c:189) | — | SUBSTITUTED | `string.sub` |
| Q_strlen (common.c:199) | — | SUBSTITUTED | `#s` |
| Q_strrchr (common.c:210) | — | SUBSTITUTED | `string.match` patterns |
| Q_strcat (common.c:219) | — | SUBSTITUTED | `..` |
| Q_strcmp (common.c:225) | — | SUBSTITUTED | `==` |
| Q_strncmp (common.c:240) | — | SUBSTITUTED | `string.sub` compare |
| Q_strncasecmp (common.c:257) | — | SUBSTITUTED | `string.lower` compare |
| Q_strcasecmp (common.c:287) | — | SUBSTITUTED | `string.lower` compare |
| Q_atoi (common.c:292) | shared/engine/common/com.luau:atoi | PENDING | decimal path exercised via parseEdict in test_vm; hex `0x` / char `'x'` paths untested |
| Q_atof (common.c:351) | com.luau:atof | PENDING | decimal path exercised (test_vm parsed origin `480 -352 88`); hex/char paths untested |
| ShortSwap/ShortNoSwap (common.c:443,453) | — | SUBSTITUTED | Luau `buffer` API is little-endian, matching Quake's on-disk/wire format; no swapping needed |
| LongSwap/LongNoSwap (common.c:458,470) | — | SUBSTITUTED | same |
| FloatSwap/FloatNoSwap (common.c:475,492) | — | SUBSTITUTED | same |
| MSG_WriteChar (common.c:510) | shared/engine/common/msg.luau:writeChar | VERIFIED | full protocol loopback: test_loopback/test_server parse server-written streams with the real client parser |
| MSG_WriteByte (common.c:523) | msg.luau:writeByte | VERIFIED | test_server: datagram starts with svc_time; loopback signon parses |
| MSG_WriteShort (common.c:536) | msg.luau:writeShort | VERIFIED | clc_move forward=400 drives asserted movement (test_server "player ran forward") |
| MSG_WriteLong (common.c:550) | msg.luau:writeLong | VERIFIED | svc_updatestat longs → loopback stats asserted |
| MSG_WriteFloat (common.c:561) | msg.luau:writeFloat | VERIFIED | test_server: svc_time float read back within tolerance |
| MSG_WriteString (common.c:576) | msg.luau:writeString | VERIFIED | loopback levelname/precache strings asserted |
| MSG_WriteCoord (common.c:584) | msg.luau:writeCoord | VERIFIED | loopback: player origin via entity updates near (480,-352,88); coord = short of f*8 |
| MSG_WriteAngle (common.c:589) | msg.luau:writeAngle | VERIFIED | test_server: angle 90 in clc_move → northward motion asserted |
| MSG_BeginReading (common.c:600) | msg.luau:reader | VERIFIED | reader object replaces global read state; all message tests |
| MSG_ReadChar (common.c:607) | msg.luau:readChar | VERIFIED | host readClientMessage cmd loop (all E2E tests); -1 on end-of-message preserved |
| MSG_ReadByte (common.c:623) | msg.luau:readByte | VERIFIED | clc parsing in all E2E tests |
| MSG_ReadShort (common.c:639) | msg.luau:readShort | VERIFIED | clc_move fields drive asserted movement |
| MSG_ReadLong (common.c:657) | msg.luau:readLong | VERIFIED | protocol version in serverinfo (loopback signon completes) |
| MSG_ReadFloat (common.c:677) | msg.luau:readFloat | VERIFIED | clc_move ping time consumed; svc_time |
| MSG_ReadString (common.c:697) | msg.luau:readString | VERIFIED | clc_stringcmd dispatch in every E2E test |
| MSG_ReadCoord (common.c:717) | msg.luau:readCoord | VERIFIED | client entity origins asserted in loopback |
| MSG_ReadAngle (common.c:722) | msg.luau:readAngle | VERIFIED | v_angle from clc_move → movement matches |
| SZ_Alloc (common.c:731) | msg.luau:newBuf | VERIFIED | all server buffers (datagram/reliable/signon) built on it |
| SZ_Free (common.c:741) | — | SUBSTITUTED | GC |
| SZ_Clear (common.c:749) | msg.luau:clear | VERIFIED | per-frame datagram clear; signon reset in spawnServer (tests assert fresh state per level) |
| SZ_GetSpace (common.c:754) | msg.luau:getSpace | PENDING | overflow/allowoverflow branch never asserted by a test |
| SZ_Write (common.c:777) | msg.luau:writeBuf | VERIFIED | signon copy into prespawn reply → baselines received in loopback |
| SZ_Print (common.c:782) | — | UNIMPLEMENTED | NUL-splicing string append not needed; strings built in Luau |
| COM_SkipPath (common.c:804) | — | SUBSTITUTED | inline Luau string patterns where needed |
| COM_StripExtension (common.c:823) | — | SUBSTITUTED | inline patterns (e.g. savegame.write `maps/(.+)%.bsp`) |
| COM_FileExtension (common.c:835) | — | SUBSTITUTED | inline patterns |
| COM_FileBase (common.c:856) | — | SUBSTITUTED | inline patterns |
| COM_DefaultExtension (common.c:884) | — | SUBSTITUTED | callers pass full names |
| COM_Parse (common.c:911) | com.luau:parse | VERIFIED | test_vm: 5 explicit checks (brace/quoted key/value/close/eof); savegame round-trip reparses full entity text |
| COM_CheckParm (common.c:990) | — | SUBSTITUTED | no argv on Roblox; config via Instance attributes (init.server.luau) |
| COM_CheckRegistered (common.c:1015) | server/host.luau:newGame (gfx/pop.lmp probe) | PENDING | sets `registered` cvar only; no com_registered global / cmdline check |
| COM_InitArgv (common.c:1057) | — | SUBSTITUTED | no command line on the platform |
| COM_Init (common.c:1125) | — | SUBSTITUTED | endianness moot; init in bootstrap |
| va (common.c:1169) | — | SUBSTITUTED | Luau string interpolation |
| memsearch (common.c:1183) | — | UNIMPLEMENTED | unused |
| COM_Path_f (common.c:1258) | — | UNIMPLEMENTED | debug console command |
| COM_WriteFile (common.c:1281) | — | SUBSTITUTED | no writable filesystem; saves persist via ServerStorage.QuakeSaves (init.server.luau) |
| COM_CreatePath (common.c:1308) | — | SUBSTITUTED | same |
| COM_CopyFile (common.c:1332) | — | SUBSTITUTED | same |
| COM_FindFile (common.c:1365) | common/vfs.luau:findFile | VERIFIED | test_pak: known file lengths through pak search + missing file returns -1 |
| COM_OpenFile (common.c:1485) | — | SUBSTITUTED | no file handles; whole-buffer loads |
| COM_FOpenFile (common.c:1498) | — | SUBSTITUTED | same |
| COM_CloseFile (common.c:1510) | — | SUBSTITUTED | same |
| COM_LoadFile (common.c:1533) | vfs.luau:loadFile | VERIFIED | test_pak/test_bsp/test_vm/test_wad all load real pak contents through it |
| COM_LoadHunkFile (common.c:1581) | — | SUBSTITUTED | hunk allocator replaced by GC; loadFile only |
| COM_LoadTempFile (common.c:1586) | — | SUBSTITUTED | same |
| COM_LoadCacheFile (common.c:1591) | — | SUBSTITUTED | same |
| COM_LoadStackFile (common.c:1598) | — | SUBSTITUTED | same |
| COM_LoadPackFile (common.c:1619) | common/pak.luau:load | VERIFIED | test_pak: 339 entries, lengths cross-checked vs independent Python parse |
| COM_AddGameDirectory (common.c:1689) | vfs.luau:addPack + init.server.luau pak loop | PENDING | fixed pak0/pak1 only (no pak2+ scan); loose files come from a Roblox folder source instead of a dir |
| COM_InitFilesystem (common.c:1732) | src/server/init.server.luau | SUBSTITUTED | paks reassembled from base64 asset chunks (no filesystem); -basedir/-game via folder attributes |

## mathlib.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ProjectPointOnPlane (mathlib.c:34) | — | UNIMPLEMENTED | used only by client-side code in C |
| PerpendicularVector (mathlib.c:56) | — | UNIMPLEMENTED | client-side only |
| RotatePointAroundVector (mathlib.c:93) | — | UNIMPLEMENTED | client-side only |
| anglemod (mathlib.c:155) | common/mathlib.luau:anglemod | PENDING | 360/65536 quantization preserved; exercised by monster turning in test_server but never directly asserted |
| BOPS_Error (mathlib.c:174) | — | UNIMPLEMENTED | error stub for the assembly path |
| BoxOnPlaneSide (mathlib.c:189) | mathlib.luau:boxOnPlaneSide | VERIFIED | side-by-side transliteration (incl. axial fast path + 8 signbits cases, `>=`/`<` semantics); exercised via findTouchedLeafs → PVS visibility assertions in test_loopback |
| AngleVectors (mathlib.c:292) | mathlib.luau:angleVectors | VERIFIED | test_movement: v_angle → wishdir chain matches compiled C within 0.0002 units over 300 ticks |
| VectorCompare (mathlib.c:318) | — | SUBSTITUTED | native `vector` equality |
| VectorMA (mathlib.c:329) | — | SUBSTITUTED | native vector arithmetic |
| _DotProduct (mathlib.c:337) | — | SUBSTITUTED | `vector.dot` |
| _VectorSubtract (mathlib.c:342) | — | SUBSTITUTED | native `-` |
| _VectorAdd (mathlib.c:349) | — | SUBSTITUTED | native `+` |
| _VectorCopy (mathlib.c:356) | — | SUBSTITUTED | value semantics |
| CrossProduct (mathlib.c:363) | — | SUBSTITUTED | `vector.cross` |
| Length (mathlib.c:372) | — | SUBSTITUTED | `vector.magnitude` |
| VectorNormalize (mathlib.c:385) | mathlib.luau:normalize | VERIFIED | returns (unit, length) like C; in the matched movement chain (test_movement) |
| VectorInverse (mathlib.c:404) | — | SUBSTITUTED | unary `-` |
| VectorScale (mathlib.c:411) | — | SUBSTITUTED | `*` |
| Q_log2 (mathlib.c:419) | — | UNIMPLEMENTED | unused server-side |
| R_ConcatRotations (mathlib.c:433) | — | UNIMPLEMENTED | renderer helper; software rasterizer substituted wholesale (FIDELITY.md) |
| R_ConcatTransforms (mathlib.c:461) | — | UNIMPLEMENTED | renderer helper |
| FloorDivMod (mathlib.c:500) | — | UNIMPLEMENTED | software-rasterizer fixed-point helper |
| GreatestCommonDivisor (mathlib.c:547) | — | UNIMPLEMENTED | same |
| Invert24To16 (mathlib.c:576) | — | UNIMPLEMENTED | same |

## cvar.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Cvar_FindVar (cvar.c:32) | common/cvar.luau (vars table lookup) | PENDING | hash lookup replaces linked list; behavior trivially equivalent, untested directly |
| Cvar_VariableValue (cvar.c:48) | cvar.luau:value | VERIFIED | sv_friction/sv_gravity/etc. feed the movement chain matched against compiled C (test_movement) |
| Cvar_VariableString (cvar.c:64) | cvar.luau:string | PENDING | no test reads string form |
| Cvar_CompleteVariable (cvar.c:80) | — | UNIMPLEMENTED | console tab-completion (client UI nicety) |
| Cvar_Set (cvar.c:104) | cvar.luau:set | PENDING | delta: `tonumber` instead of Q_atof; C's server-broadcast-on-change branch absent |
| Cvar_SetValue (cvar.c:135) | cvar.luau:setValue | VERIFIED | test_multiplayer sets coop=1 → QC coop behavior asserted (instant respawn, -2 frag suicide) |
| Cvar_RegisterVariable (cvar.c:151) | cvar.luau DEFAULTS table | SUBSTITUTED | static default table instead of dynamic registration; no engine code registers at runtime |
| Cvar_WriteVariables (cvar.c:216) | — | SUBSTITUTED | no writable config.cfg on Roblox (FIDELITY.md platform substitutions) |

## cmd.c

The command buffer / alias / bind machinery lives client-side in the port
(src/client/init.client.luau:366-620 "keys.c: bindings, and cmd.c: alias/exec/wait" and
src/client/console.luau) because Roblox has no server console; the server receives only
clc_stringcmd. FIDELITY.md records manual verification (W→forwardmove 200 over the wire,
F11 zoom chain) but there is no offline test.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Cmd_Wait_f (cmd.c:53) | client/init.client.luau ("wait" in execCommand) | PENDING | defers remainder to next frame via cbufDeferred; manual verification only |
| Cbuf_Init (cmd.c:73) | init.client.luau cbufDeferred/cbufWait state | PENDING | no 8KB sizebuf; unbounded Luau queue |
| Cbuf_AddText (cmd.c:86) | init.client.luau:execLine | PENDING | executes immediately unless waiting (C queues); ordering equivalent for the port's callers |
| Cbuf_InsertText (cmd.c:111) | init.client.luau cbufDeferred | PENDING | |
| Cbuf_Execute (cmd.c:143) | init.client.luau:execLine + cbufFrame | PENDING | quote-protected semicolon splitting per FIDELITY.md; manual verification |
| Cmd_StuffCmds_f (cmd.c:213) | — | SUBSTITUTED | no command line to stuff on Roblox |
| Cmd_Exec_f (cmd.c:283) | init.client.luau "exec" | PENDING | execs default.cfg from pak at boot + autoexec.cfg (FIDELITY.md) |
| Cmd_Echo_f (cmd.c:315) | init.client.luau "echo" | PENDING | |
| CopyString (cmd.c:332) | — | SUBSTITUTED | GC strings |
| Cmd_Alias_f (cmd.c:341) | init.client.luau "alias" + aliases table | PENDING | |
| Cmd_Init (cmd.c:428) | init.client.luau:execCommand dispatcher | SUBSTITUTED | if-chain dispatch instead of registered command table |
| Cmd_Argc (cmd.c:446) | init.client.luau:tokenize result | SUBSTITUTED | token array |
| Cmd_Argv (cmd.c:456) | tokenize result | SUBSTITUTED | |
| Cmd_Args (cmd.c:468) | tokenize / table.concat | SUBSTITUTED | |
| Cmd_TokenizeString (cmd.c:481) | init.client.luau:tokenize | PENDING | quoted strings + // comments handled |
| Cmd_AddCommand (cmd.c:532) | — | SUBSTITUTED | dispatcher if-chain |
| Cmd_Exists (cmd.c:568) | — | SUBSTITUTED | same |
| Cmd_CompleteCommand (cmd.c:588) | — | UNIMPLEMENTED | console tab-completion |
| Cmd_ExecuteString (cmd.c:614) | init.client.luau:execCommand | PENDING | commands → aliases → cvars → forward order preserved in spirit |
| Cmd_ForwardToServer (cmd.c:660) | client console → clc_stringcmd forward | PENDING | console.luau: "everything else forwarded to the server like Cmd_ForwardToServer" |
| Cmd_CheckParm (cmd.c:693) | — | UNIMPLEMENTED | unused |

## crc.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| CRC_Init (crc.c:68) | common/com.luau:crcBuffer | VERIFIED | folded into one function; test_vm: progs.dat CRC16 == 46133 vs independent Python parse |
| CRC_ProcessByte (crc.c:73) | com.luau:crcBuffer | VERIFIED | same |
| CRC_Value (crc.c:78) | com.luau:crcBuffer | VERIFIED | same |

## wad.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| W_CleanupName (wad.c:41) | gfx/wad.luau:cleanupName | VERIFIED | test_wad: 8 known lumps found by name (lowercasing path) |
| W_LoadWadFile (wad.c:68) | wad.luau:load | VERIFIED | test_wad against real gfx.wad (WAD2 magic, lump dir) |
| W_GetLumpName (wad.c:125) | wad.luau:getLump / getPic | VERIFIED | test_wad: conchars/sbar/num_* present, qpic dims asserted |
| W_GetLumpNum (wad.c:134) | — | UNIMPLEMENTED | port looks up by name only |
| SwapPic (wad.c:154) | — | SUBSTITUTED | little-endian buffer reads; no swap needed |

## model.c

Split in the port: brush → bsp/bsp.luau, alias → models/mdl.luau, sprite → models/spr.luau,
registry → models/models.luau. Ground truth: tools/dump_bsp_truth.py + independent Python
parses (test_bsp/test_models headers).

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Mod_Init (model.c:52) | models/models.luau:newRegistry | SUBSTITUTED | table registry; no mod_novis buffer |
| Mod_Extradata (model.c:64) | — | SUBSTITUTED | no cache allocator; models stay referenced |
| Mod_PointInLeaf (model.c:84) | bsp/bsp.luau:pointInLeaf | VERIFIED | test_bsp: spawn leaf CONTENTS_EMPTY, far point → leaf 0 solid |
| Mod_DecompressVis (model.c:115) | bsp.luau:leafPVS (RLE decode) | VERIFIED | test_bsp: PVS row size, self-visibility bit, solid leaf all-0xff |
| Mod_LeafPVS (model.c:155) | bsp.luau:leafPVS | VERIFIED | same; also drives loopback entity-visibility assertions |
| Mod_ClearAll (model.c:167) | — | SUBSTITUTED | fresh registry per spawnServer; GC frees |
| Mod_FindName (model.c:186) | models.luau:forName (cache table) | PENDING | no LRU/needload machinery; name→model table |
| Mod_TouchModel (model.c:236) | — | SUBSTITUTED | no cache to touch |
| Mod_LoadModel (model.c:256) | models.luau:forName (dispatch on magic) | PENDING | dispatch by IDPO/IDSP/BSP version; loaders individually verified below |
| Mod_ForName (model.c:329) | models.luau:forName | PENDING | exercised by test_server precache (`models precached`), no direct assertions |
| Mod_LoadTextures (model.c:355) | bsp.luau:loadTextures | VERIFIED | test_bsp: 81 miptex, names, mip chain size, +anim sequence linking |
| Mod_LoadLighting (model.c:504) | bsp.luau:loadBlob | VERIFIED | test_bsp: 168590 light bytes |
| Mod_LoadVisibility (model.c:521) | bsp.luau:loadBlob | VERIFIED | test_bsp: 40843 vis bytes |
| Mod_LoadEntities (model.c:538) | bsp.luau (entities lump as string) | VERIFIED | test_bsp: worldspawn + player start found in lump |
| Mod_LoadVertexes (model.c:555) | bsp.luau:loadVertexes | VERIFIED | test_bsp: vert500 exact |
| Mod_LoadSubmodels (model.c:583) | bsp.luau:loadSubmodels | VERIFIED | test_bsp: 58 models, submodel hull heads exact |
| Mod_LoadEdges (model.c:619) | bsp.luau:loadEdges | VERIFIED | test_bsp face extents depend on edges; 3 faces detail-checked |
| Mod_LoadTexinfo (model.c:646) | bsp.luau:loadTexinfo | VERIFIED | test_bsp: face texinfo indices asserted |
| CalcSurfaceExtents (model.c:714) | bsp.luau:calcSurfaceExtents | VERIFIED | test_bsp: texturemins/extents exact on faces 0/1000/2000 |
| Mod_LoadFaces (model.c:766) | bsp.luau:loadFaces | VERIFIED | test_bsp: plane/side/edges/styles/lightofs exact |
| Mod_SetParent (model.c:836) | — | UNIMPLEMENTED | port navigates the tree top-down (pointInLeaf/PVS); parent links only needed by the C renderer's R_MarkLeaves |
| Mod_LoadNodes (model.c:850) | bsp.luau:loadNodes | VERIFIED | test_bsp: node200 planenum/children exact |
| Mod_LoadLeafs (model.c:897) | bsp.luau:loadLeafs | VERIFIED | test_bsp: leaf100 contents/visofs exact |
| Mod_LoadClipnodes (model.c:944) | bsp.luau:loadClipnodes | VERIFIED | test_bsp: clipnode300 exact + hull1/hull2 heads, clip_mins/maxs |
| Mod_MakeHull0 (model.c:998) | bsp.luau:makeHull0 | VERIFIED | test_bsp: full hull0 child-range sweep; test_trace hull 0 traces vs C |
| Mod_LoadMarksurfaces (model.c:1035) | bsp.luau:loadMarksurfaces | PENDING | loaded; consumed by client renderer, no offline assertion |
| Mod_LoadSurfedges (model.c:1064) | bsp.luau:loadSurfedges | VERIFIED | face extents math depends on it (asserted) |
| Mod_LoadPlanes (model.c:1087) | bsp.luau:loadPlanes | VERIFIED | test_bsp: plane100 normal/dist/type/signbits exact |
| RadiusFromBounds (model.c:1125) | bsp.luau:radiusFromBounds | PENDING | no assertion on radius |
| Mod_LoadBrushModel (model.c:1143) | bsp.luau:load | VERIFIED | test_bsp: 58 models, world mins/maxs (incl. the ±1 spread quirk), every map in pak0 loads |
| Mod_LoadAliasFrame (model.c:1235) | models/mdl.luau:loadFrame | VERIFIED | test_models: frame names, bboxmin/max, vert unpack vs scale/scale_origin |
| Mod_LoadAliasGroup (model.c:1283) | mdl.luau:load (group branch) | VERIFIED | test_models: all 61 pak0 mdls load (includes grouped flame*.mdl); frames[i].frames[] structure |
| Mod_LoadAliasSkin (model.c:1348) | mdl.luau:load (skin branch) | VERIFIED | test_models: player skin 296x194 byte count |
| Mod_LoadAliasSkinGroup (model.c:1387) | mdl.luau:load (skin group branch) | VERIFIED | test_models: armor 3 skins |
| Mod_LoadAliasModel (model.c:1442) | mdl.luau:load | VERIFIED | test_models: header fields (verts/tris/frames/synctype/flags/radius/size ratio) vs Python parse |
| Mod_LoadSpriteFrame (model.c:1669) | models/spr.luau:loadFrame | VERIFIED | test_models: s_explod frame origin/size/pixels exact |
| Mod_LoadSpriteGroup (model.c:1726) | spr.luau:load (group branch) | VERIFIED | test_models: grouped sprites load (s_bubble/s_light) |
| Mod_LoadSpriteModel (model.c:1778) | spr.luau:load | VERIFIED | test_models: type/maxwidth/numframes |
| Mod_Print (model.c:1857) | — | UNIMPLEMENTED | debug console command |

## world.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_InitBoxHull (world.c:68) | server/world.luau:initBoxHull | PENDING | transliterated (6 planes/clipnodes); box-hull traces only exercised indirectly (entity-vs-entity clipping in E2E tests) |
| SV_HullForEntity (world.c:129) | world.luau:hullForEntity | VERIFIED | SOLID_BSP hull-select + offset path matched vs compiled C over 300 ticks (test_movement); box path exercised only via E2E |
| SV_CreateAreaNode (world.c:202) | world.luau:createAreaNode | PENDING | 4-deep axis-alternating split transliterated; no direct assertion |
| SV_ClearWorld (world.c:247) | world.luau:new | PENDING | per-level world reconstruction (fresh areanodes) |
| SV_UnlinkEdict (world.c:263) | world.luau:unlinkEdict | PENDING | called from ED_Free/linkEdict; unasserted |
| SV_TouchLinks (world.c:277) | world.luau:touchLinks | PENDING | trigger touch dispatch (self/other/time swap preserved); test_changelevel fires the trigger manually, so this path lacks assertions |
| SV_FindTouchedLeafs (world.c:328) | world.luau:findTouchedLeafs | VERIFIED | leafnums feed SV_WriteEntitiesToClient PVS culling → test_loopback entity-visibility assertions (player visible, ≥4 after moving) |
| SV_LinkEdict (world.c:372) | world.luau:linkEdict | VERIFIED | absmin/absmax incl. FL_ITEM ±15 expansion compared side-by-side; drives verified movement + visibility tests |
| SV_HullPointContents (world.c:491) | world.luau:hullPointContents | VERIFIED | test_trace: 200 points x 3 hulls exact vs tools/trace_truth.c |
| SV_PointContents (world.c:527) | world.luau:pointContents | VERIFIED | in the matched movement chain (checkWater per tick, test_movement); CONTENTS_CURRENT clamp path untested (no current brushes exercised) |
| SV_TruePointContents (world.c:537) | world.luau:truePointContents | PENDING | thin wrapper; untested |
| SV_RecursiveHullCheck (world.c:581) | world.luau:recursiveHullCheck | VERIFIED | test_trace: 300 segments x 3 hulls — allsolid/startsolid/inopen/inwater/fraction/endpos/plane exact vs compiled C (1503 checks total incl. points) |
| SV_ClipMoveToEntity (world.c:722) | world.luau:clipMoveToEntity | VERIFIED | world-entity clipping matched over 300 ticks (test_movement) |
| SV_ClipToLinks (world.c:814) | world.luau:clipToLinks | PENDING | side-by-side compared (incl. startsolid-merge quirk, owner skips, MONSTER mins2/maxs2); only indirect E2E coverage, no assertions on entity-vs-entity traces |
| SV_MoveBounds (world.c:893) | world.luau:moveBounds | VERIFIED | part of matched move chain (±1 expansion) |
| SV_Move (world.c:923) | world.luau:move | VERIFIED | test_movement: 300-tick origin/velocity match vs compiled C (world clip); MOVE_MISSILE ±15 preserved, entity clip via E2E only |
| SV_TestEntityPosition (world.c:551) | world.luau:testEntityPosition | VERIFIED | called by checkStuck every tick of the matched chain |

## pr_edict.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| ED_ClearEdict (pr_edict.c:70) | progs/vm.luau:clearEdict | VERIFIED | alloc zero-fills fields (test_vm: free clears solid) |
| ED_Alloc (pr_edict.c:87) | vm.luau:alloc | VERIFIED | test_vm "alloc grows"; 0.5s/2s freetime replacement policy preserved |
| ED_Free (pr_edict.c:122) | vm.luau:free | VERIFIED | test_vm: freed flag, model/solid cleared, nextthink=-1; unlink hook wired to world |
| ED_GlobalAtOfs (pr_edict.c:148) | progs/progs.luau lookup tables | VERIFIED | test_vm: every transcribed global offset matched to real def table |
| ED_FieldAtOfs (pr_edict.c:167) | progs.luau fielddefs | VERIFIED | test_vm: every transcribed field offset matched |
| ED_FindField (pr_edict.c:186) | progs.luau:fielddefsByName | VERIFIED | test_vm fielddef lookups; savegame field parse |
| ED_FindGlobal (pr_edict.c:206) | progs.luau:globaldefsByName | VERIFIED | savegame globals restore (test_savegame) |
| ED_FindFunction (pr_edict.c:226) | progs.luau:functionsByName | VERIFIED | test_vm: anglemod=90, worldspawn=209, SUB_Null=66 |
| GetEdictFieldValue (pr_edict.c:241) | vm.luau:findFieldDef + edFloat | PENDING | used for optional items2 in clientdata; no items2 in id1 progs so branch untested |
| PR_ValueString (pr_edict.c:280) | — | UNIMPLEMENTED | debug printing (ED_Print) |
| PR_UglyValueString (pr_edict.c:332) | server/savegame.luau:uglyValue | VERIFIED | test_savegame: function/field/entity values round-trip through save text |
| PR_GlobalString (pr_edict.c:381) | — | UNIMPLEMENTED | debug trace printing |
| PR_GlobalStringNoContents (pr_edict.c:407) | — | UNIMPLEMENTED | debug |
| ED_Print (pr_edict.c:435) | — | UNIMPLEMENTED | edicts/edict console commands |
| ED_Write (pr_edict.c:485) | savegame.luau:writeEdict | VERIFIED | test_savegame: full state round-trip (health/items/rockets/origin/edict count) |
| ED_PrintNum (pr_edict.c:525) | — | UNIMPLEMENTED | debug |
| ED_PrintEdicts (pr_edict.c:537) | — | UNIMPLEMENTED | debug |
| ED_PrintEdict_f (pr_edict.c:553) | — | UNIMPLEMENTED | debug |
| ED_Count (pr_edict.c:573) | — | UNIMPLEMENTED | debug |
| ED_WriteGlobals (pr_edict.c:616) | savegame.luau:writeGlobals | VERIFIED | test_savegame: world message/serverflags/totals survive reload |
| ED_ParseGlobals (pr_edict.c:649) | savegame.luau:load (globals block) | VERIFIED | test_savegame round-trip |
| ED_NewString (pr_edict.c:693) | vm.luau:newString | VERIFIED | test_vm: `\n` escape converted, other backslashes preserved |
| ED_ParseEpair (pr_edict.c:~714) | vm.luau:parseEpair | VERIFIED | test_vm: string/float/vector parse; savegame function/field restore |
| ED_ParseEdict (pr_edict.c:802) | vm.luau:parseEdict | VERIFIED | test_vm: classname/origin/anglehack ("angle 90" → angles (0,90,0)) |
| ED_LoadFromFile (pr_edict.c:905) | vm.luau:loadFromFile | VERIFIED | test_server census: 1 worldspawn, 18 grunts, 5 dogs, 21 doors; skill/deathmatch spawnflag inhibit logic ported |
| PR_LoadProgs (pr_edict.c:985) | progs/progs.luau:load | VERIFIED | test_vm: header CRC 5927, file CRC16 46133, all table counts vs Python parse |
| PR_Init (pr_edict.c:1068) | cvar.luau DEFAULTS (nomonsters/scratch*/saved*) | SUBSTITUTED | no console commands to register; cvars pre-seeded |
| EDICT_NUM (pr_edict.c:1089) | vm.luau:edictNum | VERIFIED | range-checked; used by every test |
| NUM_FOR_EDICT (pr_edict.c:1096) | Edict.num field | VERIFIED | identity kept on the edict record |

## pr_exec.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| PR_PrintStatement (pr_exec.c:150) | — | UNIMPLEMENTED | trace/debug printing |
| PR_StackTrace (pr_exec.c:190) | vm.luau:runError (function+statement in message) | PENDING | reduced to a one-line context; no full stack walk |
| PR_Profile_f (pr_exec.c:222) | — | UNIMPLEMENTED | profiling console command |
| PR_RunError (pr_exec.c:261) | vm.luau:runError | PENDING | raises a Luau error instead of Host_Error; server keeps running via platform pcall boundaries |
| PR_EnterFunction (pr_exec.c:294) | vm.luau:enterFunction | VERIFIED | parm copy-in/locals save; test_vm anglemod bytecode + stack balanced after calls |
| PR_LeaveFunction (pr_exec.c:333) | vm.luau:leaveFunction | VERIFIED | locals restore; test_vm stack depth 0 after nested calls |
| PR_ExecuteProgram (pr_exec.c:361) | vm.luau:exec | VERIFIED | full opcode interpreter runs shipped progs.dat through every E2E test; test_vm: anglemod values, -0.0 IFNOT int semantics, runaway counter kept |

## sv_main.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_Init (sv_main.c:36) | server/sv.luau:new + cvar DEFAULTS | SUBSTITUTED | cvar registration replaced by the defaults table; localmodels precomputed on demand (`*n` names) |
| SV_StartParticle (sv_main.c:80) | sv.luau:startParticle | PENDING | svc_particle emitted on damage/gibs in E2E runs; dir clamp/truncation ported, unasserted |
| SV_StartSound (sv_main.c:118) | sv.luau:startSound | VERIFIED | test_loopback: "weapons/guncock.wav" event received by client with channel/entity packing |
| SV_SendServerinfo (sv_main.c:189) | sv.luau:sendServerinfo | VERIFIED | test_loopback: levelname, maxclients, precache lists, signon 1 |
| SV_ConnectClient (sv_main.c:243) | sv.luau:connectClient | VERIFIED | signon completes in loopback; SetNewParms → spawn_parms copied; delta: no netconnection object (transport hooks) |
| SV_CheckForNewClients (sv_main.c:302) | src/server/init.server.luau:onInbound/connectPlayer | SUBSTITUTED | polling sockets → event-driven Roblox remotes; clients announce with a first message |
| SV_ClearDatagram (sv_main.c:348) | host.luau:frame (msg.clear) | VERIFIED | per-frame clear; datagram flow asserted in test_server |
| SV_AddToFatPVS (sv_main.c:367) | sv.luau:addToFatPVS | VERIFIED | loopback: spawn-area PVS entity set matches an independent PVS decode (test comment) + visibility assertions; delta: fat buffer zero-padded instead of C's stale static bytes |
| SV_FatPVS (sv_main.c:410) | sv.luau:fatPVS | VERIFIED | same |
| SV_WriteEntitiesToClient (sv_main.c:427) | sv.luau:writeEntitiesToClient | VERIFIED | loopback: baselines + delta bits reproduce entity origins/motion client-side; U_* bit logic side-by-side compared |
| SV_CleanupEnts (sv_main.c:557) | sv.luau:cleanupEnts | PENDING | EF_MUZZLEFLASH cleared per frame; unasserted |
| SV_WriteClientdataToMessage (sv_main.c:576) | sv.luau:writeClientdataToMessage | VERIFIED | loopback: health 100, shells 25, items IT_SHOTGUN, onground, velocity, damage message path in E2E |
| SV_SendClientDatagram (sv_main.c:720) | sv.luau:sendClientDatagram | VERIFIED | test_server: >50 unreliable datagrams, svc_time header + plausible time |
| SV_UpdateToReliableMessages (sv_main.c:756) | sv.luau:updateToReliableMessages | VERIFIED | test_multiplayer: suicide frag -2 propagates to both clients |
| SV_SendNop (sv_main.c:798) | sv.luau:sendClientMessages (nop branch) | PENDING | 5s keepalive; no test waits that long |
| SV_SendClientMessages (sv_main.c:819) | sv.luau:sendClientMessages | VERIFIED | signon gating + reliable/unreliable split proven by loopback signon; overflow-drop branch unasserted |
| SV_ModelIndex (sv_main.c:904) | sv.luau:modelIndex | VERIFIED | test_server: player.mdl index > 0; errors on missing precache |
| SV_CreateBaseline (sv_main.c:925) | sv.luau:createBaseline | VERIFIED | test_server: signon > 1000 bytes; loopback: entities render from baselines |
| SV_SendReconnect (sv_main.c:985) | init.server.luau changelevel block | SUBSTITUTED | no svc_stufftext "reconnect" round-trip; the platform re-runs connectClient for each seated player after spawnServer |
| SV_SaveSpawnparms (sv_main.c:1015) | — | UNIMPLEMENTED | SetChangeParms is never called on level change: player inventory/health and serverflags (runes) do NOT carry across levels; test_changelevel's "fresh spawn on e1m2" documents the divergent behavior |
| SV_SpawnServer (sv_main.c:1047) | server/host.luau:spawnServer | VERIFIED | test_server: entity census, precaches, lightstyles, two settle frames, baseline; QUAKE2 startspot variant excluded |

## sv_move.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_CheckBottom (sv_move.c:37) | server/sv_move.luau:checkBottom | PENDING | side-by-side compared (easy corner check, 2*STEPSIZE traces); exercised by monster AI in test_server, no positional assertions |
| SV_movestep (sv_move.c:110) | sv_move.luau:movestep | PENDING | fly/swim enemy-height nudges, step-down retry, FL_PARTIALGROUND paths all present; monster motion unasserted (only animation frames asserted) |
| SV_StepDirection (sv_move.c:233) | sv_move.luau:stepDirection | PENDING | 45/315-degree turn gate preserved |
| SV_FixCheckBottom (sv_move.c:268) | sv_move.luau:fixCheckBottom | PENDING | |
| SV_NewChaseDir (sv_move.c:284) | sv_move.luau:newChaseDir | PENDING | transliteration preserves the original's 215 (not 225) diagonal constant; RNG is the deterministic LCG, so direction choices diverge from any given C run |
| SV_CloseEnough (sv_move.c:373) | sv_move.luau:closeEnough | PENDING | |
| SV_MoveToGoal (sv_move.c:393) | sv_move.luau:moveToGoal (builtin 67) | PENDING | exercised whenever monsters hunt in E2E tests; unasserted |

## sv_phys.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_CheckAllEnts (sv_phys.c:61) | — | UNIMPLEMENTED | debug sweep, never called by the C game loop |
| SV_CheckVelocity (sv_phys.c:90) | server/sv_phys.luau:checkVelocity | VERIFIED | test_movement: in the 300-tick chain matched vs tools/move_truth.c (max err 0.0002 units) |
| SV_RunThink (sv_phys.c:126) | sv_phys.luau:runThink | VERIFIED | test_server: grunt animation frames advance (QC think chain); sub-frametime nextthink clamp ported |
| SV_Impact (sv_phys.c:153) | sv_phys.luau:impact | PENDING | touch/touch dispatch with self/other/time save-restore; pickups/damage not asserted |
| ClipVelocity (sv_phys.c:190) | sv_phys.luau:clipVelocity | VERIFIED | in matched movement chain (wall slides during yaw-135 phase) |
| SV_FlyMove (sv_phys.c:229) | sv_phys.luau:flyMove | VERIFIED | matched chain incl. bumps/planes/steptrace |
| SV_AddGravity (sv_phys.c:371) | sv_phys.luau:addGravity | VERIFIED | matched chain (jump arcs land identically) |
| SV_PushEntity (sv_phys.c:408) | sv_phys.luau:pushEntity | PENDING | movers/missiles path; E2E only |
| SV_PushMove (sv_phys.c:439) | sv_phys.luau:pushMove | PENDING | door/plat pushing with rider move-back and blocked callback; not asserted offline |
| SV_PushRotate (sv_phys.c:566) | — | UNIMPLEMENTED | dead: QUAKE2-only ifdef in WinQuake |
| SV_Physics_Pusher (sv_phys.c:704) | sv_phys.luau:physicsPusher | PENDING | ltime-based think scheduling ported; doors open in E2E runs, unasserted |
| SV_CheckStuck (sv_phys.c:762) | sv_phys.luau:checkStuck | VERIFIED | called every tick of the matched chain |
| SV_CheckWater (sv_phys.c:808) | sv_phys.luau:checkWater | VERIFIED | matched chain (dry-land path); waterlevel 2/3 branches never entered by the fixture script |
| SV_WallFriction (sv_phys.c:867) | sv_phys.luau:wallFriction | VERIFIED | inside walkMove path of the matched chain |
| SV_TryUnstick (sv_phys.c:901) | sv_phys.luau:tryUnstick | PENDING | transliterated 8-direction unstick; unlikely to be hit by the fixture, unasserted |
| SV_WalkMove (sv_phys.c:958) | sv_phys.luau:walkMove | VERIFIED | matched chain incl. step-up/down and oldonground handling |
| SV_Physics_Client (sv_phys.c:1059) | sv_phys.luau:physicsClient | VERIFIED | test_server: player walks/falls/fires (PlayerPreThink/PostThink run); WALK branch replicated tick-exact in test_movement |
| SV_Physics_None (sv_phys.c:1142) | sv_phys.luau:physicsNone | PENDING | runThink only; trigger entities in E2E |
| SV_Physics_Follow (sv_phys.c:1156) | — | UNIMPLEMENTED | dead: QUAKE2-only |
| SV_Physics_Noclip (sv_phys.c:1172) | sv_phys.luau:physicsNoclip | PENDING | noclip command reachable; unasserted |
| SV_CheckWaterTransition (sv_phys.c:1198) | sv_phys.luau:checkWaterTransition | PENDING | splash sound / watertype transitions unasserted |
| SV_Physics_Toss (sv_phys.c:1245) | sv_phys.luau:physicsToss | PENDING | bounce/backoff 1.5, fall-to-rest; grenades fly in E2E, unasserted |
| SV_Physics_Step (sv_phys.c:1468, NQ variant) | sv_phys.luau:physicsStep | VERIFIED | NQ (non-QUAKE2) variant ported; grunt think/animate asserted in test_server; freefall land-sound branch unasserted. QUAKE2 variant (sv_phys.c:1363) excluded as dead |
| SV_Physics (sv_phys.c:1507) | sv_phys.luau:physics | VERIFIED | test_server: StartFrame QC runs, time advances, all movetypes dispatched for 100+ frames; delta: C's single-player key_dest pause is client-side, port pauses via svr.paused only |
| SV_Trace_Toss (sv_phys.c:1568) | — | UNIMPLEMENTED | only consumed by QUAKE2-only PF_TraceToss |

## sv_user.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SV_SetIdealPitch (sv_user.c:53) | server/sv_user.luau:setIdealPitch | PENDING | 6-step floor sampling transliterated; runs per datagram in E2E, idealpitch value never asserted |
| SV_UserFriction (sv_user.c:122) | sv_user.luau:userFriction | VERIFIED | matched chain (test_movement) incl. edgefriction leading-edge trace |
| SV_Accelerate (#if 0 variant, sv_user.c:170) | — | UNIMPLEMENTED | dead: disabled by `#if 0` in WinQuake |
| SV_Accelerate (sv_user.c:190) | sv_user.luau:accelerate | VERIFIED | matched chain |
| SV_AirAccelerate (sv_user.c:207) | sv_user.luau:airAccelerate | VERIFIED | matched chain (wishspd 30 clamp) |
| DropPunchAngle (sv_user.c:229) | sv_user.luau:dropPunchAngle | PENDING | in the chain but fixture punchangle stays zero; decay math untested |
| SV_WaterMove (sv_user.c:247) | sv_user.luau:waterMove | PENDING | ported (copied verbatim into tools/move_truth.c but the scripted route never enters water) |
| SV_WaterJump (sv_user.c:307) | sv_user.luau:waterJump | PENDING | FL_WATERJUMP path unexercised by fixture |
| SV_AirMove (sv_user.c:326) | sv_user.luau:airMove | VERIFIED | matched chain (fwd/side/up wishvel, onground dispatch) |
| SV_ClientThink (sv_user.c:380) | sv_user.luau:clientThink | VERIFIED | matched chain; includes V_CalcRoll (view.c) for angles roll |
| SV_ReadClientMove (sv_user.c:438) | sv_user.luau:readClientMove | VERIFIED | test_server: clc_move angles/moves/buttons/impulse drive asserted movement + shotgun fire; delta: ping_times[] not tracked (no ping report) |
| SV_ReadClientMessage (sv_user.c:482) | server/host.luau:readClientMessage | VERIFIED | all E2E tests: stringcmd/move/disconnect/nop dispatch, badread drop; delta: C's per-command whitelist + Cmd_ExecuteString hop replaced by direct dispatch into host.clientCommand |
| SV_RunClients (sv_user.c:600) | host.luau:runClients | VERIFIED | drop on misbehave, cmd cleared while unspawned, paused gate; exercised in every E2E test |

## host.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Host_EndGame (host.c:90) | — | SUBSTITUTED | no demo loop/process to unwind; Luau error + platform respawn (Roblox server owns the process) |
| Host_Error (host.c:121) | Luau error() propagation | SUBSTITUTED | no longjmp; errors bubble to the Heartbeat boundary |
| Host_FindMaxClients (host.c:157) | init.server.luau (fixed 16 slots) | SUBSTITUTED | no -dedicated/-listen argv; Roblox place size governs players |
| Host_InitLocal (host.c:209) | cvar.luau DEFAULTS | SUBSTITUTED | host cvars (host_framerate/serverprofile...) are dev knobs without a console |
| Host_WriteConfiguration (host.c:246) | — | SUBSTITUTED | no writable config.cfg on Roblox (FIDELITY.md); DataStore substitute possible later |
| SV_ClientPrintf (host.c:277) | host.luau:clientPrint | PENDING | svc_print to one client; unasserted |
| SV_BroadcastPrintf (host.c:297) | sv.luau:broadcastPrint | PENDING | used by pause/name paths; client receipt unasserted |
| Host_ClientCommands (host.c:322) | sv.luau:clientCommands | PENDING | svc_stufftext; QC stuffcmd path unasserted |
| SV_DropClient (host.c:343) | sv.luau:dropClient | PENDING | ClientDisconnect QC call + updatename/frags/colors broadcast ported; exercised on misbehave/PlayerRemoving, unasserted |
| Host_ShutdownServer (host.c:405) | — | SUBSTITUTED | Roblox server lifecycle; level changes respawn in place (host.spawnServer) and re-connect seated players instead of a shutdown message |
| Host_ClearMemory (host.c:477) | — | SUBSTITUTED | GC; spawnServer builds a fresh VM/world per level |
| Host_FilterTime (host.c:501) | init.server.luau Heartbeat clamp | SUBSTITUTED | Heartbeat dt clamped to [0.001, 0.1]; no 72fps cap (FIDELITY.md: dt-driven sim verified at arbitrary dt) |
| Host_GetConsoleCommands (host.c:532) | — | SUBSTITUTED | no dedicated-server console; Studio attributes serve as the debug channel |
| _Host_ServerFrame (host.c:554, FPS_20) | — | UNIMPLEMENTED | dead: FPS_20 ifdef not compiled in WinQuake |
| Host_ServerFrame (host.c:600) | host.luau:frame | VERIFIED | test_server/test_loopback: clear datagram → run clients → physics → send messages, in C order; new-client polling is event-driven (substitution noted above) |
| _Host_Frame / Host_Frame (host.c:633,729) | host.luau:frame + init.server.luau Heartbeat | VERIFIED | server half only; client half (input/render/sound/cd) lives in the client port; rate limiting substituted per Host_FilterTime row |
| Host_InitVCR (host.c:772) | — | UNIMPLEMENTED | VCR record/playback dev harness |
| Host_Init (host.c:835) | init.server.luau bootstrap | SUBSTITUTED | pak assembly from asset chunks, remotes, host.newGame |
| Host_Shutdown (host.c:932) | — | SUBSTITUTED | Roblox tears the server down |

## host_cmd.c

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Host_Quit_f (host_cmd.c:37) | — | SUBSTITUTED | players leave via Roblox; no process quit |
| Host_Status_f (host_cmd.c:56) | host.luau:clientCommand ("status" no-op) | UNIMPLEMENTED | informational report not built |
| Host_God_f (host_cmd.c:113) | host.luau:toggleFlag (god) | PENDING | FL_GODMODE toggle + on/off prints; unasserted |
| Host_Notarget_f (host_cmd.c:131) | toggleFlag (notarget) | PENDING | |
| Host_Noclip_f (host_cmd.c:151) | clientCommand "noclip" | PENDING | movetype toggle; delta: no ON/OFF print |
| Host_Fly_f (host_cmd.c:183) | clientCommand "fly" | PENDING | delta: no ON/OFF print |
| Host_Ping_f (host_cmd.c:213) | "ping" no-op | UNIMPLEMENTED | ping times not tracked (see SV_ReadClientMove delta) |
| Host_Map_f (host_cmd.c:256) | clientCommand "map" → changelevelTo + platform respawn | PENDING | delta: does not reset serverflags/spawn parms like C map command |
| Host_Changelevel_f (host_cmd.c:311) | clientCommand "changelevel" / QC builtin 70 | PENDING | delta: missing SV_SaveSpawnparms (see sv_main.c row) |
| Host_Restart_f (host_cmd.c:366) | pr_cmds.luau localcmd "restart" → respawn same map | PENDING | |
| Host_Reconnect_f (host_cmd.c:396) | — | SUBSTITUTED | client-side signon reset; platform reconnects slots after respawn |
| Host_Connect_f (host_cmd.c:409) | — | SUBSTITUTED | Roblox join flow replaces connect <host> |
| Host_SavegameComment (host_cmd.c:442) | savegame.luau:comment | PENDING | kills/level format with underscore padding ported; content not asserted |
| Host_Savegame_f (host_cmd.c:465) | savegame.luau:write + clientCommand "save" | VERIFIED | test_savegame: version-5 text, >10KB content, full state round-trip (13 checks); storage substituted to ServerStorage.QuakeSaves |
| Host_Loadgame_f (host_cmd.c:561) | savegame.luau:load + deferred loadgameRequest | VERIFIED | test_savegame: health/items/rockets/origin/time/edict count restored, pause-until-begin, still runs after resume |
| SaveGamestate (host_cmd.c:710) | — | UNIMPLEMENTED | dead: QUAKE2-only |
| LoadGamestate (host_cmd.c:761) | — | UNIMPLEMENTED | dead: QUAKE2-only |
| Host_Changelevel2_f (host_cmd.c:865) | — | UNIMPLEMENTED | dead: QUAKE2-only |
| Host_Name_f (host_cmd.c:910) | host.luau:hostName | VERIFIED | test_multiplayer: names propagate to both clients' scoreboards; 15-char clamp + netname set |
| Host_Version_f (host_cmd.c:949) | — | UNIMPLEMENTED | trivial console print |
| Host_Please_f (host_cmd.c:956) | — | UNIMPLEMENTED | registered-only easter egg |
| Host_Say (host_cmd.c:1008) | host.luau:hostSay | PENDING | \1name: text framing + teamplay filter; client receipt unasserted |
| Host_Say_f (host_cmd.c:1072) | clientCommand "say" | PENDING | |
| Host_Say_Team_f (host_cmd.c:1078) | clientCommand "say_team" | PENDING | |
| Host_Tell_f (host_cmd.c:1084) | — | UNIMPLEMENTED | private messaging not ported |
| Host_Color_f (host_cmd.c:1141) | host.luau:hostColor | PENDING | 13-clamp, team=bottom+1, updatecolors broadcast; sent in test_server but not asserted client-side |
| Host_Kill_f (host_cmd.c:1192) | host.luau:hostKill | VERIFIED | test_multiplayer: kill → ClientKill QC → -2 frags on both views + respawn |
| Host_Pause_f (host_cmd.c:1217) | clientCommand "pause" | PENDING | pausable gate + svc_setpause broadcast; unasserted |
| Host_PreSpawn_f (host_cmd.c:1254) | host.luau:hostPreSpawn | VERIFIED | loopback signon: signon buffer replay + signonnum 2 (baselines/ambients received) |
| Host_Spawn_f (host_cmd.c:1279) | host.luau:hostSpawn | VERIFIED | loopback: ClientConnect/PutClientInServer run, names/frags/colors, lightstyles, stats, setangle, clientdata, signonnum 3 all parsed; loadgame branch in test_savegame |
| Host_Begin_f (host_cmd.c:1403) | host.luau:hostBegin | VERIFIED | client.spawned asserted everywhere; loadgame unpause branch in test_savegame |
| Host_Kick_f (host_cmd.c:1424) | — | UNIMPLEMENTED | admin kick not ported (platform Kick only for full server) |
| Host_Give_f (host_cmd.c:1516) | clientCommand "give" | PENDING | weapons 1-8 + s/n/r/c/h ammo/health essentials; used by test_savegame setup but effect not directly asserted |
| Host_Viewmodel_f (host_cmd.c:1690) | — | UNIMPLEMENTED | dev model-viewer command |
| Host_Viewframe_f (host_cmd.c:1715) | — | UNIMPLEMENTED | dev |
| PrintFrameName (host_cmd.c:1734) | — | UNIMPLEMENTED | dev |
| Host_Viewnext_f (host_cmd.c:1752) | — | UNIMPLEMENTED | dev |
| Host_Viewprev_f (host_cmd.c:1774) | — | UNIMPLEMENTED | dev |
| Host_Startdemos_f (host_cmd.c:1806) | client demo system (out of server scope) | SUBSTITUTED | demo playback/record ported client-side per FIDELITY.md; server contributes the rq_need file hook |
| Host_Demos_f (host_cmd.c:1845) | client-side | SUBSTITUTED | same |
| Host_Stopdemo_f (host_cmd.c:1862) | client-side | SUBSTITUTED | same |
| Host_InitCommands (host_cmd.c:1879) | host.luau:clientCommand dispatcher | SUBSTITUTED | command registration table → direct string dispatch of the clc_stringcmd subset |

## pr_cmds.c

All live NQ builtins are installed by server/pr_cmds.luau:install() into the VM's numbered
builtin table (numbers match the C pr_builtin[] array; slots that are PF_Fixme in the NQ
build are absent and hit the VM's bad-builtin error).

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| PF_VarString (pr_cmds.c:33) | pr_cmds.luau:varString | PENDING | concat of parm strings; feeds prints, unasserted |
| PF_error #10 (pr_cmds.c:57) | pr_cmds.luau def(10) | PENDING | raises Luau error with function name |
| PF_objerror #11 (pr_cmds.c:81) | def(11) | PENDING | frees self then errors; delta: C only frees + continues, port aborts the frame via error |
| PF_makevectors #1 (pr_cmds.c:106) | def(1) | PENDING | v_forward/right/up set; angleVectors itself verified (mathlib row) |
| PF_setorigin #2 (pr_cmds.c:120) | def(2) | VERIFIED | player spawn origin asserted client-side in loopback (setorigin + relink) |
| SetMinMaxSize (pr_cmds.c:132) | pr_cmds.luau:setMinMaxSize | PENDING | delta: C's unused rotate parameter dropped (always false in NQ callers) |
| PF_setsize #4 (pr_cmds.c:215) | def(4) | VERIFIED | player hull from PutClientInServer → onground/walk movement asserted (test_server) |
| PF_setmodel #3 (pr_cmds.c:234) | def(3) | VERIFIED | precache index lookup + brush model min/max; census + client precache lists asserted |
| PF_bprint #23 (pr_cmds.c:273) | def(23) | PENDING | |
| PF_sprint #24 (pr_cmds.c:290) | def(24) | PENDING | svc_print to one client |
| PF_centerprint #73 (pr_cmds.c:321) | def(73) | PENDING | svc_centerprint |
| PF_normalize #9 (pr_cmds.c:350) | def(9) | PENDING | QC-exercised constantly, unasserted |
| PF_vlen #12 (pr_cmds.c:381) | def(12) | PENDING | |
| PF_vectoyaw #13 (pr_cmds.c:401) | def(13) | PENDING | int truncation preserved |
| PF_vectoangles #51 (pr_cmds.c:428) | def(51) | PENDING | int truncation + 90/270 vertical cases |
| PF_random #7 (pr_cmds.c:470) | def(7) | PENDING | delta: deterministic msvcrt-LCG rand() with fixed seed 12345 — sequence diverges from any particular C session (C never seeds either, but state differs) |
| PF_particle #48 (pr_cmds.c:486) | def(48) | PENDING | |
| PF_ambientsound #74 (pr_cmds.c:506) | def(74) | VERIFIED | loopback: ≥4 svc_spawnstaticsound received from e1m1 signon |
| PF_sound #8 (pr_cmds.c:558) | def(8) | VERIFIED | loopback: shotgun sample event with volume*255 scaling |
| PF_break #6 (pr_cmds.c:591) | def(6) | PENDING | errors instead of debugger drop |
| PF_traceline #16 (pr_cmds.c:609) | def(16) | PENDING | trace globals set; underlying world.move verified, builtin glue unasserted (firing consumes shells but hit results unchecked) |
| PF_TraceToss #64 slot (pr_cmds.c:641) | — | UNIMPLEMENTED | dead: PF_Fixme slot in NQ build (QUAKE2-only) |
| PF_checkpos (pr_cmds.c:678) | — | UNIMPLEMENTED | empty stub in C too |
| PF_newcheckclient (pr_cmds.c:686) | pr_cmds.luau:newCheckClient | PENDING | 0.1s rotation + PVS snapshot; monster sight in E2E only |
| PF_checkclient #17 (pr_cmds.c:753) | def(17) | PENDING | PVS bit test transliterated |
| PF_stuffcmd #21 (pr_cmds.c:804) | def(21) | PENDING | svc_stufftext (QC "bf\n" flashes) unasserted |
| PF_localcmd #46 (pr_cmds.c:830) | def(46) | PENDING | delta: no Cbuf on the server — routes changelevel/restart to changelevelTo, logs everything else |
| PF_cvar #45 (pr_cmds.c:845) | def(45) | PENDING | QC reads registered/teamplay via it |
| PF_cvar_set #72 (pr_cmds.c:861) | def(72) | PENDING | |
| PF_findradius #22 (pr_cmds.c:880) | def(22) | PENDING | chain building; explosions in E2E only |
| PF_dprint #25 (pr_cmds.c:918) | def(25) | PENDING | routed to svr.dprint |
| PF_ftos #26 (pr_cmds.c:925) | def(26) | PENDING | %d vs %5.1f split preserved; shared temp-string slot like pr_string_temp |
| PF_fabs #43 (pr_cmds.c:937) | def(43) | PENDING | |
| PF_vtos #27 (pr_cmds.c:944) | def(27) | PENDING | '%5.1f %5.1f %5.1f' format |
| PF_etos (pr_cmds.c:951) | — | UNIMPLEMENTED | dead: PF_Fixme slot in NQ build |
| PF_Spawn #14 (pr_cmds.c:958) | def(14) | VERIFIED | entity census exact (test_server); ED_Alloc verified in test_vm |
| PF_Remove #15 (pr_cmds.c:965) | def(15) | VERIFIED | inhibited-entity frees during load → exact census; ED_Free verified in test_vm |
| PF_Find #18 (pr_cmds.c:975) | def(18) | VERIFIED | SelectSpawnPoint's find() → player near info_player_start asserted (loopback/test_server) |
| PR_CheckEmptyString (pr_cmds.c:1056) | pr_cmds.luau:checkEmptyString | PENDING | |
| PF_precache_file #68 (pr_cmds.c:1062) | def(68) | PENDING | no-op returning parm, like C |
| PF_precache_sound #19 (pr_cmds.c:1067) | def(19) | VERIFIED | test_server: >30 sounds precached; loading-state guard + overflow error ported |
| PF_precache_model #20 (pr_cmds.c:1092) | def(20) | VERIFIED | test_server: >30 models, player.mdl indexed; loads model + registers brush submodels |
| PF_coredump #28 (pr_cmds.c:1119) | def(28) stub | UNIMPLEMENTED | prints a stub line; no ED_PrintEdicts to call |
| PF_traceon/PF_traceoff #29/#30 (pr_cmds.c:1124,1129) | def(29)/def(30) | UNIMPLEMENTED | sets vm.trace but exec() resets it and no statement printer exists — effectively inert |
| PF_eprint #31 (pr_cmds.c:1134) | def(31) empty | UNIMPLEMENTED | debug print stub |
| PF_walkmove #32 (pr_cmds.c:1146) | def(32) | PENDING | program-state save/restore around movestep preserved |
| PF_droptofloor #34 (pr_cmds.c:1189) | def(34) | PENDING | -256 drop + FL_ONGROUND/groundentity; items settle in E2E, unasserted |
| PF_lightstyle #35 (pr_cmds.c:1221) | def(35) | VERIFIED | test_server: styles 0/63/10 registered; loopback receives style 0 "m" |
| PF_rint #36 (pr_cmds.c:1247) | def(36) | PENDING | round-half-away-from-zero preserved |
| PF_floor #37 / PF_ceil #38 (pr_cmds.c:1256,1260) | def(37)/def(38) | PENDING | |
| PF_checkbottom #40 (pr_cmds.c:1271) | def(40) | PENDING | |
| PF_pointcontents #41 (pr_cmds.c:1285) | def(41) | PENDING | wraps verified pointContents; builtin glue unasserted |
| PF_nextent #47 (pr_cmds.c:1301) | def(47) | PENDING | |
| PF_aim #44 (pr_cmds.c:1333) | def(44) | PENDING | sv_aim 0.93 default + teamplay filter; firing works E2E but aim vector unasserted |
| PF_changeyaw #49 (pr_cmds.c:1412) | sv_move.luau:changeYaw via def(49) | PENDING | anglemod quantization; monster turning unasserted |
| PF_changepitch (pr_cmds.c:1455) | — | UNIMPLEMENTED | dead: PF_Fixme slot in NQ build |
| WriteDest (pr_cmds.c:1506) | pr_cmds.luau:writeDest | VERIFIED | MSG_ALL routing proven by intermission svc reaching the client (test_changelevel) |
| PF_WriteByte #52 (pr_cmds.c:1539) | def(52) | VERIFIED | QC intermission bytes parsed by real client (test_changelevel: intermission seen) |
| PF_WriteChar #53 (pr_cmds.c:1544) | def(53) | PENDING | |
| PF_WriteShort #54 (pr_cmds.c:1549) | def(54) | PENDING | |
| PF_WriteLong #55 (pr_cmds.c:1554) | def(55) | PENDING | |
| PF_WriteAngle #57 (pr_cmds.c:1559) | def(57) | PENDING | |
| PF_WriteCoord #56 (pr_cmds.c:1564) | def(56) | PENDING | |
| PF_WriteString #58 (pr_cmds.c:~1570) | def(58) | PENDING | |
| PF_WriteEntity #59 (pr_cmds.c:~1576) | def(59) | PENDING | |
| PF_makestatic #69 (pr_cmds.c:~1585) | def(69) | PENDING | svc_spawnstatic + edict free; e1m1 has no statics so loopback doesn't hit it (torch maps do in manual runs per FIDELITY.md) |
| PF_setspawnparms #78 (pr_cmds.c:~1616) | def(78) | PENDING | copies client parms to parm globals |
| PF_changelevel #70 (pr_cmds.c:~1639) | def(70) | VERIFIED | test_changelevel: changelevelTo == "e1m2", double-issue guard |
| PF_WaterMove (pr_cmds.c:~1684) | — | UNIMPLEMENTED | dead: QUAKE2-only |
| PF_sin/PF_cos/PF_sqrt (pr_cmds.c:~1809+) | — | UNIMPLEMENTED | dead: QUAKE2-only slots |
| PF_Fixme (pr_cmds.c:~1825) | vm.luau exec bad-builtin error | PENDING | missing builtin number → runError, equivalent to Fixme's abort |
| precache_model2/sound2/file2 #75-77 | pr_cmds.luau B[75..77] aliases | VERIFIED | aliased to the verified #19/#20/#68 implementations, same as C's table |

## zone.c

The entire zone/hunk/cache allocator is replaced by Luau garbage collection and `buffer`
objects; Roblox provides no manual memory management and none is needed (models, edicts,
and message buffers are ordinary GC values; per-level state is rebuilt in spawnServer).

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| Z_ClearZone / Z_Free / Z_Malloc / Z_TagMalloc (zone.c:74-155) | — | SUBSTITUTED | GC |
| Z_Print / Z_CheckHeap (zone.c:219,247) | — | SUBSTITUTED | no heap to audit |
| Hunk_Check / Hunk_Print (zone.c:293,315) | — | SUBSTITUTED | GC |
| Hunk_AllocName / Hunk_Alloc (zone.c:399,434) | — | SUBSTITUTED | GC |
| Hunk_FreeToLowMark / Hunk_FreeToHighMark (zone.c:444,463) | — | SUBSTITUTED | per-level state rebuilt in spawnServer instead of hunk marks |
| Hunk_HighAllocName / Hunk_TempAlloc (zone.c:482,528) | — | SUBSTITUTED | GC |
| Cache_Move / Cache_FreeLow / Cache_FreeHigh (zone.c:575-628) | — | SUBSTITUTED | no cache eviction; models held by registry until level teardown |
| Cache_UnlinkLRU / Cache_MakeLRU / Cache_TryAlloc (zone.c:650-680) | — | SUBSTITUTED | GC |
| Cache_Flush / Cache_Print / Cache_Report / Cache_Compact (zone.c:759-799) | — | SUBSTITUTED | GC |
| Cache_Init / Cache_Free / Cache_Check / Cache_Alloc (zone.c:809-871) | — | SUBSTITUTED | GC |
| Memory_Init (zone.c:913) | — | SUBSTITUTED | no -zone/-heapsize; Luau VM manages memory |

## net_main.c (+ net_dgrm.c / net_loop.c / net_wins.c / drivers as one group)

The entire NET layer is substituted: UDP/IPX sockets and the loopback driver are replaced
by Roblox RemoteEvents (reliable) and UnreliableRemoteEvents, wired in
src/server/init.server.luau. Each engine Client carries transport hooks
(sendReliable/sendUnreliable/canSendReliable) and an inbox of raw clc buffers; the svc/clc
byte stream on top is the exact protocol 15 format (FIDELITY.md). Delivery deltas: the
reliable channel is genuinely reliable (no resend logic needed), and unreliable payloads
over ~850 bytes are re-routed onto the reliable remote because UnreliableRemoteEvents
silently drop >~900-byte packets.

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| SetNetTime (net_main.c:95) | svr.realtime accumulation in host.frame | SUBSTITUTED | Heartbeat-driven time |
| NET_NewQSocket / NET_FreeQSocket (net_main.c:110,149) | sv.newClient transport hooks | SUBSTITUTED | no socket objects |
| NET_Listen_f / MaxPlayers_f / NET_Port_f (net_main.c:175-233) | — | SUBSTITUTED | Roblox place settings govern listening/capacity |
| PrintSlistHeader / PrintSlist / PrintSlistTrailer / NET_Slist_f / Slist_Send / Slist_Poll (net_main.c:262-331) | — | SUBSTITUTED | server browsing is Roblox's discovery UI |
| NET_Connect (net_main.c:368) | client fires first remote message | SUBSTITUTED | connectPlayer on first inbound (init.server.luau) |
| NET_CheckNewConnections (net_main.c:457) | onInbound/connectPlayer | SUBSTITUTED | event-driven |
| NET_Close (net_main.c:500) | PlayerRemoving → dropClient | SUBSTITUTED | |
| NET_GetMessage (net_main.c:540) | client.inbox drain in host.readClientMessage | SUBSTITUTED | ordered buffer queue; no resend/ack needed |
| NET_SendMessage (net_main.c:625) | client.sendReliable | SUBSTITUTED | RemoteEvent:FireClient |
| NET_SendUnreliableMessage (net_main.c:656) | client.sendUnreliable | SUBSTITUTED | UnreliableRemoteEvent, >850B fallback to reliable |
| NET_CanSendMessage (net_main.c:695) | client.canSendReliable | SUBSTITUTED | always true on remotes |
| NET_SendToAll (net_main.c:722) | per-client loop in sendClientMessages | SUBSTITUTED | |
| NET_Init / NET_Shutdown / NET_Poll / SchedulePollProcedure (net_main.c:804-958) | remote creation in init.server.luau | SUBSTITUTED | no polling procedures |
| net_dgrm.c / net_loop.c / net_wins.c / net_udp / net_vcr / net_ser (group) | — | SUBSTITUTED | datagram framing, ack/resend, loopback driver all unnecessary on Roblox remotes; the loopback tests wire client and server directly through the same transport hooks (tests/test_loopback.luau) |

## sys_win.c / sys_dos.c / conproc.c (group)

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| sys_win.c / sys_dos.c / conproc.c (entire files) | src/server/init.server.luau + Lune test runner | SUBSTITUTED | file I/O → vfs over asset chunks; timers → RunService.Heartbeat / os.clock in tests; Sys_Error → Luau error; no console process to manage |

## cd_win.c / cd_dos.c etc. (group)

| Function | Port | Status | Evidence / Delta |
|---|---|---|---|
| cd_*.c (entire files) | — | SUBSTITUTED | CD audio tracks were never in the paks; svc_cdtrack is still sent (sv.sendServerinfo) but no playback backend exists (FIDELITY.md; LibreQuake music could be banked later) |

## Port-side additions with no C counterpart

| Addition | Justification |
|---|---|
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

Scope: 19 enumerated C files plus 3 substituted platform groups (net drivers,
sys/conproc, cd). 455 table rows; a few rows group trivial sibling functions
(endian swaps, floor/ceil, traceon/traceoff, the zone allocator, net_main
socket entries), so the rows cover ~490 C function definitions.

| Status | Count (rows) |
|---|---|
| VERIFIED | 157 |
| PENDING | 125 |
| UNIMPLEMENTED | 62 |
| SUBSTITUTED | 111 |

Notes on the UNIMPLEMENTED bucket: 13 of the 49 are dead code in the WinQuake NQ build
(QUAKE2/FPS_20/#if 0 ifdefs or PF_Fixme slots); most of the rest are console/debug
printing (ED_Print*, PR_Profile, viewmodel dev commands). The gameplay-relevant gaps are
SV_SaveSpawnparms (inventory/rune carry across levels), Host_Tell_f, and Host_Kick_f.
