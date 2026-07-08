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
	-- sbar face = local player's avatar head (avatarrigs mirror, hud.luau).
	-- absent = follows roblox_avatars; explicit boolean forces either way
	-- (false = the original gfx.wad face bitmaps even in avatars mode)
	"avatar_face",
	-- content softening: white gibs/blood, corpses fade (render-only).
	-- default ON when absent (clientbundle mirror); set false for the
	-- original engine presentation
	"mildmode",
	-- stats/leaderboard scope label; absent = derived (statscore.deriveModeKey)
	"modekey",
}

local DM_RULES = {
	deathmatch = 1,
	fraglimit = 15,
	-- classic Quake DM server convention (id's stock configs ran 10)
	timelimit = 10,
	-- everything the synced pak1 ships (dm1..dm6)
	maplist = "dm1 dm2 dm3 dm4 dm5 dm6",
	votetime = 15,
	startmap = "dm3",
}

modepresets.PRESETS = {
	-- single player / coop campaign: authentic exit chain, no director
	campaign = {
		engine = "nq",
		game = "id1",
		startmap = "start",
		modekey = "campaign",
	},
	-- two-player coop on the id1 campaign — monsters present AND friendly
	-- fire on (the demo-reel setup). coop=1 makes host.luau force
	-- deathmatch=0, so QuakeC keeps monsters and vm.loadFromFile doesn't
	-- strip NOT_DEATHMATCH-flagged entities; teamplay absent (=0) leaves
	-- player-vs-player damage on, so a buddy can walk up and shoot you. No
	-- maplist -> authentic exit chain (director stays out). startmap=e1m3
	-- (The Necropolis) is the demo1.dem Ogre level. Requires a real id1 pak
	-- at runtime: LibreQuake ships no monster/campaign maps, so `+librequake`
	-- is NOT a supported overlay here.
	coop = {
		engine = "nq",
		game = "id1",
		startmap = "e1m3",
		coop = 1,
		modekey = "coop",
	},
	["nq-dm"] = {
		engine = "nq",
		game = "id1",
		modekey = "dm",
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
		modekey = "dm",
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
		modekey = "ctf",
		gamedir = "threewave",
		-- threewave overloads teamplay as a bitfield: 256 enables CTF (flags
		-- don't spawn without it). 419 = the mod's shipped server.cfg value
		-- (health+armor protect, color lock, drop items, CTF)
		teamplay = 419,
		deathmatch = 1,
		fraglimit = 15,
		timelimit = 20,
		startmap = "ctf1",
		-- everything the synced paks ship: ctf1..ctf8 (pak0) + the
		-- Capture II series ctf2m1..ctf2m8 (pak1); ctfstart is the mod's
		-- hub map, not a match map
		maplist = "ctf1 ctf2 ctf3 ctf4 ctf5 ctf6 ctf7 ctf8 ctf2m1 ctf2m2 ctf2m3 ctf2m4 ctf2m5 ctf2m6 ctf2m7 ctf2m8",
		votetime = 15,
	},
	-- Rocket Arena (QW): manages its own rotation via localinfo (the mod's
	-- rotate.cfg, applied at qwserver boot) — no maplist, so the director
	-- stays out of its way. Startmap must be IN the rotate.cfg cycle;
	-- limits per raserver.txt's recommended command line
	arena = {
		engine = "qw",
		game = "id1",
		modekey = "arena",
		gamedir = "arena",
		deathmatch = 1,
		fraglimit = 15,
		timelimit = 20,
		startmap = "crandome",
	},
	-- Team Fortress 2.9 (QWTF) on QW — LOCAL/DEV ONLY, never publishable
	-- (docs/mods-licenses.md: Valve IP, non-commercial license). Verified
	-- offline by tests/test_scenario_tf.luau. Players spawn as observers:
	-- join a team with impulse 140/141, pick a class with impulse 100+class
	-- (101 scout .. 109 engineer) or the "changeclass" menu (impulse 99).
	tf = {
		engine = "qw",
		game = "id1",
		modekey = "tf",
		gamedir = "fortress",
		-- TF overloads teamplay as its own bitfield (qwserver.txt): 21 =
		-- on + no direct-fire damage + no area damage between teammates
		teamplay = 21,
		-- deathmatch 3 = TF's "players may change class mid-game" setting
		-- (also the mod's shipped server.cfg value)
		deathmatch = 3,
		fraglimit = 100,
		timelimit = 30,
		-- the one TF map staged (2fort5, the classic); add more under
		-- external_assets/fortress/maps and rebuild to extend
		maplist = "2fort5",
		startmap = "2fort5",
	},
	instagib = {
		engine = "nq",
		game = "id1",
		modekey = "instagib",
		gamedir = "instagib",
		deathmatch = DM_RULES.deathmatch,
		fraglimit = DM_RULES.fraglimit,
		timelimit = DM_RULES.timelimit,
		maplist = DM_RULES.maplist,
		votetime = DM_RULES.votetime,
		startmap = DM_RULES.startmap,
	},
	-- LibreQuake base + Threewave CTF overlay: the ctf preset's rules and
	-- maps with lq1 replacing id1 as the base game (asset fallthrough:
	-- threewave paks first, then lq1 — same-named replacements resolve).
	-- Threewave ships under Zoid's permission (docs/mods-licenses.md), so
	-- unlike plain `ctf` this is publishable. NOT `ctf+librequake` — that
	-- modifier swaps in the lqdm maplist, which has no flag spawns.
	["lq-ctf"] = {
		engine = "qw",
		game = "lq1",
		modekey = "ctf",
		gamedir = "threewave",
		-- teamplay bitfield per the ctf preset: 419 = mod's shipped
		-- server.cfg value (health+armor protect, color lock, drop items, CTF)
		teamplay = 419,
		deathmatch = 1,
		fraglimit = 15,
		timelimit = 20,
		startmap = "ctf1",
		maplist = "ctf1 ctf2 ctf3 ctf4 ctf5 ctf6 ctf7 ctf8 ctf2m1 ctf2m2 ctf2m3 ctf2m4 ctf2m5 ctf2m6 ctf2m7 ctf2m8",
		votetime = 15,
	},
	-- LibreQuake (copyright-free content, game=lq1): the NQ DM setup on
	-- the lqdm* maps; weapon model names match id1 (v_shot.mdl etc.)
	["lq-dm"] = {
		engine = "nq",
		game = "lq1",
		deathmatch = DM_RULES.deathmatch,
		fraglimit = DM_RULES.fraglimit,
		timelimit = DM_RULES.timelimit,
		-- full lqdm1..13 rotation. NOTE: the heavy maps (lqdm3/13/6, and
		-- to a lesser extent lqdm5/9) can starve Studio's EditableMesh
		-- budget; verify them in play mode before relying on them.
		maplist = "lqdm1 lqdm2 lqdm3 lqdm4 lqdm5 lqdm6 lqdm7 lqdm8 lqdm9 lqdm10 lqdm11 lqdm12 lqdm13",
		votetime = DM_RULES.votetime,
		startmap = "lqdm1",
		roblox_avatars = true,
	},
}

-- modifiers: composable overlays that apply over ANY preset as
-- "<preset>+<modifier>" (e.g. qw-dm+original, campaign+original via
-- tools/mode); every key must be in KEYS
modepresets.MODIFIERS = {
	-- the original engine presentation (red gibs/blood, persistent
	-- corpses): opts out of the mildmode default for parity captures
	original = { mildmode = false },
	-- LibreQuake content (copyright-free, game=lq1) over any preset's
	-- rules, e.g. qw-dm+librequake / nq-dm+librequake. lq1 shares no map
	-- names with id1 except start.bsp, so the full lqdm1..13 rotation must
	-- come along. NOTE: the heavy maps (lqdm3/13/6, and to a lesser extent
	-- lqdm5/9) can starve Studio's EditableMesh budget; verify in play mode.
	-- DM oriented — campaign+librequake would need its own startmap/exit
	-- chain and is not a supported combination; for CTF use the dedicated
	-- lq-ctf preset (this modifier's lqdm maplist has no flag spawns).
	librequake = {
		game = "lq1",
		maplist = "lqdm1 lqdm2 lqdm3 lqdm4 lqdm5 lqdm6 lqdm7 lqdm8 lqdm9 lqdm10 lqdm11 lqdm12 lqdm13",
		startmap = "lqdm1",
	},
}

-- resolve "<preset>[+modifier...]" into the complete attribute state;
-- nil when the preset or any modifier is unknown
function modepresets.resolve(name: string): { [string]: any }?
	local parts = string.split(name, "+")
	local preset = modepresets.PRESETS[parts[1]]
	if not preset then
		return nil
	end
	local state = table.clone(preset :: { [string]: any })
	for i = 2, #parts do
		local mod = (modepresets.MODIFIERS :: { [string]: { [string]: any } })[parts[i]]
		if not mod then
			return nil
		end
		for key, value in mod do
			state[key] = value
		end
	end
	return state
end

-- apply a preset (+modifiers) onto the assets folder: every KEY is
-- written (nil clears), so state == the resolved preset exactly
function modepresets.apply(assets: Instance, name: string): boolean
	local state = modepresets.resolve(name)
	if not state then
		return false
	end
	for _, key in modepresets.KEYS do
		assets:SetAttribute(key, state[key])
	end
	return true
end

return modepresets
