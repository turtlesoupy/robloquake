--!strict
--!optimize 2
-- Base64 encode/decode for buffers. Used to move pak data through
-- Rojo-synced StringValues (which must be valid UTF-8 text).

local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local CHAR_TO_VAL = buffer.create(256)
for i = 1, 64 do
	buffer.writeu8(CHAR_TO_VAL, ALPHABET:byte(i), i - 1)
end

function base64.encode(data: buffer): string
	local len = buffer.len(data)
	local out = table.create(math.ceil(len / 3))
	local i = 0
	local full = len - len % 3
	while i < full do
		local b0 = buffer.readu8(data, i)
		local b1 = buffer.readu8(data, i + 1)
		local b2 = buffer.readu8(data, i + 2)
		local n = b0 * 65536 + b1 * 256 + b2
		local c0 = math.floor(n / 262144) % 64
		local c1 = math.floor(n / 4096) % 64
		local c2 = math.floor(n / 64) % 64
		local c3 = n % 64
		table.insert(out, string.char(ALPHABET:byte(c0 + 1), ALPHABET:byte(c1 + 1), ALPHABET:byte(c2 + 1), ALPHABET:byte(c3 + 1)))
		i += 3
	end
	local rem = len - full
	if rem == 1 then
		local b0 = buffer.readu8(data, i)
		local n = b0 * 16
		table.insert(out, string.char(ALPHABET:byte(math.floor(n / 64) + 1), ALPHABET:byte(n % 64 + 1)) .. "==")
	elseif rem == 2 then
		local b0 = buffer.readu8(data, i)
		local b1 = buffer.readu8(data, i + 1)
		local n = b0 * 1024 + b1 * 4
		table.insert(
			out,
			string.char(ALPHABET:byte(math.floor(n / 4096) + 1), ALPHABET:byte(math.floor(n / 64) % 64 + 1), ALPHABET:byte(n % 64 + 1)) .. "="
		)
	end
	return table.concat(out)
end

-- Decode into `out` buffer at `outPos`; returns bytes written.
-- Input must be plain base64, no whitespace.
function base64.decodeInto(s: string, out: buffer, outPos: number): number
	local slen = #s
	if slen == 0 then
		return 0
	end
	local pad = 0
	if s:sub(-1) == "=" then
		pad = if s:sub(-2, -2) == "=" then 2 else 1
	end
	local sbuf = buffer.fromstring(s)
	local groups = slen / 4
	local fullGroups = groups - (if pad > 0 then 1 else 0)
	local o = outPos
	local i = 0
	local lut = CHAR_TO_VAL
	for _ = 1, fullGroups do
		local n = buffer.readu8(lut, buffer.readu8(sbuf, i)) * 262144
			+ buffer.readu8(lut, buffer.readu8(sbuf, i + 1)) * 4096
			+ buffer.readu8(lut, buffer.readu8(sbuf, i + 2)) * 64
			+ buffer.readu8(lut, buffer.readu8(sbuf, i + 3))
		buffer.writeu8(out, o, math.floor(n / 65536))
		buffer.writeu8(out, o + 1, math.floor(n / 256) % 256)
		buffer.writeu8(out, o + 2, n % 256)
		i += 4
		o += 3
	end
	if pad == 1 then
		local n = buffer.readu8(lut, buffer.readu8(sbuf, i)) * 262144
			+ buffer.readu8(lut, buffer.readu8(sbuf, i + 1)) * 4096
			+ buffer.readu8(lut, buffer.readu8(sbuf, i + 2)) * 64
		buffer.writeu8(out, o, math.floor(n / 65536))
		buffer.writeu8(out, o + 1, math.floor(n / 256) % 256)
		o += 2
	elseif pad == 2 then
		local n = buffer.readu8(lut, buffer.readu8(sbuf, i)) * 262144 + buffer.readu8(lut, buffer.readu8(sbuf, i + 1)) * 4096
		buffer.writeu8(out, o, math.floor(n / 65536))
		o += 1
	end
	return o - outPos
end

function base64.decodedLen(s: string): number
	local slen = #s
	if slen == 0 then
		return 0
	end
	local pad = 0
	if s:sub(-1) == "=" then
		pad = if s:sub(-2, -2) == "=" then 2 else 1
	end
	return slen / 4 * 3 - pad
end

function base64.decode(s: string): buffer
	local out = buffer.create(base64.decodedLen(s))
	base64.decodeInto(s, out, 0)
	return out
end

return base64
