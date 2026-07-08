-- netsplit: unreliable-datagram fragmentation/reassembly (transport layer)
local netsplit = require("../src/shared/netsplit")

local checks = 0
local function check(cond: boolean, label: string)
	checks += 1
	if not cond then
		error(`FAIL: {label}`)
	end
	print(`ok {checks} - {label}`)
end

local function mkbuf(len: number, seed: number): buffer
	local b = buffer.create(len)
	for i = 0, len - 1 do
		buffer.writeu8(b, i, (seed + i * 7) % 256)
	end
	return b
end

local function eq(a: buffer, b: buffer): boolean
	if buffer.len(a) ~= buffer.len(b) then
		return false
	end
	return buffer.tostring(a) == buffer.tostring(b)
end

-- small datagram: single fragment, roundtrips
local recv = netsplit.receiver()
local got: { buffer } = {}
local function deliver(b: buffer)
	table.insert(got, b)
end
local small = mkbuf(120, 3)
local frags = netsplit.wrap(1, small)
check(#frags == 1, "small datagram = one fragment")
recv(frags[1], deliver)
check(#got == 1 and eq(got[1], small), "small datagram roundtrips")

-- big datagram: fragments, each under the unreliable ceiling, reassembles
local big = mkbuf(2000, 11)
frags = netsplit.wrap(2, big)
check(#frags == 3, "2000B datagram = three fragments")
for _, f in frags do
	check(buffer.len(f) <= 850, "fragment under the unreliable ceiling")
end
for _, f in frags do
	recv(f, deliver)
end
check(#got == 2 and eq(got[2], big), "big datagram reassembles")

-- out-of-order fragments within a frame still reassemble
local b3 = mkbuf(1500, 42)
frags = netsplit.wrap(3, b3)
recv(frags[2], deliver)
recv(frags[1], deliver)
check(#got == 3 and eq(got[3], b3), "out-of-order fragments reassemble")

-- lost fragment: frame never delivers, next frame does
local b4 = mkbuf(1700, 99)
frags = netsplit.wrap(4, b4)
recv(frags[1], deliver) -- frags[2]/[3] lost
local b5 = mkbuf(300, 5)
frags = netsplit.wrap(5, b5)
recv(frags[1], deliver)
check(#got == 4 and eq(got[4], b5), "incomplete frame dropped, next frame delivers")

-- stale frame after a newer one delivered: discarded (NQ NET semantics)
local b6 = mkbuf(200, 8)
frags = netsplit.wrap(4, b6) -- older seq than the delivered 5
recv(frags[1], deliver)
check(#got == 4, "stale frame discarded after newer delivery")

-- late fragment completing an OLD frame after a newer delivered: discarded
local b7 = mkbuf(1000, 13)
local f7 = netsplit.wrap(7, b7)
recv(f7[1], deliver)
local b8 = mkbuf(100, 21)
recv(netsplit.wrap(8, b8)[1], deliver)
check(#got == 5 and eq(got[5], b8), "newer frame delivers past a partial older one")
recv(f7[2], deliver)
check(#got == 5, "late completion of an older frame is discarded")

-- duplicate fragment resends are idempotent
local b9 = mkbuf(900, 33)
local f9 = netsplit.wrap(9, b9)
recv(f9[1], deliver)
recv(f9[1], deliver)
recv(f9[2], deliver)
check(#got == 6 and eq(got[6], b9), "duplicate fragments are idempotent")

-- non-netsplit garbage is ignored
recv(mkbuf(3, 1), deliver)
recv(mkbuf(50, 200), deliver)
check(#got == 6, "garbage/foreign packets ignored")

print(`netsplit: {checks} checks passed`)
