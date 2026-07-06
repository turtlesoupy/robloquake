--!strict
-- Console variables — minimal port of cvar.c: a name -> value registry with
-- the variables the server/game code reads. Values are kept as strings with
-- a parsed float, like the C engine.

local cvar = {}

export type Cvars = {
	vars: { [string]: { string: string, value: number } },
	print: (s: string) -> (),
}

local DEFAULTS: { [string]: string } = {
	-- sv_phys / sv_user
	sv_friction = "4",
	sv_stopspeed = "100",
	sv_gravity = "800",
	sv_maxvelocity = "2000",
	sv_nostep = "0",
	sv_maxspeed = "320",
	sv_accelerate = "10",
	edgefriction = "2",
	sv_idealpitchscale = "0.8",
	sv_aim = "0.93",
	-- game rules
	teamplay = "0",
	skill = "1",
	deathmatch = "0",
	coop = "0",
	noexit = "0",
	samelevel = "0",
	fraglimit = "0",
	timelimit = "0",
	pausable = "1",
	temp1 = "0",
	-- registered by PR_Init
	nomonsters = "0",
	gamecfg = "0",
	scratch1 = "0",
	scratch2 = "0",
	scratch3 = "0",
	scratch4 = "0",
	savedgamecfg = "0",
	saved1 = "0",
	saved2 = "0",
	saved3 = "0",
	saved4 = "0",
	-- misc read by QC
	registered = "0", -- shareware!
	hostname = "robloquake",
}

function cvar.new(): Cvars
	local c: Cvars = { vars = {}, print = print }
	for name, value in DEFAULTS do
		c.vars[name] = { string = value, value = tonumber(value) or 0 }
	end
	return c
end

-- Cvar_VariableValue
function cvar.value(c: Cvars, name: string): number
	local v = c.vars[name]
	return if v then v.value else 0
end

function cvar.string(c: Cvars, name: string): string
	local v = c.vars[name]
	return if v then v.string else ""
end

-- Cvar_Set
function cvar.set(c: Cvars, name: string, value: string)
	local v = c.vars[name]
	if not v then
		c.print(`Cvar_Set: variable {name} not found`)
		c.vars[name] = { string = value, value = tonumber(value) or 0 }
		return
	end
	v.string = value
	v.value = tonumber(value) or 0
end

function cvar.setValue(c: Cvars, name: string, value: number)
	-- Cvar_SetValue formats with %f in C; strip trailing zeros like most ports
	cvar.set(c, name, if value == math.floor(value) then tostring(value) else string.format("%f", value))
end

-- Cvar_CompleteVariable: exact match wins, then the first prefix match.
-- Delta: C scans registration order; the hash map is sorted by name for
-- a deterministic "first".
function cvar.completeVariable(c: Cvars, partial: string): string?
	if partial == "" then
		return nil
	end
	if c.vars[partial] then
		return partial
	end
	local names = {}
	for name in c.vars do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if name:sub(1, #partial) == partial then
			return name
		end
	end
	return nil
end

return cvar
