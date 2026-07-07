--!strict
-- Remote-player render interpolation buffer (qwplerp): bracketing lerp
-- on the delayed timeline, shortest-path angles, teleport snap, stall
-- hold, burst re-spreading, and the adaptive delay tracker.
local t = require("./testutil")
local qwplerp = require("../src/shared/engine/qw/qwplerp")

local function snapAt(h: qwplerp.Hist, msg: number, tm: number, x: number, yaw: number?, vel: number?, frame: number?)
	qwplerp.push(h, msg, tm, vector.create(x, 0, 0), 0, yaw or 0, vector.create(vel or 0, 0, 0), frame or 0)
end

-- basic bracketing lerp (velocity consistent with displacement, as on
-- the real wire: 13 qu over 13ms at ~1000 qu/s)
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0, 0, 900, 5)
	snapAt(h, 2, 1.013, 13, 10, 1100, 6)
	local o, _, yaw, vel, frame = qwplerp.sample(h, 1.0065)
	t.check(o ~= nil and math.abs(o.x - 6.5) < 1e-6, "midpoint origin lerped")
	t.check(math.abs(yaw - 5) < 1e-6, "midpoint yaw lerped")
	t.check(math.abs(vel.x - 1000) < 1e-6, "midpoint velocity lerped")
	t.eq(frame, 5, "animation frame comes from the FROM snapshot")

	-- outside the buffer: hold nearest
	local oNew = qwplerp.sample(h, 2.0)
	t.check(oNew ~= nil and oNew.x == 13, "past newest holds newest (stall)")
	local oOld = qwplerp.sample(h, 0.5)
	t.check(oOld ~= nil and oOld.x == 0, "before oldest holds oldest")
end

-- shortest-path angle wrap
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0, 350)
	snapAt(h, 2, 1.010, 1, 10)
	local _, _, yaw = qwplerp.sample(h, 1.005)
	local dist = math.abs((yaw + 180) % 360 - 180) -- angular distance to 0
	t.check(dist < 1e-6, `yaw 350->10 lerps through 0 (got {yaw})`)
end

-- teleport: no lerp across a >128qu jump
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0)
	snapAt(h, 2, 1.013, 500)
	local o1 = qwplerp.sample(h, 1.003)
	local o2 = qwplerp.sample(h, 1.010)
	t.check(o1 ~= nil and o1.x == 0, "teleport: early sample snaps to FROM")
	t.check(o2 ~= nil and o2.x == 500, "teleport: late sample snaps to TO")
end

-- duplicate messagenums are dropped; a backward WIRE time is kept (the
-- state itself is newer — arrival order is protocol-correct, only the
-- timestamp wobbles) and re-timed onto a monotonic clock
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0, nil, 500)
	snapAt(h, 1, 1.013, 99) -- same msg: ignored
	t.eq(#h.snaps, 1, "dup msg dropped")
	snapAt(h, 2, 0.990, 5, nil, 500) -- newer state, jittered-backward timestamp
	t.eq(#h.snaps, 2, "backward wire time kept")
	t.check(h.snaps[2].t > h.snaps[1].t, "…and re-timed monotonic")
end

-- duplicate position sample (our reply landed between the mover's
-- moves): collapses into the newest snapshot instead of injecting a
-- flat zero-motion segment
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0, nil, 1000)
	snapAt(h, 2, 1.013, 13, nil, 1000)
	snapAt(h, 3, 1.020, 13, 4, 1000, 9) -- same origin, fresher yaw/frame
	t.eq(#h.snaps, 2, "duplicate position collapsed")
	t.eq(h.snaps[2].frame, 9, "collapsed snapshot refreshed in place")
end

-- stale gap (PVS exit/re-entry) restarts the buffer
do
	local h = qwplerp.new()
	snapAt(h, 1, 1.000, 0)
	snapAt(h, 2, 2.000, 400) -- 1s hole: no lerp across the void
	t.eq(#h.snaps, 1, "stale gap cleared the old snapshot")
	local o = qwplerp.sample(h, 1.5)
	t.check(o ~= nil and o.x == 400, "post-gap sample uses only the fresh state")
end

-- ring cap
do
	local h = qwplerp.new()
	for i = 1, 40 do
		snapAt(h, i, 1 + i * 0.013, i)
	end
	t.check(#h.snaps <= 16, `history capped ({#h.snaps})`)
end

-- burst re-spreading: three states delivered at once still sample
-- smoothly because time comes from the wire, not from arrival
do
	local h = qwplerp.new()
	for i = 0, 3 do
		snapAt(h, i + 1, 1 + i * 0.013, i * 13) -- 1000 qu/s
	end
	local prev: number? = nil
	local uniform = true
	for s = 0, 12 do
		local o = qwplerp.sample(h, 1.0 + s * 0.003)
		t.check(o ~= nil, "burst sample in range")
		if o and prev then
			if math.abs((o.x - prev) - 3.0) > 1e-6 then
				uniform = false
			end
		end
		prev = o and o.x or nil
	end
	t.check(uniform, "burst replays as uniform per-frame steps")
end

-- adaptive delay: tracks the worst arrival drought, decays after
do
	local h = qwplerp.new()
	local pt = 1.0
	local msg = 0
	local function tickIn(withSnap: boolean): (number, number)
		if withSnap then
			msg += 1
			snapAt(h, msg, pt - 0.02, 0)
		end
		local rt, d = qwplerp.step(h, pt, pt + 0.02)
		pt += 0.013
		return rt, d
	end
	-- steady 13ms arrivals, playertime trailing 20ms behind the newest
	for _ = 1, 60 do
		tickIn(true)
	end
	local _, steady = tickIn(true)
	t.check(steady < 0.06, `steady delivery keeps the delay small ({math.floor(steady * 1000)}ms)`)
	-- a 150ms drought: playertime advances, no snapshots
	for _ = 1, 12 do
		tickIn(false)
	end
	local _, afterDrought = tickIn(false)
	t.check(afterDrought > 0.1, `drought raises the delay ({math.floor(afterDrought * 1000)}ms)`)
	-- resume steady delivery: the delay relaxes back over seconds
	for _ = 1, 600 do
		tickIn(true)
	end
	local _, relaxed = tickIn(true)
	t.check(relaxed < 0.07, `delay decays after the drought passes ({math.floor(relaxed * 1000)}ms)`)
end

-- render clock: advances smoothly through arrival jitter, never past
-- the newest snapshot, and freezes (not warps) through a drought
do
	local h = qwplerp.new()
	local pt = 1.0
	local msg = 0
	local rts = {}
	-- jittery arrivals: alternating 6ms/20ms gaps around a 13ms mean
	local gap = { 0.006, 0.020 }
	local nextSnap = pt
	for i = 1, 120 do
		if pt >= nextSnap then
			msg += 1
			snapAt(h, msg, pt - 0.02, 0)
			nextSnap += gap[(i % 2) + 1]
		end
		local rt = qwplerp.step(h, pt, pt + 0.02)
		table.insert(rts, rt)
		pt += 0.013
	end
	local worstStep, newestViolations = 0, 0
	for i = 42, #rts do -- past cadence/delay convergence
		local s = rts[i] - rts[i - 1]
		worstStep = math.max(worstStep, math.abs(s - 0.013))
		if rts[i] > h.snaps[#h.snaps].t then
			newestViolations += 1
		end
	end
	t.check(worstStep < 0.006, `render clock steps stay near the frame step (worst dev {math.floor(worstStep * 10000) / 10}ms)`)
	t.eq(newestViolations, 0, "render clock never samples past the newest snapshot")
end

-- wire-timeline noise: the state_time base mixes OUR cmd send times
-- with the server's msec byte, so upstream jitter and sv.time frame
-- quantization wobble the timestamps of a player whose TRUE motion is
-- uniform. Re-timing must flatten it: sampled motion stays uniform.
-- drives push + step + sample like the real client loop: uniform true
-- motion (13 qu per 13ms snapshot), wire timestamps corrupted by the
-- given noise pattern, optional messagenum gap (dropped packet).
-- Returns the worst per-frame speed deviation seen after warmup.
local function runJitterSim(noise: { number }, dropAt: number?): number
	local h = qwplerp.new()
	local prev: number? = nil
	local worst = 0
	local msg = 0
	for i = 1, 240 do
		local trueT = 1 + i * 0.013
		msg += 1
		if i == dropAt then
			msg += 1 -- dropped packet: messagenum gap, position skips a step
		end
		snapAt(h, msg, trueT + noise[(i % #noise) + 1], msg * 13, nil, 1000)
		local rt = qwplerp.step(h, trueT, trueT)
		local skipGap = dropAt and math.abs(i - dropAt) < 8
		if i > 80 and not skipGap then
			local o = qwplerp.sample(h, rt)
			if o and prev then
				worst = math.max(worst, math.abs((o.x - prev) - 13))
			end
			prev = o and o.x or nil
		else
			prev = nil
		end
	end
	return worst
end

-- wire noise at typical levels: raw spacing 8..22ms (up to ±70% speed
-- error per segment); the messagenum clock must render near-uniform
do
	local worst = runJitterSim({ 0.005, -0.004, 0.001, -0.005, 0.004, -0.001 })
	t.check(worst < 2, `re-timing flattens wire-time noise (worst dev {math.floor(worst * 100) / 100} qu/frame)`)
end

-- HEAVY viewer-side jitter (the bad-connection machine): timestamp
-- noise bigger than the packet interval — wire times even run
-- backward — plus a dropped packet mid-run
do
	local worst = runJitterSim({ 0.014, -0.011, 0.002, -0.013, 0.009, -0.002 }, 160)
	t.check(worst < 3, `heavy jitter (±14ms, reversals, a drop) still renders uniform (worst dev {math.floor(worst * 100) / 100} qu/frame)`)
end

-- the full production condition: a 60Hz mover sampled by 77Hz viewer
-- replies (the two cmd clocks beat — some replies duplicate the
-- mover's position, others span two of their moves) PLUS heavy
-- timestamp noise. Displacement timing must render uniform motion.
do
	local h = qwplerp.new()
	local noise = { 0.012, -0.009, 0.003, -0.011, 0.008, -0.003 }
	local prev: number? = nil
	local worst = 0
	for k = 1, 240 do
		local rT = 1 + k * 0.013 -- viewer reply cadence: 77Hz
		local moves = (rT - 1) // 0.0167 -- mover move cadence: 60Hz
		local x = moves * 16.7 -- 1000 qu/s in 16.7ms steps
		local stateT = 1 + moves * 0.0167 + noise[(k % 6) + 1]
		snapAt(h, k, stateT, x, nil, 1000)
		local rt = qwplerp.step(h, rT, rT)
		if k > 80 then
			local o = qwplerp.sample(h, rt)
			if o and prev then
				worst = math.max(worst, math.abs((o.x - prev) - 13))
			end
			prev = o and o.x or nil
		end
	end
	t.check(worst < 3, `60/77Hz beat + jitter renders uniform (worst dev {math.floor(worst * 100) / 100} qu/frame)`)
end

t.finish("test_qwplerp")
