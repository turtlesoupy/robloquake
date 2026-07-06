--!strict
-- Inspect and switch the dev mode preset from the terminal:
--   lune run tools/mode              -> show active preset + all states
--   lune run tools/mode qw-dm        -> activate a preset
--   lune run tools/mode off          -> disable presets (place attrs rule)
-- The switch rewrites src/server/modeconfig.luau; rojo syncs it live and
-- the next Play session boots into that state.

local fs = require("@lune/fs")
local process = require("@lune/process")

local modepresets = require("../src/server/modepresets")

local CONFIG_PATH = "src/server/modeconfig.luau"

local function currentPreset(): string?
	local src = fs.readFile(CONFIG_PATH)
	return src:match('return%s+"([%w%-]+)"')
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
	local preset = modepresets.PRESETS[name] :: { [string]: any }
	local parts = {}
	for _, key in modepresets.KEYS do
		if preset[key] ~= nil then
			table.insert(parts, `{key}={tostring(preset[key])}`)
		end
	end
	return table.concat(parts, "  ")
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
	print("\nswitch: lune run tools/mode <preset>   disable: lune run tools/mode off")
elseif arg == "off" then
	writeConfig(nil)
	print("presets disabled — the place's QuakeAssets attributes rule")
elseif modepresets.PRESETS[arg] then
	writeConfig(arg)
	print(`active preset -> {arg}`)
	print(`  {describe(arg)}`)
	print("restart the Play session (rojo syncs the config) to boot into it")
else
	print(`unknown preset "{arg}"`)
	process.exit(1)
end
