--!strict
--!optimize 2
-- Network message buffers — port of sizebuf_t / MSG_Write* / MSG_Read* from
-- WinQuake common.c. All values little-endian; coords are 13.3 fixed point,
-- angles are 8-bit 360ths.

local msg = {}

export type SizeBuf = {
	data: buffer,
	cursize: number,
	maxsize: number,
	allowoverflow: boolean,
	overflowed: boolean,
}

export type Reader = {
	data: buffer,
	size: number,
	readcount: number,
	badread: boolean,
}

function msg.newBuf(maxsize: number, allowoverflow: boolean?): SizeBuf
	return {
		data = buffer.create(maxsize),
		cursize = 0,
		maxsize = maxsize,
		allowoverflow = allowoverflow or false,
		overflowed = false,
	}
end

function msg.clear(sb: SizeBuf)
	-- C SZ_Clear zeroes only cursize; overflowed must survive so the
	-- send paths can see it (SZ_GetSpace clears the buffer right after
	-- setting the flag — resetting it here made those checks dead code)
	sb.cursize = 0
end

-- SZ_GetSpace
local function getSpace(sb: SizeBuf, length: number): number
	if sb.cursize + length > sb.maxsize then
		if not sb.allowoverflow then
			error("SZ_GetSpace: overflow without allowoverflow set")
		end
		if length > sb.maxsize then
			error(`SZ_GetSpace: {length} is > full buffer size`)
		end
		sb.overflowed = true
		msg.clear(sb)
	end
	local pos = sb.cursize
	sb.cursize += length
	return pos
end

function msg.writeChar(sb: SizeBuf, c: number)
	buffer.writei8(sb.data, getSpace(sb, 1), c)
end

function msg.writeByte(sb: SizeBuf, c: number)
	buffer.writeu8(sb.data, getSpace(sb, 1), bit32.band(c, 0xff))
end

function msg.writeShort(sb: SizeBuf, c: number)
	local pos = getSpace(sb, 2)
	buffer.writeu16(sb.data, pos, bit32.band(c, 0xffff))
end

function msg.writeLong(sb: SizeBuf, c: number)
	local pos = getSpace(sb, 4)
	buffer.writeu32(sb.data, pos, c % 0x100000000)
end

function msg.writeFloat(sb: SizeBuf, f: number)
	buffer.writef32(sb.data, getSpace(sb, 4), f)
end

function msg.writeString(sb: SizeBuf, s: string?)
	local str = s or ""
	local pos = getSpace(sb, #str + 1)
	buffer.writestring(sb.data, pos, str)
	buffer.writeu8(sb.data, pos + #str, 0)
end

-- MSG_WriteCoord: 13.3 fixed point via C truncation
-- QW's MSG_WriteAngle: scale first, then C-truncate ((int)(f*256/360)).
-- NetQuake truncates f first — one angle-step difference for fractional
-- inputs, so the QW wire paths use this variant.
function msg.writeAngleQW(sb: SizeBuf, f: number)
	local v = f * 256 / 360
	v = if v >= 0 then math.floor(v) else -math.floor(-v)
	buffer.writeu8(sb.data, getSpace(sb, 1), bit32.band(v, 255))
end

function msg.writeCoord(sb: SizeBuf, f: number)
	local v = f * 8
	msg.writeShort(sb, if v >= 0 then math.floor(v) else -math.floor(-v))
end

-- MSG_WriteAngle: note the C casts f to int BEFORE scaling, and the whole
-- expression is integer math with truncation toward zero
-- QW MSG_WriteAngle16: (int)(f*65536/360) truncates toward zero
function msg.writeAngle16(sb: SizeBuf, f: number)
	local v = f * 65536 / 360
	v = if v >= 0 then math.floor(v) else -math.floor(-v)
	msg.writeShort(sb, bit32.band(v, 65535))
end

function msg.writeAngle(sb: SizeBuf, f: number)
	local i = if f >= 0 then math.floor(f) else -math.floor(-f)
	local scaled = i * 256 / 360
	msg.writeByte(sb, bit32.band(if scaled >= 0 then math.floor(scaled) else -math.floor(-scaled), 255))
end

-- SZ_Write: append another buffer's contents
function msg.writeBuf(sb: SizeBuf, src: buffer, len: number)
	local pos = getSpace(sb, len)
	buffer.copy(sb.data, pos, src, 0, len)
end

-- Snapshot the current contents as a fresh buffer (for sending).
function msg.snapshot(sb: SizeBuf): buffer
	local out = buffer.create(sb.cursize)
	buffer.copy(out, 0, sb.data, 0, sb.cursize)
	return out
end

--------------------------------------------------------------------------
-- reading

function msg.reader(data: buffer): Reader
	return { data = data, size = buffer.len(data), readcount = 0, badread = false }
end

function msg.readChar(r: Reader): number
	if r.readcount + 1 > r.size then
		r.badread = true
		return -1
	end
	local c = buffer.readi8(r.data, r.readcount)
	r.readcount += 1
	return c
end

function msg.readByte(r: Reader): number
	if r.readcount + 1 > r.size then
		r.badread = true
		return -1
	end
	local c = buffer.readu8(r.data, r.readcount)
	r.readcount += 1
	return c
end

function msg.readShort(r: Reader): number
	if r.readcount + 2 > r.size then
		r.badread = true
		return -1
	end
	local c = buffer.readi16(r.data, r.readcount)
	r.readcount += 2
	return c
end

function msg.readLong(r: Reader): number
	if r.readcount + 4 > r.size then
		r.badread = true
		return -1
	end
	local c = buffer.readi32(r.data, r.readcount)
	r.readcount += 4
	return c
end

function msg.readFloat(r: Reader): number
	if r.readcount + 4 > r.size then
		r.badread = true
		return -1
	end
	local f = buffer.readf32(r.data, r.readcount)
	r.readcount += 4
	return f
end

function msg.readString(r: Reader): string
	local out = {}
	while true do
		local c = msg.readChar(r)
		if c == -1 or c == 0 then
			break
		end
		table.insert(out, string.char(bit32.band(c, 0xff)))
	end
	return table.concat(out)
end

function msg.readCoord(r: Reader): number
	return msg.readShort(r) * (1 / 8)
end

-- QW MSG_ReadAngle16
function msg.readAngle16(r: Reader): number
	return msg.readShort(r) * (360 / 65536)
end

function msg.readAngle(r: Reader): number
	return msg.readChar(r) * (360 / 256)
end

return msg
