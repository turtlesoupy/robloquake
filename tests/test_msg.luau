--!strict
-- Wire codec (msg.luau = common.c MSG_*/SZ_*) byte-exact battery.
-- Expectations are the C encodings: little-endian shorts/longs, IEEE
-- floats, byte angles value*256/360 truncated, coords value*8 truncated
-- to short, NUL-terminated strings, and -1 with badread on underflow.
local t = require("./testutil")
local msg = require("../src/shared/engine/common/msg")

-- SZ_Alloc / writes
local sb = msg.newBuf(64)
msg.writeChar(sb, -3)
msg.writeByte(sb, 200)
msg.writeShort(sb, -1234)
msg.writeLong(sb, 123456789)
msg.writeFloat(sb, 1.5)
msg.writeString(sb, "abc")
msg.writeCoord(sb, -12.5)
msg.writeAngle(sb, 90)
msg.writeAngle(sb, 360)
msg.writeAngle16(sb, 90)
t.eq(sb.cursize, 1 + 1 + 2 + 4 + 4 + 4 + 2 + 1 + 1 + 2, "SZ cursize sums each write")

-- byte-exact encoding
local raw = msg.snapshot(sb)
t.eq(buffer.readi8(raw, 0), -3, "WriteChar signed byte")
t.eq(buffer.readu8(raw, 1), 200, "WriteByte unsigned")
t.eq(buffer.readi16(raw, 2), -1234, "WriteShort little-endian signed")
t.eq(buffer.readi32(raw, 4), 123456789, "WriteLong little-endian")
t.eq(buffer.readf32(raw, 8), 1.5, "WriteFloat IEEE")
t.eq(buffer.readu8(raw, 15), 0, "WriteString NUL terminator")
t.eq(buffer.readi16(raw, 16), -100, "WriteCoord -12.5 = -100 (value*8)")
t.eq(buffer.readu8(raw, 18), 64, "WriteAngle 90 = 64 (value*256/360 & 255)")
t.eq(buffer.readu8(raw, 19), 0, "WriteAngle 360 wraps to 0")
t.eq(buffer.readu16(raw, 20), 16384, "WriteAngle16 90 = 16384")

-- MSG_BeginReading / reads round-trip
local r = msg.reader(raw)
t.eq(msg.readChar(r), -3, "ReadChar")
t.eq(msg.readByte(r), 200, "ReadByte")
t.eq(msg.readShort(r), -1234, "ReadShort")
t.eq(msg.readLong(r), 123456789, "ReadLong")
t.eq(msg.readFloat(r), 1.5, "ReadFloat")
t.eq(msg.readString(r), "abc", "ReadString stops at NUL")
t.eq(msg.readCoord(r), -12.5, "ReadCoord back to units")
t.eq(msg.readAngle(r), 90, "ReadAngle back to degrees")
t.eq(msg.readAngle(r), 0, "wrapped angle reads 0")
t.eq(msg.readAngle16(r), 90, "ReadAngle16 back to degrees")

-- underflow: C sets msg_badread and returns -1
t.eq(msg.readByte(r), -1, "read past end returns -1")
t.check(r.badread, "badread set on underflow")

-- SZ_Clear keeps capacity, resets size
msg.clear(sb)
t.eq(sb.cursize, 0, "SZ_Clear resets cursize")
msg.writeByte(sb, 7)
t.eq(sb.cursize, 1, "buffer usable after clear")

-- coord/angle quantization truncates like C's (int) casts
local q = msg.newBuf(16)
msg.writeCoord(q, 1.99) -- 15.92 -> (int) 15
msg.writeAngle(q, 1) -- 0.71 -> (int) 0
local qraw = msg.snapshot(q)
t.eq(buffer.readi16(qraw, 0), 15, "WriteCoord truncates toward zero")
t.eq(buffer.readu8(qraw, 2), 0, "WriteAngle truncates toward zero")

-- SZ_GetSpace: overflow errors without allowoverflow; with it, the
-- buffer clears and sets overflowed (C semantics)
local tiny = msg.newBuf(2)
msg.writeByte(tiny, 1)
msg.writeByte(tiny, 2)
t.check(not pcall(function()
	msg.writeByte(tiny, 3)
end), "overflow without allowoverflow errors")
local ov = msg.newBuf(2, true)
msg.writeByte(ov, 1)
msg.writeByte(ov, 2)
msg.writeByte(ov, 3)
t.check(ov.overflowed and ov.cursize == 1, "allowoverflow clears the buffer and flags overflowed")

t.finish("test_msg")
