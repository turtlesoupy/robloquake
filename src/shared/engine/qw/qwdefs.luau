--!strict
-- QW progs ABI — built from qwprogs.dat's own globaldefs/fielddefs at load
-- time instead of hardcoded offsets (the QW entvars layout differs from
-- NetQuake's; deriving by name keeps us honest against any qwprogs build).

local progslib = require("../progs/progs")

local qwdefs = {}

export type QwDefs = {
	glob: { [string]: number },
	ent: { [string]: number },
	func: { [string]: number },
}

-- pr_global_struct members the QW server reads/writes (progdefs.h)
local REQUIRED_GLOBALS = {
	"self", "other", "world", "time", "frametime", "newmis", "force_retouch",
	"mapname", "serverflags", "total_secrets", "total_monsters",
	"found_secrets", "killed_monsters",
	"parm1", "parm2", "parm3", "parm4", "parm5", "parm6", "parm7", "parm8",
	"parm9", "parm10", "parm11", "parm12", "parm13", "parm14", "parm15", "parm16",
	"v_forward", "v_up", "v_right",
	"trace_allsolid", "trace_startsolid", "trace_fraction", "trace_endpos",
	"trace_plane_normal", "trace_plane_dist", "trace_ent", "trace_inopen",
	"trace_inwater", "msg_entity",
}

-- entry points (function globals in progdefs.h)
local REQUIRED_FUNCS = {
	"main", "StartFrame", "PlayerPreThink", "PlayerPostThink",
	"ClientKill", "ClientConnect", "PutClientInServer", "ClientDisconnect",
	"SetNewParms", "SetChangeParms",
}
local OPTIONAL_FUNCS = { "SpectatorConnect", "SpectatorThink", "SpectatorDisconnect" }

-- entvars_t members the QW server touches
local REQUIRED_FIELDS = {
	"modelindex", "absmin", "absmax", "ltime", "lastruntime",
	"movetype", "solid", "origin", "oldorigin", "velocity", "angles",
	"avelocity", "classname", "model", "frame", "skin", "effects",
	"mins", "maxs", "size", "touch", "use", "think", "blocked", "nextthink",
	"groundentity", "health", "frags", "weapon", "weaponmodel",
	"weaponframe", "currentammo", "ammo_shells", "ammo_nails",
	"ammo_rockets", "ammo_cells", "items", "takedamage", "chain",
	"deadflag", "view_ofs", "button0", "button1", "button2", "impulse",
	"fixangle", "v_angle", "netname", "enemy", "flags", "colormap",
	"team", "max_health", "teleport_time", "armortype", "armorvalue",
	"waterlevel", "watertype", "ideal_yaw", "yaw_speed", "aiment",
	"goalentity", "spawnflags", "target", "targetname", "dmg_take",
	"dmg_save", "dmg_inflictor", "owner", "movedir", "message", "sounds",
	"noise", "noise1", "noise2", "noise3",
}

function qwdefs.build(progs: progslib.Progs): QwDefs
	local glob: { [string]: number } = {}
	local ent: { [string]: number } = {}
	local func: { [string]: number } = {}

	for _, name in REQUIRED_GLOBALS do
		local d = progs.globaldefsByName[name]
		if not d then
			error(`qwprogs missing required global {name}`)
		end
		glob[name] = d.ofs
	end
	-- deathmatch/teamplay/timelimit/fraglimit are named cvar mirrors in QW
	for _, name in { "deathmatch", "teamplay", "timelimit", "fraglimit" } do
		local d = progs.globaldefsByName[name]
		if d then
			glob[name] = d.ofs
		end
	end

	for _, name in REQUIRED_FIELDS do
		local d = progs.fielddefsByName[name]
		if not d then
			error(`qwprogs missing required field {name}`)
		end
		ent[name] = d.ofs
	end

	-- GetEdictFieldValue lookups: QC-defined fields the server reads
	-- opportunistically (nil when the progs don't define them)
	local optfield: { [string]: number } = {}
	for _, name in { "gravity", "maxspeed" } do
		local d = progs.fielddefsByName[name]
		if d then
			optfield[name] = d.ofs
		end
	end

	for _, name in REQUIRED_FUNCS do
		local fnum = progs.functionsByName[name]
		if not fnum then
			error(`qwprogs missing required function {name}`)
		end
		func[name] = fnum
	end
	for _, name in OPTIONAL_FUNCS do
		local fnum = progs.functionsByName[name]
		if fnum then
			func[name] = fnum
		end
	end

	return { glob = glob, ent = ent, func = func, optfield = optfield }
end

return qwdefs
