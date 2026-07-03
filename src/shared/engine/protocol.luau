--!strict
-- Network protocol constants from WinQuake protocol.h (protocol 15).

local protocol = {}

protocol.PROTOCOL_VERSION = 15

-- entity update flags
protocol.U_MOREBITS = 1
protocol.U_ORIGIN1 = 2
protocol.U_ORIGIN2 = 4
protocol.U_ORIGIN3 = 8
protocol.U_ANGLE2 = 16
protocol.U_NOLERP = 32 -- don't interpolate movement
protocol.U_FRAME = 64
protocol.U_SIGNAL = 128 -- just differentiates from other updates
protocol.U_ANGLE1 = 256
protocol.U_ANGLE3 = 512
protocol.U_MODEL = 1024
protocol.U_COLORMAP = 2048
protocol.U_SKIN = 4096
protocol.U_EFFECTS = 8192
protocol.U_LONGENTITY = 16384

-- clientdata flags
protocol.SU_VIEWHEIGHT = 1
protocol.SU_IDEALPITCH = 2
protocol.SU_PUNCH1 = 4
protocol.SU_PUNCH2 = 8
protocol.SU_PUNCH3 = 16
protocol.SU_VELOCITY1 = 32
protocol.SU_VELOCITY2 = 64
protocol.SU_VELOCITY3 = 128
protocol.SU_ITEMS = 512
protocol.SU_ONGROUND = 1024
protocol.SU_INWATER = 2048
protocol.SU_WEAPONFRAME = 4096
protocol.SU_ARMOR = 8192
protocol.SU_WEAPON = 16384

-- sound message flags
protocol.SND_VOLUME = 1
protocol.SND_ATTENUATION = 2
protocol.SND_LOOPING = 4
protocol.DEFAULT_SOUND_PACKET_VOLUME = 255
protocol.DEFAULT_SOUND_PACKET_ATTENUATION = 1.0

protocol.DEFAULT_VIEWHEIGHT = 22

protocol.GAME_COOP = 0
protocol.GAME_DEATHMATCH = 1

-- server to client
protocol.svc_bad = 0
protocol.svc_nop = 1
protocol.svc_disconnect = 2
protocol.svc_updatestat = 3
protocol.svc_version = 4
protocol.svc_setview = 5
protocol.svc_sound = 6
protocol.svc_time = 7
protocol.svc_print = 8
protocol.svc_stufftext = 9
protocol.svc_setangle = 10
protocol.svc_serverinfo = 11
protocol.svc_lightstyle = 12
protocol.svc_updatename = 13
protocol.svc_updatefrags = 14
protocol.svc_clientdata = 15
protocol.svc_stopsound = 16
protocol.svc_updatecolors = 17
protocol.svc_particle = 18
protocol.svc_damage = 19
protocol.svc_spawnstatic = 20
protocol.svc_spawnbaseline = 22
protocol.svc_temp_entity = 23
protocol.svc_setpause = 24
protocol.svc_signonnum = 25
protocol.svc_centerprint = 26
protocol.svc_killedmonster = 27
protocol.svc_foundsecret = 28
protocol.svc_spawnstaticsound = 29
protocol.svc_intermission = 30
protocol.svc_finale = 31
protocol.svc_cdtrack = 32
protocol.svc_sellscreen = 33
protocol.svc_cutscene = 34

-- client to server
protocol.clc_bad = 0
protocol.clc_nop = 1
protocol.clc_disconnect = 2
protocol.clc_move = 3
protocol.clc_stringcmd = 4

-- temp entity events
protocol.TE_SPIKE = 0
protocol.TE_SUPERSPIKE = 1
protocol.TE_GUNSHOT = 2
protocol.TE_EXPLOSION = 3
protocol.TE_TAREXPLOSION = 4
protocol.TE_LIGHTNING1 = 5
protocol.TE_LIGHTNING2 = 6
protocol.TE_WIZSPIKE = 7
protocol.TE_KNIGHTSPIKE = 8
protocol.TE_LIGHTNING3 = 9
protocol.TE_LAVASPLASH = 10
protocol.TE_TELEPORT = 11
protocol.TE_EXPLOSION2 = 12
protocol.TE_BEAM = 13

protocol.NUM_SPAWN_PARMS = 16

return protocol
