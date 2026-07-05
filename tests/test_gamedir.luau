--!strict
-- Gamedir (mod) support: a mod directory's pak stacks over the base game in
-- the vfs searchpath, its files override same-named base files, missing
-- files fall through to the base game, and both server boots load a mod's
-- progs through the stack without any special-casing.
--
-- The "mod progs" here is LibreQuake's progs.dat — a genuinely foreign
-- QuakeC build (different CRC/field count from id's) — layered over the id1
-- base pak, exactly how a third-party mod ships.

local fs = require("@lune/fs")

local pak = require("../src/shared/engine/common/pak")
local vfs = require("../src/shared/engine/common/vfs")
local progslib = require("../src/shared/engine/progs/progs")
local host = require("../src/shared/engine/server/host")
local qwsv = require("../src/shared/engine/qw/qwsv")
local testutil = require("./testutil")

local check = testutil.check
local eq = testutil.eq

local writePak = testutil.writePak

-- 1. searchpath semantics: override + fallthrough ------------------------

local fsys = testutil.gameFs() -- id1/pak0
local basePalette = vfs.loadFile(fsys, "gfx/palette.lmp")
assert(basePalette, "base palette present")

local marker = buffer.fromstring("MOD OVERRIDE MARKER")
local modPak = pak.load(
	"mymod/pak0.pak",
	writePak({
		{ name = "gfx/palette.lmp", data = marker },
		{ name = "mod/only.txt", data = buffer.fromstring("mod-only file") },
	})
)
vfs.addPack(fsys, modPak) -- COM_AddGameDirectory: mod stacks over base

local got = vfs.loadFile(fsys, "gfx/palette.lmp")
check(got ~= nil and buffer.tostring(got :: buffer) == "MOD OVERRIDE MARKER", "mod file overrides base file")
eq(vfs.fileLength(fsys, "gfx/palette.lmp"), buffer.len(marker), "fileLength sees the mod version")
local modOnly = vfs.loadFile(fsys, "mod/only.txt")
check(modOnly ~= nil and buffer.tostring(modOnly :: buffer) == "mod-only file", "mod-only file found")
local baseOnly = vfs.loadFile(fsys, "progs.dat")
check(baseOnly ~= nil, "base-only file falls through to id1")

-- 2. NQ boot with a foreign mod progs.dat via gamedir stacking ------------

local LQ_PAK = "external_assets/librequake/full/id1/pak0.pak"
if fs.isFile(LQ_PAK) then
	local idFs = testutil.gameFs()
	local idProgs = progslib.load(vfs.loadFile(idFs, "progs.dat") :: buffer)

	-- the "mod" ships just its own progs.dat, like a total-conversion server mod
	local lqPak = pak.load("lq/pak0.pak", buffer.fromstring(fs.readFile(LQ_PAK)))
	local lqProgsBuf = pak.readFile(lqPak, pak.find(lqPak, "progs.dat") :: pak.PackEntry)
	vfs.addPack(idFs, pak.load("moddir/pak0.pak", writePak({ { name = "progs.dat", data = lqProgsBuf } })))

	local svr = host.newGame(idFs, 4)
	svr.print = function(_s: string) end
	host.spawnServer(svr, "e1m1")
	check(svr.active == true, "NQ server boots id1 e1m1 with the mod progs")
	eq(svr.progs.crc, progslib.load(lqProgsBuf).crc, "loaded progs is the mod's (crc match)")
	check(svr.progs.crc ~= idProgs.crc, "mod progs crc differs from base progs (really foreign)")
else
	print("test_gamedir: NQ foreign-progs leg SKIPPED (no LibreQuake assets)")
end

-- 3. QW boot: qwprogs.dat resolved through the searchpath (COM_LoadFile) --

local QWPROGS = "reference/quake-c/qw-qc/qwprogs.dat"
if fs.isFile(QWPROGS) then
	local qwFs = testutil.gameFs()
	local qwProgsBuf = buffer.fromstring(fs.readFile(QWPROGS))
	vfs.addPack(qwFs, pak.load("moddir/pak0.pak", writePak({ { name = "qwprogs.dat", data = qwProgsBuf } })))

	local svr = qwsv.newGame(qwFs) -- no injected buffer: must come from the vfs
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")
	check(svr.active == true, "QW server boots with qwprogs.dat from the searchpath")
else
	print("test_gamedir: QW vfs-progs leg SKIPPED (no reference qwprogs.dat)")
end

-- 4. missing progs errors clearly, doesn't crash obscurely ----------------

local emptyFs = vfs.new()
local ok, err = pcall(function()
	qwsv.newGame(emptyFs)
end)
check(not ok, "qwsv.newGame without qwprogs.dat fails")
check(
	typeof(err) == "string" and (err :: string):find("qwprogs.dat") ~= nil,
	"error names the missing file (got: " .. tostring(err) .. ")"
)

testutil.finish("test_gamedir")
