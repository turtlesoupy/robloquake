--!strict
-- Virtual filesystem — port of the COM_LoadFile / com_searchpaths machinery
-- from WinQuake common.c.
--
-- Quake searches game directories in reverse add order ("id1", then the mod
-- dir), and inside each, pak files pak0..pakN also in reverse order, so later
-- additions override earlier ones. We reproduce that: searchpaths is a stack.

local pak = require("./pak")
local base64 = require("./base64")

local vfs = {}

export type SearchPath = {
	pack: pak.Pack?,
	-- Roblox Folder of per-file chunk folders (the server-published client
	-- bundle); each child Folder is named with the quake path and holds
	-- base64 StringValue chunks plus "chunks"/"len" attributes
	folder: any?,
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

function vfs.addFolderSource(fs: Vfs, folder: any)
	table.insert(fs.searchpaths, 1, { folder = folder })
end

-- com_gamedirfile: the directory name of the newest (last-added) game
-- directory on the searchpath — pack filenames carry it as their prefix
-- ("fortress/pak0.pak" -> "fortress"). QW stamps this into serverinfo
-- "*gamedir" so mods can verify what they're running under (e.g. Team
-- Fortress refuses to boot unless it reads "fortress").
function vfs.gamedir(fs: Vfs): string?
	for _, sp in fs.searchpaths do
		if sp.pack then
			return string.match(sp.pack.filename, "^([^/]+)/")
		end
	end
	return nil
end

-- COM_FindFile. Returns the containing pack and entry, or nil.
function vfs.findFile(fs: Vfs, filename: string): (pak.Pack?, pak.PackEntry?)
	for _, sp in fs.searchpaths do
		if sp.pack then
			local entry = pak.find(sp.pack, filename)
			if entry then
				return sp.pack, entry
			end
		end
	end
	return nil, nil
end

-- read a file published as a Folder of base64 StringValue chunks; when
-- `wait` is set, allow time for replication to deliver it (map changes)
local function folderRead(folder: any, filename: string, wait: boolean?): buffer?
	local f = folder:FindFirstChild(filename)
	if not f and wait then
		f = folder:WaitForChild(filename, 20)
	end
	if not f then
		return nil
	end
	-- the chunk children may still be replicating
	local deadline = os.clock() + 20
	while true do
		local n = f:GetAttribute("chunks")
		if typeof(n) == "number" and #f:GetChildren() >= n then
			break
		end
		if os.clock() > deadline then
			return nil
		end
		task.wait()
	end
	local chunks = f:GetChildren()
	table.sort(chunks, function(a, b)
		return a.Name < b.Name
	end)
	local parts = table.create(#chunks)
	for _, chunk in chunks do
		table.insert(parts, chunk.Value)
	end
	return base64.decode(table.concat(parts))
end

-- COM_LoadFile: returns file contents as a fresh buffer, or nil if missing.
-- `wait` (folder sources only) blocks until replication delivers the file.
function vfs.loadFile(fs: Vfs, filename: string, wait: boolean?): buffer?
	for _, sp in fs.searchpaths do
		if sp.pack then
			local entry = pak.find(sp.pack, filename)
			if entry then
				return pak.readFile(sp.pack, entry)
			end
		elseif sp.folder then
			local buf = folderRead(sp.folder, filename, wait)
			if buf then
				return buf
			end
		end
	end
	return nil
end

function vfs.fileLength(fs: Vfs, filename: string): number
	local _, entry = vfs.findFile(fs, filename)
	if entry then
		return entry.filelen
	end
	for _, sp in fs.searchpaths do
		if sp.folder then
			local f = sp.folder:FindFirstChild(filename)
			local len = if f then f:GetAttribute("len") else nil
			if typeof(len) == "number" then
				return len
			end
		end
	end
	return -1
end

return vfs
