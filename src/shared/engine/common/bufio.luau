--!strict
--!optimize 2
--!native
-- Binary reading helpers over Luau buffers.
-- Quake data is all little-endian, which matches buffer.read* natively.

local bufio = {}

export type Reader = {
	buf: buffer,
	pos: number,
	len: number,
	u8: (self: Reader) -> number,
	i8: (self: Reader) -> number,
	u16: (self: Reader) -> number,
	i16: (self: Reader) -> number,
	i32: (self: Reader) -> number,
	u32: (self: Reader) -> number,
	f32: (self: Reader) -> number,
	vec3: (self: Reader) -> vector,
	-- Fixed-size, NUL-padded string field (e.g. the 56-byte pak names)
	strz: (self: Reader, n: number) -> string,
	bytes: (self: Reader, n: number) -> buffer,
	seek: (self: Reader, pos: number) -> (),
	skip: (self: Reader, n: number) -> (),
}

local Reader = {}
Reader.__index = Reader

function Reader.u8(self: Reader): number
	local v = buffer.readu8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Reader.i8(self: Reader): number
	local v = buffer.readi8(self.buf, self.pos)
	self.pos += 1
	return v
end

function Reader.u16(self: Reader): number
	local v = buffer.readu16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Reader.i16(self: Reader): number
	local v = buffer.readi16(self.buf, self.pos)
	self.pos += 2
	return v
end

function Reader.i32(self: Reader): number
	local v = buffer.readi32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Reader.u32(self: Reader): number
	local v = buffer.readu32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Reader.f32(self: Reader): number
	local v = buffer.readf32(self.buf, self.pos)
	self.pos += 4
	return v
end

function Reader.vec3(self: Reader): vector
	local p = self.pos
	self.pos = p + 12
	return vector.create(
		buffer.readf32(self.buf, p),
		buffer.readf32(self.buf, p + 4),
		buffer.readf32(self.buf, p + 8)
	)
end

function Reader.strz(self: Reader, n: number): string
	local raw = buffer.readstring(self.buf, self.pos, n)
	self.pos += n
	local nul = raw:find("\0", 1, true)
	if nul then
		return raw:sub(1, nul - 1)
	end
	return raw
end

function Reader.bytes(self: Reader, n: number): buffer
	local out = buffer.create(n)
	buffer.copy(out, 0, self.buf, self.pos, n)
	self.pos += n
	return out
end

function Reader.seek(self: Reader, pos: number)
	self.pos = pos
end

function Reader.skip(self: Reader, n: number)
	self.pos += n
end

function bufio.reader(buf: buffer, pos: number?): Reader
	return (setmetatable({ buf = buf, pos = pos or 0, len = buffer.len(buf) }, Reader) :: any) :: Reader
end

-- Read a NUL-terminated string at an absolute offset (no fixed field size).
function bufio.cstring(buf: buffer, offset: number): string
	local len = buffer.len(buf)
	local i = offset
	while i < len and buffer.readu8(buf, i) ~= 0 do
		i += 1
	end
	return buffer.readstring(buf, offset, i - offset)
end

-- Copy a slice of a buffer into a fresh buffer.
function bufio.slice(buf: buffer, offset: number, len: number): buffer
	local out = buffer.create(len)
	buffer.copy(out, 0, buf, offset, len)
	return out
end

return bufio
