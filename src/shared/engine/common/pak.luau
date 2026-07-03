--!strict
--!optimize 2
-- PAK archive support — port of COM_LoadPackFile / pack handling from
-- WinQuake common.c. A pack is a directory of {name, filepos, filelen}
-- over one contiguous blob, which we keep as a single buffer.

local bufio = require("./bufio")

local pak = {}

export type PackEntry = {
	name: string,
	filepos: number,
	filelen: number,
}

export type Pack = {
	filename: string, -- diagnostic name, e.g. "id1/pak0.pak"
	data: buffer,
	entries: { PackEntry }, -- in directory order
	byName: { [string]: PackEntry },
	numfiles: number,
}

local MAX_FILES_IN_PACK = 2048

-- COM_LoadPackFile: parse the header and directory.
-- Names are compared case-sensitively, exactly like Q_strcmp in COM_FindFile.
function pak.load(filename: string, data: buffer): Pack
	local r = bufio.reader(data)
	local id = r:strz(4)
	if id ~= "PACK" then
		error(filename .. " is not a packfile")
	end
	local dirofs = r:i32()
	local dirlen = r:i32()
	local numpackfiles = dirlen / 64
	if numpackfiles > MAX_FILES_IN_PACK then
		error(filename .. " has " .. numpackfiles .. " files")
	end

	local entries: { PackEntry } = table.create(numpackfiles)
	local byName: { [string]: PackEntry } = {}
	r:seek(dirofs)
	for _ = 1, numpackfiles do
		local name = r:strz(56)
		local filepos = r:i32()
		local filelen = r:i32()
		local entry: PackEntry = { name = name, filepos = filepos, filelen = filelen }
		table.insert(entries, entry)
		byName[name] = entry
	end

	return {
		filename = filename,
		data = data,
		entries = entries,
		byName = byName,
		numfiles = numpackfiles,
	}
end

function pak.find(pack: Pack, name: string): PackEntry?
	return pack.byName[name]
end

-- Copy a file out of the pack into a fresh buffer.
function pak.readFile(pack: Pack, entry: PackEntry): buffer
	return bufio.slice(pack.data, entry.filepos, entry.filelen)
end

return pak
