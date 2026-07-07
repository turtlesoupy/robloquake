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
-- The switch rewrites src/server/modeconfig.luau; rojo syncs it live and
-- the next Play session boots into that state. `stamp` is for places that
-- run with presets off (ship mode): attributes live in the place, so bake
-- the chosen state in and save — never hand-type attribute sets.

local fs = require("@lune/fs")
local process = require("@lune/process")

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
elseif arg == "off" then
	writeConfig(nil)
	print("presets disabled — the place's QuakeAssets attributes rule")
elseif modepresets.resolve(arg) then
	writeConfig(arg)
	print(`active preset -> {arg}`)
	print(`  {describe(arg)}`)
	print("restart the Play session (rojo syncs the config) to boot into it")
else
	print(`unknown preset "{arg}"`)
	process.exit(1)
end
