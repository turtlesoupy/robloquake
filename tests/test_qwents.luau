--!strict
-- QW delta codec round-trips: usercmds and packet entities through the
-- exact wire format, full and delta paths
local t = require("./testutil")
local msg = require("../src/shared/engine/common/msg")
local qwents = require("../src/shared/engine/qw/qwents")
local qwp = require("../src/shared/engine/qw/qwprotocol")

-- usercmd round trip
local from = qwents.nullCmd()
local cmd: qwents.UserCmdWire = {
	angles = vector.create(10.5, 271.4, 0),
	forwardmove = 400,
	sidemove = -350,
	upmove = 0,
	buttons = 3,
	impulse = 7,
	msec = 50,
}
local sb = msg.newBuf(64)
qwents.writeDeltaUsercmd(sb, from, cmd)
local r = msg.reader(msg.snapshot(sb))
local got = qwents.readDeltaUsercmd(r, from)
-- angle16 rides a signed short: round-trips are congruent mod 360, as in C
local function angdiff(a: number, b: number): number
	return math.abs((a - b + 180) % 360 - 180)
end
t.check(angdiff(got.angles.x, cmd.angles.x) < 0.01, "cmd angle1 round-trips (angle16)")
t.check(angdiff(got.angles.y, cmd.angles.y) < 0.01, "cmd angle2 round-trips (mod 360)")
t.eq(got.forwardmove, 400, "forwardmove")
t.eq(got.sidemove, -350, "sidemove")
t.eq(got.buttons, 3, "buttons")
t.eq(got.impulse, 7, "impulse")
t.eq(got.msec, 50, "msec")

-- entity states
local function state(num: number, x: number, frame: number): qwents.EntityState
	local s = qwents.nullState(num)
	s.origin = vector.create(x, 64, 24)
	s.modelindex = 5
	s.frame = frame
	return s
end
local baselines: { [number]: qwents.EntityState } = {}
local function baselineFor(n: number): qwents.EntityState
	return baselines[n] or qwents.nullState(n)
end

-- full update (no delta)
local frame1: qwents.PacketEntities = { state(40, 100, 0), state(55, 200, 2), state(60, 300, 1) }
sb = msg.newBuf(1024)
qwents.emitPacketEntities(sb, frame1, nil, nil, baselineFor)
r = msg.reader(msg.snapshot(sb))
t.eq(msg.readByte(r), qwp.svc_packetentities, "full update svc")
local parsed1 = qwents.parsePacketEntities(r, {}, baselineFor)
t.eq(#parsed1, 3, "3 entities parsed")
t.eq(parsed1[2].number, 55, "entity numbers preserved")
t.check(vector.magnitude(parsed1[2].origin - vector.create(200, 64, 24)) < 0.01, "origins preserved")
t.eq(parsed1[3].frame, 1, "frames preserved")

-- delta update: 40 moves, 55 unchanged, 60 removed, 70 new
local frame2: qwents.PacketEntities = { state(40, 132, 0), state(55, 200, 2), state(70, 400, 6) }
sb = msg.newBuf(1024)
qwents.emitPacketEntities(sb, frame2, parsed1, 7, baselineFor)
r = msg.reader(msg.snapshot(sb))
t.eq(msg.readByte(r), qwp.svc_deltapacketentities, "delta svc")
t.eq(msg.readByte(r), 7, "delta from-sequence")
local parsed2 = qwents.parsePacketEntities(r, parsed1, baselineFor)
t.eq(#parsed2, 3, "delta result count")
t.eq(parsed2[1].number, 40, "moved entity present")
t.check(math.abs(parsed2[1].origin.x - 132) < 0.01, "moved origin applied")
t.eq(parsed2[2].number, 55, "unchanged entity carried")
t.eq(parsed2[3].number, 70, "new entity from baseline")
t.eq(parsed2[3].frame, 6, "new entity fields")
local removed = false
for _, e in parsed2 do
	if e.number == 60 then
		removed = true
	end
end
t.check(not removed, "removed entity gone")

t.finish("test_qwents")
