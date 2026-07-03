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
