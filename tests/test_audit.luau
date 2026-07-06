--!strict
-- Regression checks for the 2026-07-06 release-audit findings
-- (docs/coverage/audit-2026-07-06.md). Each block is labelled with its
-- manifest row id.

local t = require("./testutil")
local qwcl = require("../src/shared/engine/qw/qwcl")
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

t.finish("test_audit")
