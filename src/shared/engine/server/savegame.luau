--!strict
-- Savegames — Host_Savegame_f / Host_Loadgame_f with the exact .sav text
-- format (SAVEGAME_VERSION 5): version, comment, 16 spawn parms, skill,
-- map name, time, 64 lightstyles, ED_WriteGlobals, then every edict via
-- ED_Write. Loading reuses ED_ParseEpair so function/field/entity values
-- round-trip. Storage is the caller's concern (no filesystem here).

local com = require("../common/com")
local cvarlib = require("../common/cvar")
local defs = require("../progs/defs")
local progslib = require("../progs/progs")
local vmlib = require("../progs/vm")
local world = require("./world")

local savegame = {}

local SAVEGAME_VERSION = 5
local NUM_SPAWN_PARMS = 16
local MAX_LIGHTSTYLES = 64

-- words per etype (type_size)
local function typeSize(typ: number): number
	return if typ == defs.ev_vector then 3 else 1
end

-- PR_UglyValueString: parseable value formatting
local function uglyValue(vm: vmlib.VM, typ: number, src: buffer, ofs: number): string
	typ = bit32.band(typ, 0x7fff)
	if typ == defs.ev_string then
		return vmlib.getString(vm, buffer.readi32(src, ofs * 4))
	elseif typ == defs.ev_entity then
		return tostring(buffer.readi32(src, ofs * 4))
	elseif typ == defs.ev_function then
		local fnum = buffer.readi32(src, ofs * 4)
		local fn = vm.progs.functions[fnum + 1]
		return if fn then fn.name else ""
	elseif typ == defs.ev_field then
		local fofs = buffer.readi32(src, ofs * 4)
		for _, d in vm.progs.fielddefs do
			if d.ofs == fofs then
				return d.name
			end
		end
		return ""
	elseif typ == defs.ev_void then
		return "void"
	elseif typ == defs.ev_float then
		return ("%f"):format(buffer.readf32(src, ofs * 4))
	elseif typ == defs.ev_vector then
		return ("%f %f %f"):format(
			buffer.readf32(src, ofs * 4),
			buffer.readf32(src, ofs * 4 + 4),
			buffer.readf32(src, ofs * 4 + 8)
		)
	end
	return "bad type " .. typ
end

local function fieldIsZero(src: buffer, ofs: number, words: number): boolean
	for j = 0, words - 1 do
		if buffer.readi32(src, (ofs + j) * 4) ~= 0 then
			return false
		end
	end
	return true
end

-- ED_Write
local function writeEdict(vm: vmlib.VM, ed: vmlib.Edict, out: { string })
	table.insert(out, "{\n")
	if not ed.free then
		for _, d in vm.progs.fielddefs do
			local name = d.name
			if #name >= 2 and name:sub(-2, -2) == "_" then
				continue -- skip _x, _y, _z vars
			end
			local typ = bit32.band(d.type, 0x7fff)
			if fieldIsZero(ed.fields, d.ofs, typeSize(typ)) then
				continue
			end
			table.insert(out, ('"%s" "%s"\n'):format(name, uglyValue(vm, typ, ed.fields, d.ofs)))
		end
	end
	table.insert(out, "}\n")
end

-- ED_WriteGlobals
local function writeGlobals(vm: vmlib.VM, out: { string })
	table.insert(out, "{\n")
	for _, d in vm.progs.globaldefs do
		if bit32.band(d.type, defs.DEF_SAVEGLOBAL) == 0 then
			continue
		end
		local typ = bit32.band(d.type, 0x7fff)
		if typ ~= defs.ev_string and typ ~= defs.ev_float and typ ~= defs.ev_entity then
			continue
		end
		table.insert(out, ('"%s" "%s"\n'):format(d.name, uglyValue(vm, typ, vm.globals, d.ofs)))
	end
	table.insert(out, "}\n")
end

-- Host_SavegameComment: level name + kills, 39 chars, spaces as _
function savegame.comment(svr: any): string
	local vm = svr.vm
	local levelname = vmlib.edString(vm, vm.edicts[1], defs.ent.message)
	local kills = ("kills:%3i/%3i"):format(
		vmlib.globalFloat(vm, defs.glob.killed_monsters),
		vmlib.globalFloat(vm, defs.glob.total_monsters)
	)
	local text = ("%-21s %s"):format(levelname:sub(1, 21), kills)
	text = ("%-39s"):format(text):sub(1, 39)
	return (text:gsub(" ", "_"))
end

-- Host_Savegame_f (minus the file I/O)
function savegame.write(svr: any): string
	local vm = svr.vm
	local out: { string } = {}
	table.insert(out, ("%i\n"):format(SAVEGAME_VERSION))
	table.insert(out, savegame.comment(svr) .. "\n")
	local parms = svr.clients[1].spawn_parms
	for i = 1, NUM_SPAWN_PARMS do
		table.insert(out, ("%f\n"):format(parms[i] or 0))
	end
	table.insert(out, ("%d\n"):format(cvarlib.value(svr.cvars, "skill")))
	table.insert(out, svr.modelname:match("maps/(.+)%.bsp") .. "\n")
	table.insert(out, ("%f\n"):format(svr.time))
	for i = 0, MAX_LIGHTSTYLES - 1 do
		table.insert(out, (svr.lightstyles[i] or "m") .. "\n")
	end
	writeGlobals(vm, out)
	for i = 0, vm.num_edicts - 1 do
		writeEdict(vm, vm.edicts[i + 1], out)
	end
	return table.concat(out)
end

-- ED_ParseGlobals / the edict-restore loop from Host_Loadgame_f.
-- spawnMap is host.spawnServer partially applied by the caller.
function savegame.load(svr: any, text: string, spawnMap: (mapname: string) -> ()): boolean
	local pos = 1
	local function line(): string
		local e = text:find("\n", pos, true)
		if not e then
			local rest = text:sub(pos)
			pos = #text + 1
			return rest
		end
		local l = text:sub(pos, e - 1)
		pos = e + 1
		return (l:gsub("\r$", ""))
	end

	local version = tonumber(line())
	if version ~= SAVEGAME_VERSION then
		svr.print(`Savegame is version {version}, not {SAVEGAME_VERSION}`)
		return false
	end
	line() -- comment
	local parms = table.create(NUM_SPAWN_PARMS, 0)
	for i = 1, NUM_SPAWN_PARMS do
		parms[i] = tonumber(line()) or 0
	end
	local skill = tonumber(line()) or 1
	cvarlib.setValue(svr.cvars, "skill", skill)
	local mapname = line()
	local time = tonumber(line()) or 0

	spawnMap(mapname)
	if not svr.active then
		svr.print("Couldn't load map")
		return false
	end
	svr.paused = true -- pause until all clients connect
	svr.loadgame = true

	for i = 0, MAX_LIGHTSTYLES - 1 do
		svr.lightstyles[i] = line()
	end

	-- load the edicts out of the savegame file
	local vm = svr.vm
	local entnum = -1 -- -1 is the globals block
	local rest = text:sub(pos)
	local p = 1
	while true do
		local token
		token, p = com.parse(rest, p)
		if not token or token == "" then
			break
		end
		if token ~= "{" then
			svr.print("First token isn't a brace")
			return false
		end

		if entnum == -1 then
			-- parse the global vars
			while true do
				local key
				key, p = com.parse(rest, p)
				if not key or key == "}" then
					break
				end
				local value
				value, p = com.parse(rest, p)
				if value == nil then
					break
				end
				local d = vm.progs.globaldefsByName[key]
				if d then
					vmlib.parseEpair(vm, vm.globals, d, value :: string)
				end
			end
		else
			-- parse an edict
			local ed = vmlib.edictNum(vm, entnum)
			buffer.fill(ed.fields, 0, 0, vm.progs.entityfields * 4)
			ed.free = false
			p = vmlib.parseEdict(vm, rest, p, ed)
			if not ed.free then
				world.linkEdict(svr.world, ed, false)
			end
		end
		entnum += 1
	end

	vm.num_edicts = entnum
	svr.time = time
	local client = svr.clients[1]
	for i = 1, NUM_SPAWN_PARMS do
		client.spawn_parms[i] = parms[i]
	end
	return true
end

return savegame
