--!strict
-- Remote-player render interpolation. QW's CL_LinkPlayers extrapolates
-- other players by replaying their last usercmd for half the elapsed
-- move and snapping forward on every fresh state — at Roblox display
-- rates (big avatar rigs at 60Hz) that snap-and-correct pattern reads
-- as warping, worst on strafe reversals where the stale cmd
-- extrapolates the wrong way before the correction lands. Modern QW
-- clients (ezQuake/FTE) render remote players on a slightly delayed
-- timeline instead, interpolating between the two wire states that
-- bracket it; this module is that buffer. Snapshots are keyed by the
-- wire state_time (the move's time on the client clock), so a burst
-- of packets delivered in one network step still replays spread out.

local qwplerp = {}

export type Snap = {
	t: number,
	origin: vector,
	pitch: number, -- viewangles.x, degrees
	yaw: number, -- viewangles.y, degrees
	velocity: vector,
	frame: number,
}

export type Hist = {
	snaps: { Snap }, -- oldest..newest, t strictly increasing (re-timed)
	maxLag: number, -- decaying max of (playertime - newest.t): delay floor
	lastMsg: number, -- messagenum of the newest pushed state
	lastPt: number?, -- realtime of the last step() call (frame clock)
	renderT: number?, -- smoothed render-timeline clock
	lastWireT: number?, -- raw wire time of the newest snapshot
	timeErr: number, -- wire time minus assigned time (noise gauge)
	errEma: number?, -- smoothed timeErr (drift corrector input)
	-- live-diagnostic counters (cumulative; the log window diffs them)
	pushes: number, -- snapshots accepted
	dups: number, -- duplicate-position samples collapsed in place
	holds: number, -- frames the render clock clamped at the newest snap
	resyncs: number, -- hard timeline resyncs (hitches)
}

local MAX_SNAPS = 16
local TELEPORT = 128 -- qu on any axis: QW's don't-lerp threshold
local STALE = 0.5 -- s without updates (PVS exit): restart the buffer
local MIN_DELAY = 0.02
local MAX_DELAY = 0.25
local MARGIN = 0.015
local DECAY = 0.02 -- maxLag relaxes ~20ms per second of smooth delivery
local TRACK = 0.05 -- render clock eases 5%/frame toward the target
local RESYNC = 0.25 -- s of clock error that forces a hard snap

qwplerp.MIN_DELAY = MIN_DELAY
qwplerp.MAX_DELAY = MAX_DELAY

local function lerpAngle(a: number, b: number, f: number): number
	local d = (b - a + 180) % 360 - 180
	return a + d * f
end

function qwplerp.new(): Hist
	return { snaps = {}, maxLag = 0, lastMsg = -1, timeErr = 0, pushes = 0, dups = 0, holds = 0, resyncs = 0 }
end

-- Wire state_time is NOISY on this transport: it is rebuilt from OUR
-- acked cmd's send time minus the server's msec byte, so the VIEWER's
-- own upstream delivery jitter and the server's frame-quantized
-- sv.time inject up to a frame of noise into every remote player's
-- timeline — positions advance smoothly but their timestamps compress
-- and stretch, and an interpolator faithfully renders that as
-- speed-ups and jumps (worst to the eye during strafes, where motion
-- is lateral; and worst on the client with the worst connection, since
-- each viewer reconstructs its own copy of the timeline). A uniform
-- per-packet clock is no better: replies sample the mover at OUR cmd
-- cadence, and two unsynchronized cmd clocks beat — some replies carry
-- a duplicate of the mover's position, others span two of their moves.
-- So each segment is timed by its own DISPLACEMENT measured against
-- the server-exact wire velocity (dt = dP.V/|V|^2): both come straight
-- from the server, so timestamp noise can't enter, duplicate samples
-- collapse to zero time, double-steps and drop gaps get their real
-- span, and either client's frame pacing is irrelevant. Wire time
-- only bounds long-term drift through a deadband; near-stationary
-- players (where displacement carries no signal, and where timing
-- errors are invisible anyway) fall back to the wire clock.
local ERR_DEADBAND = 0.05
local MOVE_MIN = 50 -- qu/s: below this, displacement timing is noise
local function retime(h: Hist, wireT: number, origin: vector, velocity: vector, prev: Snap): number
	local dtWire = math.clamp(wireT - (h.lastWireT or wireT), 0, 0.25)
	local vavg = (velocity + prev.velocity) * 0.5
	local speed2 = vector.dot(vavg, vavg)
	local dt = dtWire
	if speed2 > MOVE_MIN * MOVE_MIN then
		local dp = origin - prev.origin
		local dtMove = math.clamp(vector.dot(dp, vavg) / speed2, 0, 0.25)
		local w = math.clamp((math.sqrt(speed2) - MOVE_MIN) / (2 * MOVE_MIN), 0, 1)
		dt = dtMove * w + dtWire * (1 - w)
	end
	local assigned = prev.t + dt
	-- drift corrector: steer from the SMOOTHED error only — the raw
	-- per-snapshot error is exactly the timestamp noise being filtered
	-- out, and correcting on it would leak the noise back in
	local errEma = (h.errEma or 0) * 0.9 + (wireT - assigned) * 0.1
	h.errEma = errEma
	if math.abs(errEma) > ERR_DEADBAND and dt > 0.002 then
		-- persistent drift would otherwise run the delay away over
		-- minutes: pull gently toward wire time
		local over = (math.abs(errEma) - ERR_DEADBAND) * (if errEma > 0 then 1 else -1)
		assigned += math.clamp(over * 0.25, -0.5 * dt, dt)
	end
	if math.abs(wireT - assigned) > 0.1 then
		-- way off (viewer hitch, long stall): hard resync — the moment
		-- itself already reads as a hitch, a timeline jump hides in it
		assigned = math.max(wireT, prev.t + 0.001)
		h.errEma = 0
		h.resyncs += 1
	end
	h.timeErr = wireT - assigned
	return assigned
end

function qwplerp.push(h: Hist, msg: number, t: number, origin: vector, pitch: number, yaw: number, velocity: vector, frame: number)
	if msg == h.lastMsg then
		return -- same wire state re-observed
	end
	h.lastMsg = msg
	local snaps = h.snaps
	local newest = snaps[#snaps]
	if newest and t - (h.lastWireT or t) > STALE then
		table.clear(snaps) -- PVS re-entry: don't lerp across the void
		newest = nil
		h.timeErr = 0
		h.errEma = 0
	end
	-- backward wire times are NOT dropped: arrival order (messagenum) is
	-- protocol-correct, only the timestamp wobbles — retime() floors the
	-- gap at zero and assigns a monotonic time, keeping the sample
	if newest then
		local wireT = t
		t = retime(h, wireT, origin, velocity, newest)
		h.lastWireT = wireT
		if t - newest.t < 0.0005 then
			-- duplicate sample of the same mover state (our reply landed
			-- between their moves): refresh the newest snapshot in place
			newest.origin, newest.pitch, newest.yaw = origin, pitch, yaw
			newest.velocity, newest.frame = velocity, frame
			h.dups += 1
			return
		end
	else
		h.lastWireT = t
	end
	h.pushes += 1
	table.insert(snaps, { t = t, origin = origin, pitch = pitch, yaw = yaw, velocity = velocity, frame = frame })
	if #snaps > MAX_SNAPS then
		table.remove(snaps, 1)
	end
end

-- once per render frame: advance the render-timeline clock. The naive
-- sample point (playertime - delay) inherits the latency estimator's
-- sawtooth (cls.latency drifts up 1ms per packet and snaps down on
-- each fresh RTT minimum) plus the arrival jitter; instead the clock
-- advances steadily by the WALL-CLOCK frame step (realtime), eases
-- toward the playertime-derived target, and clamps at the newest
-- snapshot — a late packet freezes the player for a frame rather than
-- warping ahead and snapping back. Returns (renderTime, delay); delay
-- adapts to the worst recent inter-arrival gap.
function qwplerp.step(h: Hist, playertime: number, realtime: number): (number, number)
	local dt = math.clamp(realtime - (h.lastPt or realtime), 0, 0.1)
	h.lastPt = realtime
	local newest = h.snaps[#h.snaps]
	if newest then
		local lag = playertime - newest.t
		if lag > h.maxLag then
			h.maxLag = math.min(lag, MAX_DELAY)
		else
			h.maxLag = math.max(h.maxLag - dt * DECAY, 0)
		end
	end
	local delay = math.clamp(h.maxLag + MARGIN, MIN_DELAY, MAX_DELAY)
	local target = playertime - delay
	local rt = h.renderT
	if rt == nil or math.abs(target - rt) > RESYNC then
		rt = target -- first sample / hard resync
	else
		rt += dt + (target - rt) * TRACK
	end
	if newest and rt > newest.t then
		rt = newest.t
		h.holds += 1
	end
	h.renderT = rt
	return rt, delay
end

-- sample the buffer at time t: interpolated origin/angles/velocity and
-- the from-snapshot's animation frame. Outside the buffer (stall, or
-- not enough data yet) the nearest snapshot is held. nil = no data.
function qwplerp.sample(h: Hist, t: number): (vector?, number, number, vector, number)
	local snaps = h.snaps
	local n = #snaps
	if n == 0 then
		return nil, 0, 0, vector.zero, 0
	end
	if t >= snaps[n].t or n == 1 then
		local s = snaps[n]
		return s.origin, s.pitch, s.yaw, s.velocity, s.frame
	end
	if t <= snaps[1].t then
		local s = snaps[1]
		return s.origin, s.pitch, s.yaw, s.velocity, s.frame
	end
	for i = n - 1, 1, -1 do
		local a, b = snaps[i], snaps[i + 1]
		if t >= a.t then
			local f = (t - a.t) / (b.t - a.t)
			local d = b.origin - a.origin
			if math.abs(d.x) > TELEPORT or math.abs(d.y) > TELEPORT or math.abs(d.z) > TELEPORT then
				local s = if f < 0.5 then a else b -- teleported: don't lerp
				return s.origin, s.pitch, s.yaw, s.velocity, s.frame
			end
			return a.origin + d * f,
				lerpAngle(a.pitch, b.pitch, f),
				lerpAngle(a.yaw, b.yaw, f),
				a.velocity + (b.velocity - a.velocity) * f,
				a.frame
		end
	end
	local s = snaps[1]
	return s.origin, s.pitch, s.yaw, s.velocity, s.frame
end

return qwplerp
