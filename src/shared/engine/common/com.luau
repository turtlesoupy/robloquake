--!strict
--!optimize 2
-- Text tokenizer and CRC16 — ports of COM_Parse and the CRC routines from
-- WinQuake common.c / crc.c.

local com = {}

-- Single-character tokens in COM_Parse
local function isSingle(c: number): boolean
	return c == 123 or c == 125 or c == 41 or c == 40 or c == 39 or c == 58 -- { } ) ( ' :
end

-- COM_Parse: parse a token out of a string starting at pos (1-based).
-- Returns the token and the position after it, or nil at end of data.
-- Mirrors the C version: whitespace is any char <= ' ', // comments are
-- skipped, quoted strings keep everything up to the closing quote.
function com.parse(data: string, pos: number): (string?, number)
	local len = #data

	-- skip whitespace
	while true do
		while pos <= len do
			local c = data:byte(pos)
			if c > 32 then
				break
			end
			pos += 1
		end
		if pos > len then
			return nil, pos
		end
		-- skip // comments
		if data:byte(pos) == 47 and data:byte(pos + 1) == 47 then
			while pos <= len and data:byte(pos) ~= 10 do
				pos += 1
			end
		else
			break
		end
	end

	local c = data:byte(pos)

	-- handle quoted strings specially
	if c == 34 then -- '"'
		pos += 1
		local start = pos
		while pos <= len and data:byte(pos) ~= 34 do
			pos += 1
		end
		return data:sub(start, pos - 1), pos + 1
	end

	-- parse single characters
	if isSingle(c) then
		return data:sub(pos, pos), pos + 1
	end

	-- parse a regular word
	local start = pos
	repeat
		pos += 1
		c = data:byte(pos) or 0
		if isSingle(c) then
			break
		end
	until c <= 32
	return data:sub(start, pos - 1), pos
end

-- atof/atoi with C semantics: leading number parsed, garbage ignored,
-- 0 on failure. QC files only contain plain decimal numbers.
function com.atof(s: string): number
	local n = tonumber(s)
	if n then
		return n
	end
	local m = s:match("^%s*(-?%d+%.?%d*)")
	return if m then tonumber(m) or 0 else 0
end

function com.atoi(s: string): number
	local f = com.atof(s)
	return if f >= 0 then math.floor(f) else -math.floor(-f)
end

-- libc atof semantics (ED_ParseEpair / PF_stof use plain atof, not
-- Q_atof): decimal + exponent only — NO hex ("0x1A" parses the leading
-- 0 and stops at 'x')
function com.atofC(s: string): number
	if s:match("^%s*[-+]?0[xX]") then
		return 0
	end
	return com.atof(s)
end

-- CRC-16 CCITT as in crc.c (init 0xffff, poly 0x1021, no final xor)
local CRC_INIT_VALUE = 0xffff

local crctable: { number } = table.create(256)
do
	for i = 0, 255 do
		local value = bit32.lshift(i, 8)
		for _ = 1, 8 do
			if bit32.band(value, 0x8000) ~= 0 then
				value = bit32.bxor(bit32.lshift(value, 1), 0x1021)
			else
				value = bit32.lshift(value, 1)
			end
			value = bit32.band(value, 0xffff)
		end
		crctable[i + 1] = value
	end
end

function com.crcBuffer(buf: buffer): number
	local crc = CRC_INIT_VALUE
	for i = 0, buffer.len(buf) - 1 do
		local byte = buffer.readu8(buf, i)
		crc = bit32.band(bit32.bxor(bit32.lshift(crc, 8), crctable[bit32.rshift(crc, 8) + 1], 0), 0xffff)
		crc = bit32.bxor(crc, byte) -- CRC_ProcessByte: (crc << 8) ^ table[crc >> 8] ^ data
	end
	return crc
end

-- Cmd_CompleteCommand over a supplied name list: exact match wins, then
-- the first prefix match (list sorted for determinism; C scans
-- registration order)
function com.completePrefix(names: { string }, partial: string): string?
	if partial == "" then
		return nil
	end
	local sorted = table.clone(names)
	table.sort(sorted)
	for _, name in sorted do
		if name == partial then
			return name
		end
	end
	for _, name in sorted do
		if name:sub(1, #partial) == partial then
			return name
		end
	end
	return nil
end

return com
