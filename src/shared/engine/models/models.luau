--!strict
--!optimize 2
-- Model registry — port of Mod_ForName / Mod_LoadModel dispatch from
-- model.c. Loads brush, alias, and sprite models from the VFS and caches
-- them by name; a BSP's "*n" submodels are registered when it loads.

local vfslib = require("../common/vfs")
local bsp = require("../bsp/bsp")
local mdl = require("./mdl")
local spr = require("./spr")

local models = {}

export type Model = {
	name: string,
	kind: "brush" | "alias" | "sprite",
	brush: bsp.Model?,
	alias: mdl.AliasModel?,
	sprite: spr.SpriteModel?,
	mins: vector,
	maxs: vector,
	numframes: number,
	flags: number,
	synctype: number,
}

export type Registry = {
	fs: vfslib.Vfs,
	byName: { [string]: Model },
}

function models.newRegistry(fs: vfslib.Vfs): Registry
	return { fs = fs, byName = {} }
end

-- Mod_ForName
function models.forName(reg: Registry, name: string, crash: boolean): Model?
	local cached = reg.byName[name]
	if cached then
		return cached
	end

	if name:sub(1, 1) == "*" then
		error(`Mod_ForName: inline model {name} not registered (bsp not loaded?)`)
	end

	local buf = vfslib.loadFile(reg.fs, name)
	if not buf then
		if crash then
			error(`Mod_ForName: {name} not found`)
		end
		return nil
	end

	local ident = buffer.readi32(buf, 0)
	local model: Model
	if ident == mdl.IDENT then
		local alias = mdl.load(name, buf)
		model = {
			name = name,
			kind = "alias",
			alias = alias,
			mins = alias.mins,
			maxs = alias.maxs,
			numframes = alias.numframes,
			flags = alias.flags,
			synctype = alias.synctype,
		}
	elseif ident == spr.IDENT then
		local sprite = spr.load(name, buf)
		model = {
			name = name,
			kind = "sprite",
			sprite = sprite,
			mins = sprite.mins,
			maxs = sprite.maxs,
			numframes = sprite.numframes,
			flags = 0,
			synctype = sprite.synctype,
		}
	else
		local brushModels = bsp.load(name, buf)
		for i, bm in brushModels do
			local m: Model = {
				name = bm.name,
				kind = "brush",
				brush = bm,
				mins = bm.mins,
				maxs = bm.maxs,
				numframes = 2, -- regular and alternate texture animation
				flags = 0,
				synctype = 0,
			}
			reg.byName[bm.name] = m
			if i == 1 then
				model = m
			end
		end
	end

	reg.byName[name] = model
	return model
end

return models
