--!strict
-- Engine-wide constants from quakedef.h / server.h / protocol.h.

local quakedef = {}

-- edict->solid values
quakedef.SOLID_NOT = 0 -- no interaction with other objects
quakedef.SOLID_TRIGGER = 1 -- touch on edge, but not blocking
quakedef.SOLID_BBOX = 2 -- touch on edge, block
quakedef.SOLID_SLIDEBOX = 3 -- touch on edge, but not an onground
quakedef.SOLID_BSP = 4 -- bsp clip, touch on edge, block

-- edict->movetype values
quakedef.MOVETYPE_NONE = 0 -- never moves
quakedef.MOVETYPE_ANGLENOCLIP = 1
quakedef.MOVETYPE_ANGLECLIP = 2
quakedef.MOVETYPE_WALK = 3 -- gravity
quakedef.MOVETYPE_STEP = 4 -- gravity, special edge handling
quakedef.MOVETYPE_FLY = 5
quakedef.MOVETYPE_TOSS = 6 -- gravity
quakedef.MOVETYPE_PUSH = 7 -- no clip to world, push and crush
quakedef.MOVETYPE_NOCLIP = 8
quakedef.MOVETYPE_FLYMISSILE = 9 -- extra size to monsters
quakedef.MOVETYPE_BOUNCE = 10

-- edict->flags
quakedef.FL_FLY = 1
quakedef.FL_SWIM = 2
quakedef.FL_CONVEYOR = 4
quakedef.FL_CLIENT = 8
quakedef.FL_INWATER = 16
quakedef.FL_MONSTER = 32
quakedef.FL_GODMODE = 64
quakedef.FL_NOTARGET = 128
quakedef.FL_ITEM = 256
quakedef.FL_ONGROUND = 512
quakedef.FL_PARTIALGROUND = 1024 -- not all corners are valid
quakedef.FL_WATERJUMP = 2048 -- player jumping out of water
quakedef.FL_JUMPRELEASED = 4096 -- for jump debouncing

-- edict->deadflag values
quakedef.DEAD_NO = 0
quakedef.DEAD_DYING = 1
quakedef.DEAD_DEAD = 2

quakedef.DAMAGE_NO = 0
quakedef.DAMAGE_YES = 1
quakedef.DAMAGE_AIM = 2

-- SV_Move types
quakedef.MOVE_NORMAL = 0
quakedef.MOVE_NOMONSTERS = 1
quakedef.MOVE_MISSILE = 2

-- point contents
quakedef.CONTENTS_EMPTY = -1
quakedef.CONTENTS_SOLID = -2
quakedef.CONTENTS_WATER = -3
quakedef.CONTENTS_SLIME = -4
quakedef.CONTENTS_LAVA = -5
quakedef.CONTENTS_SKY = -6
quakedef.CONTENTS_CURRENT_0 = -9
quakedef.CONTENTS_CURRENT_DOWN = -14

-- entity effects
quakedef.EF_BRIGHTFIELD = 1
quakedef.EF_MUZZLEFLASH = 2
quakedef.EF_BRIGHTLIGHT = 4
quakedef.EF_DIMLIGHT = 8

-- item flags (sbar/QC)
quakedef.IT_SHOTGUN = 1
quakedef.IT_SUPER_SHOTGUN = 2
quakedef.IT_NAILGUN = 4
quakedef.IT_SUPER_NAILGUN = 8
quakedef.IT_GRENADE_LAUNCHER = 16
quakedef.IT_ROCKET_LAUNCHER = 32
quakedef.IT_LIGHTNING = 64

quakedef.MAX_EDICTS = 600
quakedef.MAX_DATAGRAM = 1024
quakedef.MAX_MSGLEN = 8000
quakedef.MAX_SOUNDS = 256
quakedef.MAX_MODELS = 256
quakedef.MAX_LIGHTSTYLES = 64
quakedef.MAX_STYLESTRING = 64
quakedef.MAX_SCOREBOARD = 16

-- sound channels
quakedef.CHAN_AUTO = 0
quakedef.CHAN_WEAPON = 1
quakedef.CHAN_VOICE = 2
quakedef.CHAN_ITEM = 3
quakedef.CHAN_BODY = 4

quakedef.ATTN_NONE = 0
quakedef.ATTN_NORM = 1

-- spawnflags
quakedef.SPAWNFLAG_NOT_EASY = 256
quakedef.SPAWNFLAG_NOT_MEDIUM = 512
quakedef.SPAWNFLAG_NOT_HARD = 1024
quakedef.SPAWNFLAG_NOT_DEATHMATCH = 2048

return quakedef
