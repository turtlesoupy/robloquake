--!strict
-- Regression checks for the 2026-07-06 release-audit findings
-- (docs/coverage/audit-2026-07-06.md). Each block is labelled with its
-- manifest row id.

local t = require("./testutil")
local fs = require("@lune/fs")
local vfs = require("../src/shared/engine/common/vfs")
local progslib = require("../src/shared/engine/progs/progs")
local vmlib = require("../src/shared/engine/progs/vm")
local qwcl = require("../src/shared/engine/qw/qwcl")
local qwsv = require("../src/shared/engine/qw/qwsv")
local msg = require("../src/shared/engine/common/msg")
local sv_user = require("../src/shared/engine/server/sv_user")

local gamefs = t.gameFs()

-- A1: cl_pushlatency prediction horizon -----------------------------------
do
	local cl = qwcl.new(gamefs)
	cl.realtime = 10
	cl.latency = 0.2
	-- default pushlatency -999: cl.time = realtime - latency + 0.999,
	-- clamped to realtime — prediction runs through all outstanding cmds
	qwcl.predictMove(cl)
	t.eq(cl.time, 10, "A1 default pushlatency predicts to realtime")
	-- pushlatency 0 reproduces the old (laggy) horizon
	cl.pushlatency = 0
	qwcl.predictMove(cl)
	t.check(math.abs(cl.time - 9.8) < 1e-9, "A1 pushlatency 0 stops one RTT early")
	-- C clamps positive values to 0 at the top of CL_PredictMove
	cl.pushlatency = 500
	qwcl.predictMove(cl)
	t.eq(cl.pushlatency, 0, "A1 positive pushlatency clamped to 0")
	t.check(math.abs(cl.time - 9.8) < 1e-9, "A1 clamped horizon equals pushlatency 0")
end

-- A2: MakeChar truncation toward zero -------------------------------------
do
	local cl = qwcl.new(gamefs)
	cl.state = "active"
	cl.movemessages = 5
	cl.send = function(_p: buffer) end
	local function sent(fwd: number): number
		local seq = cl.netchan.outgoing_sequence
		qwcl.sendCmd(cl, {
			msec = 16,
			angles = vector.zero,
			forwardmove = fwd,
			sidemove = 0,
			upmove = 0,
			buttons = 0,
			impulse = 0,
		})
		return cl.frames[bit32.band(seq, 15)].cmd.forwardmove
	end
	-- C: (int)(-12.5) = -12; -12 & ~3 = -12. Floor would give -16.
	t.eq(sent(-12.5), -12, "A2 makeChar truncates -12.5 toward zero")
	-- C: (int)(-200.5) = -200. Floor would give -204.
	t.eq(sent(-200.5), -200, "A2 makeChar truncates -200.5 toward zero")
	t.eq(sent(200.5), 200, "A2 makeChar positive unchanged")
	t.eq(sent(-1000), -508, "A2 makeChar clamps at -127*4")
end

-- A3: SV_SetIdealPitch int step/dir ---------------------------------------
do
	-- fractional risers: C truncates each delta to int, so 0.6-unit
	-- steps read as 0 (no step) — the float port counted them
	local dir, steps = sv_user.idealPitchSteps({ 0, 0.6, 1.2, 1.8, 2.4, 3.0 })
	t.eq(dir, 0, "A3 sub-unit deltas truncate to no direction")
	t.eq(steps, 0, "A3 sub-unit deltas count zero steps")
	-- 16.7-unit risers: C dir = 16 (not 16.7)
	dir, steps = sv_user.idealPitchSteps({ 0, 16.7, 33.4, 50.1, 66.8, 83.5 })
	t.eq(dir, 16, "A3 fractional riser dir truncates toward zero")
	t.eq(steps, 5, "A3 riser count intact")
	-- descending fractional: trunc(-16.7) = -16 (floor would say -17)
	dir, steps = sv_user.idealPitchSteps({ 83.5, 66.8, 50.1, 33.4, 16.7, 0 })
	t.eq(dir, -16, "A3 negative dir truncates toward zero")
	-- mixed changes still bail out
	local _, s2 = sv_user.idealPitchSteps({ 0, 16, 0, 16, 0, 16 })
	t.eq(s2, -1, "A3 mixed changes bail out")
end

-- B1: VM stack state restored after a QC runtime error ---------------------
do
	local buf = vfs.loadFile(gamefs, "progs.dat")
	assert(buf)
	local pr = progslib.load(buf)
	local vm = vmlib.new(pr, 600, 0)
	-- no builtins registered: the first builtin call inside main()
	-- raises PR_RunError ("bad builtin call number") mid-execution
	local fnum = pr.functionsByName["main"]
	assert(fnum, "progs.dat main")
	local ok = pcall(vmlib.exec, vm, fnum)
	t.eq(ok, false, "B1 QC error propagates")
	t.eq(vm.depth, 0, "B1 depth dumped like PR_RunError")
	t.eq(vm.localstack_used, 0, "B1 locals stack dumped")
	-- the VM keeps working: a pure-assignment function runs clean
	local ok2 = pcall(vmlib.exec, vm, pr.functionsByName["SetNewParms"])
	t.eq(ok2, true, "B1 next exec runs on a clean stack")
	t.eq(vm.depth, 0, "B1 depth balanced after clean exec")
end

-- B2: reliable overflow flags + drops instead of erroring; timeouts --------
do
	local qwprogs = buffer.fromstring(fs.readFile("reference/quake-c/qw-qc/qwprogs.dat"))
	local svr = qwsv.newGame(gamefs, qwprogs)
	svr.print = function(_s: string) end
	qwsv.spawnServer(svr, "e1m1")

	local c1 = qwsv.wireConnect(svr, 1, { name = "spammed" }, function(_p: buffer) end)
	-- 30 x ~300B into the 8192 reliable stream: C's allowoverflow path
	-- must flag + clear, never error
	local okWrite = pcall(function()
		for _ = 1, 30 do
			msg.writeByte(c1.netchan.message, 8) -- svc_print
			msg.writeByte(c1.netchan.message, 2)
			msg.writeString(c1.netchan.message, string.rep("x", 300))
		end
	end)
	t.eq(okWrite, true, "B2 overflowing reliable write does not error")
	t.eq(c1.netchan.message.overflowed, true, "B2 overflow flagged")
	qwsv.frame(svr, 0.05)
	t.eq(c1.active, false, "B2 overflowed client dropped at the frame sweep")

	-- timeout: a client that stops sending packets gets dropped after
	-- timeout (65s) of realtime; a talking client survives
	local c2 = qwsv.wireConnect(svr, 2, { name = "zombie" }, function(_p: buffer) end)
	local c3 = qwsv.wireConnect(svr, 3, { name = "alive" }, function(_p: buffer) end)
	c2.last_message = svr.realtime
	svr.realtime += 100
	c3.last_message = svr.realtime
	qwsv.checkTimeouts(svr)
	t.eq(c2.active, false, "B2 silent client timed out")
	t.eq(c3.active, true, "B2 talking client survives the sweep")
end

t.finish("test_audit")
