--!strict
-- Virtual filesystem — port of the COM_LoadFile / com_searchpaths machinery
-- from WinQuake common.c.
--
-- Quake searches game directories in reverse add order ("id1", then the mod
-- dir), and inside each, pak files pak0..pakN also in reverse order, so later
-- additions override earlier ones. We reproduce that: searchpaths is a stack.

local pak = require("./pak")

local vfs = {}

export type SearchPath = {
	pack: pak.Pack,
}

export type Vfs = {
	searchpaths: { SearchPath }, -- newest first
}

function vfs.new(): Vfs
	return { searchpaths = {} }
end

-- COM_AddGameDirectory adds paks in order pak0, pak1, ...; each newly added
-- pak is searched before the ones added earlier.
function vfs.addPack(fs: Vfs, pack: pak.Pack)
	table.insert(fs.searchpaths, 1, { pack = pack })
end

-- COM_FindFile. Returns the containing pack and entry, or nil.
function vfs.findFile(fs: Vfs, filename: string): (pak.Pack?, pak.PackEntry?)
	for _, sp in fs.searchpaths do
		local entry = pak.find(sp.pack, filename)
		if entry then
			return sp.pack, entry
		end
	end
	return nil, nil
end

-- COM_LoadFile: returns file contents as a fresh buffer, or nil if missing.
function vfs.loadFile(fs: Vfs, filename: string): buffer?
	local p, entry = vfs.findFile(fs, filename)
	if p and entry then
		return pak.readFile(p, entry)
	end
	return nil
end

function vfs.fileLength(fs: Vfs, filename: string): number
	local _, entry = vfs.findFile(fs, filename)
	return if entry then entry.filelen else -1
end

return vfs
