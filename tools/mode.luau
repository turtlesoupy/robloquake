--!strict
-- Inspect and switch the dev mode preset from the terminal:
--   lune run tools/mode              -> show active preset + all states
--   lune run tools/mode qw-dm        -> activate a preset
--   lune run tools/mode ctf+original -> preset with modifier overlays
--                                       (modifiers compose over ANY preset)
--   lune run tools/mode off          -> disable presets (place attrs rule)
--   lune run tools/mode stamp qw-dm  -> print a Studio command-bar snippet
--                                       that writes the preset's attributes
--                                       onto ServerStorage.QuakeAssets
--   lune run tools/mode assets qw-dm -> write assets-current.project.json
--                                       scoped to EXACTLY the game folders
--                                       the preset needs + print the serve
--                                       and (publish-only) strip steps
-- The switch rewrites src/server/modeconfig.luau; rojo syncs it live and
-- the next Play session boots into that state. `stamp` is for places that
-- run with presets off (ship mode): attributes live in the place, so bake
-- the chosen state in and save — never hand-type attribute sets.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local modepresets = require("../src/server/modepresets")

local CONFIG_PATH = "src/server/modeconfig.luau"

local function currentPreset(): string?
	local src = fs.readFile(CONFIG_PATH)
	return src:match('return%s+"([%w%-+]+)"')
end

local function writeConfig(name: string?)
	local value = if name then `"{name}"` else "nil"
	fs.writeFile(
		CONFIG_PATH,
		"--!strict\n"
			.. "-- ACTIVE dev mode preset (see modepresets.luau; managed by\n"
			.. "-- `lune run tools/mode <preset|off>`). nil = presets disabled: the\n"
			.. "-- place's own QuakeAssets attributes rule (how shipped places run).\n"
			.. `return {value} :: string?\n`
	)
end

local function describe(name: string): string
	local preset = modepresets.resolve(name) :: { [string]: any }
	local parts = {}
	for _, key in modepresets.KEYS do
		if preset[key] ~= nil then
			table.insert(parts, `{key}={tostring(preset[key])}`)
		end
	end
	return table.concat(parts, "  ")
end

-- one SetAttribute line per KEY, mirroring modepresets.apply exactly:
-- absent keys are cleared (nil), so the stamped place == the preset
local function stampSnippet(name: string): string
	local preset = modepresets.resolve(name) :: { [string]: any }
	local lines = { 'local a = game:GetService("ServerStorage").QuakeAssets' }
	for _, key in modepresets.KEYS do
		local v = preset[key]
		local lit: string
		if v == nil then
			lit = "nil"
		elseif type(v) == "string" then
			lit = string.format("%q", v)
		else -- number | boolean
			lit = tostring(v)
		end
		table.insert(lines, `a:SetAttribute("{key}", {lit})`)
	end
	table.insert(lines, `print("QuakeAssets stamped: {name}")`)
	return table.concat(lines, " ")
end

-- the QuakeAssets game folders a preset actually reads at boot:
-- base game (init.server defaults absent `game` to id1) + optional mod dir
local function neededGames(name: string): { string }
	local state = modepresets.resolve(name) :: { [string]: any }
	local games = { if type(state.game) == "string" then state.game else "id1" }
	if type(state.gamedir) == "string" and state.gamedir ~= games[1] then
		table.insert(games, state.gamedir)
	end
	return games
end

local ASSETS_PROJECT = "assets-current.project.json"

local function writeAssetsProject(name: string): { string }
	local games = neededGames(name)
	local quakeAssets: { [string]: any } = { ["$className"] = "Folder" }
	for _, g in games do
		quakeAssets[g] = { ["$path"] = `assets/{g}` }
	end
	fs.writeFile(
		ASSETS_PROJECT,
		serde.encode("json", {
			name = "robloquake-assets-current",
			tree = {
				["$className"] = "DataModel",
				ServerStorage = { QuakeAssets = quakeAssets },
			},
		}, true) .. "\n"
	)
	return games
end

-- publish-only: delete every QuakeAssets game folder the preset does NOT
-- need (licensing: shipped places must hold lq1 only — docs/PUBLISHING.md)
local function stripSnippet(games: { string }): string
	local keep = {}
	for _, g in games do
		table.insert(keep, `["{g}"]=true`)
	end
	return `local keep={"{"}{table.concat(keep, ",")}{"}"} `
		.. `local qa=game:GetService("ServerStorage").QuakeAssets `
		.. `for _,c in qa:GetChildren() do if not keep[c.Name] then c:Destroy() end end `
		.. `print("QuakeAssets stripped to: {table.concat(games, " + ")}")`
end

local arg = process.args[1]
if not arg then
	local active = currentPreset()
	print(`active preset: {active or "off (place attributes rule)"}\n`)
	local names = {}
	for name in modepresets.PRESETS :: { [string]: any } do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local marker = if name == active then ">" else " "
		print(`{marker} {name}`)
		print(`    {describe(name)}`)
	end
	local mods = {}
	for name in modepresets.MODIFIERS :: { [string]: any } do
		table.insert(mods, name)
	end
	table.sort(mods)
	print("\nmodifiers (compose over any preset with +):")
	for _, name in mods do
		local parts = {}
		for key, value in (modepresets.MODIFIERS :: { [string]: { [string]: any } })[name] do
			table.insert(parts, `{key}={tostring(value)}`)
		end
		table.sort(parts)
		print(`  +{name}    {table.concat(parts, "  ")}`)
	end
	print("\nswitch: lune run tools/mode <preset>[+modifier]   disable: lune run tools/mode off")
elseif arg == "stamp" then
	local name = process.args[2]
	if not name or not modepresets.resolve(name) then
		print(`usage: lune run tools/mode stamp <preset>[+modifier]   (unknown preset "{name or ""}")`)
		process.exit(1)
	end
	print(`-- paste into the Studio command bar, then SAVE the place:`)
	print(stampSnippet(name :: string))
elseif arg == "assets" then
	local name = process.args[2]
	if not name or not modepresets.resolve(name) then
		print(`usage: lune run tools/mode assets <preset>[+modifier]   (unknown preset "{name or ""}")`)
		process.exit(1)
	end
	local games = writeAssetsProject(name :: string)
	print(`{ASSETS_PROJECT} -> QuakeAssets needs: {table.concat(games, " + ")}`)
	for _, g in games do
		if not fs.isDir(`assets/{g}`) then
			print(`  MISSING assets/{g} on disk — build it first: tools/sync_assets.sh {g}`)
		end
	end
	print("\nimport into the place (adds/refreshes ONLY these folders):")
	print(`  pkill -f "rojo serve"; rojo serve {ASSETS_PROJECT}`)
	print("  Studio Rojo plugin: Connect -> accept patch -> Disconnect")
	print('  then restore the code serve: pkill -f "rojo serve"; rojo serve')
	print("\npublish-only STRIP (deletes the other game folders from the place):")
	print(`  {stripSnippet(games)}`)
elseif arg == "off" then
	writeConfig(nil)
	print("presets disabled — the place's QuakeAssets attributes rule")
elseif modepresets.resolve(arg) then
	writeConfig(arg)
	print(`active preset -> {arg}`)
	print(`  {describe(arg)}`)
	print(`  QuakeAssets folders read at boot: {table.concat(neededGames(arg), " + ")}`)
	print("restart the Play session (rojo syncs the config) to boot into it")
else
	print(`unknown preset "{arg}"`)
	process.exit(1)
end
