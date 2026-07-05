--!strict
-- Shared helpers for lune-based tests. Loads real Quake data from
-- external_assets (never committed) so parsers are tested against ground truth.

local fs = require("@lune/fs")
local process = require("@lune/process")

local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")

local testutil = {}

local PAK0 = "external_assets/quake106/extracted/id1/pak0.pak"

function testutil.loadPak0(): pak.Pack
	if not fs.isFile(PAK0) then
		error("missing " .. PAK0 .. " — run from repo root with shareware assets extracted")
	end
	local data = buffer.fromstring(fs.readFile(PAK0))
	return pak.load("id1/pak0.pak", data)
end

function testutil.gameFs(): vfs.Vfs
	local fsys = vfs.new()
	vfs.addPack(fsys, testutil.loadPak0())
	return fsys
end

-- build a pak blob the way tools/build_assets.py packs loose mod files
-- (PACK header, file data, 64-byte directory entries) — for staging mod
-- gamedirs in tests
function testutil.writePak(files: { { name: string, data: buffer } }): buffer
	local headerLen = 12
	local dirlen = #files * 64
	local datalen = 0
	for _, f in files do
		datalen += buffer.len(f.data)
	end
	local blob = buffer.create(headerLen + datalen + dirlen)
	buffer.writestring(blob, 0, "PACK")
	buffer.writei32(blob, 4, headerLen + datalen) -- dirofs
	buffer.writei32(blob, 8, dirlen)
	local pos = headerLen
	local dpos = headerLen + datalen
	for _, f in files do
		buffer.copy(blob, pos, f.data, 0, buffer.len(f.data))
		buffer.writestring(blob, dpos, f.name) -- rest of the 56 bytes stays 0
		buffer.writei32(blob, dpos + 56, pos)
		buffer.writei32(blob, dpos + 60, buffer.len(f.data))
		pos += buffer.len(f.data)
		dpos += 64
	end
	return blob
end

local failures = 0
local checks = 0

function testutil.check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		failures += 1
		print("  FAIL: " .. msg)
	end
end

function testutil.eq(got: any, want: any, msg: string)
	testutil.check(got == want, msg .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
end

function testutil.finish(name: string)
	if failures > 0 then
		print(string.format("%s: %d/%d checks FAILED", name, failures, checks))
		process.exit(1)
	else
		print(string.format("%s: all %d checks passed", name, checks))
	end
end

return testutil
