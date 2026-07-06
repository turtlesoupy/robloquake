--!strict
-- Mode presets as CODE (dev source of truth; see docs/MODES.md).
-- A preset is the COMPLETE attribute state for QuakeAssets: applying one
-- writes every key in KEYS (absent = cleared), so the running state is
-- always exactly what this file says — no residue from earlier states,
-- nothing hand-edited in Roblox. Shipped places set modeconfig to nil
-- and own their attributes per-place instead.
-- Switch/inspect from the terminal: `lune run tools/mode [preset|off]`.

local modepresets = {}

-- the full parameter set (MODES.md); every preset key must be one of these
modepresets.KEYS = {
	"engine",
	"game",
	"gamedir",
	"startmap",
	"deathmatch",
	"coop",
	"skill",
	"teamplay",
	"fraglimit",
	"timelimit",
	"samelevel",
	"noexit",
	"maplist",
	"votetime",
	-- default ON when absent (avatarrigs mirror); presets set false to opt out
	"roblox_avatars",
}

local DM_RULES = {
	deathmatch = 1,
	fraglimit = 15,
	timelimit = 20,
	maplist = "dm3 dm4 dm6 dm2",
	votetime = 30,
	startmap = "dm3",
}

modepresets.PRESETS = {
	-- single player / coop campaign: authentic exit chain, no director
	campaign = {
		engine = "nq",
		game = "id1",
		startmap = "start",
	},
	["nq-dm"] = {
		engine = "nq",
		game = "id1",
		deathmatch = DM_RULES.deathmatch,
		fraglimit = DM_RULES.fraglimit,
		timelimit = DM_RULES.timelimit,
		maplist = DM_RULES.maplist,
		votetime = DM_RULES.votetime,
		startmap = DM_RULES.startmap,
	},
	["qw-dm"] = {
		engine = "qw",
		game = "id1",
		deathmatch = DM_RULES.deathmatch,
		fraglimit = DM_RULES.fraglimit,
		timelimit = DM_RULES.timelimit,
		maplist = DM_RULES.maplist,
		votetime = DM_RULES.votetime,
		startmap = DM_RULES.startmap,
	},
	-- Threewave CTF on QW (the verified mod path: tests/test_scenario_ctf
	-- + qw-ctf2m3 evidence); pak ships ctf1..ctf8
	ctf = {
		engine = "qw",
		game = "id1",
		gamedir = "threewave",
		-- threewave overloads teamplay as a bitfield: 256 enables CTF (flags
		-- don't spawn without it). 419 = the mod's shipped server.cfg value
		-- (health+armor protect, color lock, drop items, CTF)
		teamplay = 419,
		deathmatch = 1,
		fraglimit = 15,
		timelimit = 20,
		startmap = "ctf1",
		maplist = "ctf1 ctf2 ctf3 ctf4 ctf5",
		votetime = 30,
	},
	-- Rocket Arena (QW): manages its own rotation via localinfo (the mod's
	-- rotate.cfg, applied at qwserver boot) — no maplist, so the director
	-- stays out of its way. Startmap must be IN the rotate.cfg cycle;
	-- limits per raserver.txt's recommended command line
	arena = {
		engine = "qw",
		game = "id1",
		gamedir = "arena",
		deathmatch = 1,
		fraglimit = 15,
		timelimit = 20,
		startmap = "crandome",
	},
	instagib = {
		engine = "nq",
		game = "id1",
		gamedir = "instagib",
		deathmatch = DM_RULES.deathmatch,
		fraglimit = DM_RULES.fraglimit,
		timelimit = DM_RULES.timelimit,
		maplist = DM_RULES.maplist,
		votetime = DM_RULES.votetime,
		startmap = DM_RULES.startmap,
	},
}

-- apply a preset onto the assets folder: every KEY is written (nil
-- clears), so state == preset exactly
function modepresets.apply(assets: Instance, name: string): boolean
	local preset = modepresets.PRESETS[name]
	if not preset then
		return false
	end
	for _, key in modepresets.KEYS do
		assets:SetAttribute(key, (preset :: { [string]: any })[key])
	end
	return true
end

return modepresets
