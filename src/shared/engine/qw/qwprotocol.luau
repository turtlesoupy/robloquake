--!strict
-- QuakeWorld protocol 28 constants — QW/client/protocol.h verbatim.

local p = {}

p.PROTOCOL_VERSION = 28

p.MAX_CLIENTS = 32
p.UPDATE_BACKUP = 64
p.UPDATE_MASK = 63

-- server to client
p.svc_bad = 0
p.svc_nop = 1
p.svc_disconnect = 2
p.svc_updatestat = 3
p.svc_setview = 5
p.svc_sound = 6
p.svc_print = 8
p.svc_stufftext = 9
p.svc_setangle = 10
p.svc_serverdata = 11
p.svc_lightstyle = 12
p.svc_updatefrags = 14
p.svc_stopsound = 16
p.svc_damage = 19
p.svc_spawnstatic = 20
p.svc_spawnbaseline = 22
p.svc_temp_entity = 23
p.svc_setpause = 24
p.svc_centerprint = 26
p.svc_killedmonster = 27
p.svc_foundsecret = 28
p.svc_spawnstaticsound = 29
p.svc_intermission = 30
p.svc_finale = 31
p.svc_cdtrack = 32
p.svc_sellscreen = 33
p.svc_smallkick = 34
p.svc_bigkick = 35
p.svc_updateping = 36
p.svc_updateentertime = 37
p.svc_updatestatlong = 38
p.svc_muzzleflash = 39
p.svc_updateuserinfo = 40
p.svc_download = 41
p.svc_playerinfo = 42
p.svc_nails = 43
p.svc_chokecount = 44
p.svc_modellist = 45
p.svc_soundlist = 46
p.svc_packetentities = 47
p.svc_deltapacketentities = 48
p.svc_maxspeed = 49
p.svc_entgravity = 50
p.svc_setinfo = 51
p.svc_serverinfo = 52
p.svc_updatepl = 53

-- client to server
p.clc_bad = 0
p.clc_nop = 1
p.clc_move = 3
p.clc_stringcmd = 4
p.clc_delta = 5
p.clc_tmove = 6
p.clc_upload = 7

-- playerinfo flags (always sends playernum, flags, origin, framenumber)
p.PF_MSEC = 1
p.PF_COMMAND = 2
p.PF_VELOCITY1 = 4
p.PF_VELOCITY2 = 8
p.PF_VELOCITY3 = 16
p.PF_MODEL = 32
p.PF_SKINNUM = 64
p.PF_EFFECTS = 128
p.PF_WEAPONFRAME = 256 -- only sent for view player
p.PF_DEAD = 512 -- don't block movement any more
p.PF_GIB = 1024 -- offset the view height differently
p.PF_NOGRAV = 2048 -- don't apply gravity for prediction

-- usercmd delta bits
p.CM_ANGLE1 = 1
p.CM_ANGLE3 = 2
p.CM_FORWARD = 4
p.CM_SIDE = 8
p.CM_UP = 16
p.CM_BUTTONS = 32
p.CM_IMPULSE = 64
p.CM_ANGLE2 = 128

-- packet entity bits (first byte holds the low bits + entity number)
p.U_ORIGIN1 = 512
p.U_ORIGIN2 = 1024
p.U_ORIGIN3 = 2048
p.U_ANGLE2 = 4096
p.U_FRAME = 8192
p.U_REMOVE = 16384 -- REMOVE this entity, don't add it
p.U_MOREBITS = 32768
-- morebits byte
p.U_ANGLE1 = 1
p.U_ANGLE3 = 2
p.U_MODEL = 4
p.U_COLORMAP = 8
p.U_SKIN = 16
p.U_EFFECTS = 32
p.U_SOLID = 64 -- the entity should be solid for prediction

p.SND_VOLUME = 32768
p.SND_ATTENUATION = 16384
p.DEFAULT_SOUND_PACKET_VOLUME = 255
p.DEFAULT_SOUND_PACKET_ATTENUATION = 1.0

p.PRINT_LOW = 0
p.PRINT_MEDIUM = 1
p.PRINT_HIGH = 2
p.PRINT_CHAT = 3

p.TE_SPIKE = 0
p.TE_SUPERSPIKE = 1
p.TE_GUNSHOT = 2
p.TE_EXPLOSION = 3
p.TE_TAREXPLOSION = 4
p.TE_LIGHTNING1 = 5
p.TE_LIGHTNING2 = 6
p.TE_WIZSPIKE = 7
p.TE_KNIGHTSPIKE = 8
p.TE_LIGHTNING3 = 9
p.TE_LAVASPLASH = 10
p.TE_TELEPORT = 11
p.TE_BLOOD = 12
p.TE_LIGHTNINGBLOOD = 13

-- QW stats
p.STAT_HEALTH = 0
p.STAT_FRAGS = 1
p.STAT_WEAPON = 2
p.STAT_AMMO = 3
p.STAT_ARMOR = 4
p.STAT_SHELLS = 6
p.STAT_NAILS = 7
p.STAT_ROCKETS = 8
p.STAT_CELLS = 9
p.STAT_ACTIVEWEAPON = 10
p.STAT_TOTALSECRETS = 11
p.STAT_TOTALMONSTERS = 12
p.STAT_SECRETS = 13
p.STAT_MONSTERS = 14
p.STAT_ITEMS = 15
p.STAT_VIEWHEIGHT = 16

return p
