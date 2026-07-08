--!strict
-- Unreliable-datagram fragmentation (PRODUCT transport layer, both boots).
--
-- UnreliableRemoteEvents silently drop payloads over ~900 bytes. The old
-- workaround routed oversized datagrams onto the reliable RemoteEvent —
-- which is ordered and retransmitted, so on a lossy/jittery link one
-- delayed busy frame head-of-line-blocked every frame behind it: the
-- rhythmic ~1s "chunking" playtesters felt under real network conditions
-- (frames are biggest exactly during motion/combat). Quake's protocol
-- wants stale frames DROPPED, never delivered late.
--
-- Instead: every server->client datagram rides the unreliable channel,
-- split into <=CHUNK fragments with a 7-byte header
--   [u8 MAGIC][u32 seq][u8 index][u8 count]
-- The receiver reassembles complete frames and delivers only frames newer
-- than the last delivered one (original NQ NET-layer semantics — its
-- unreliable sequence numbers discarded stale datagrams; QW's netchan does
-- its own sequencing on top and treats a discarded frame as a normal
-- drop). A frame missing any fragment is simply never delivered.

local netsplit = {}

local MAGIC = 0xF7
local HEADER = 7
-- fragment payload; header + payload stays well under the ~900-byte
-- UnreliableRemoteEvent ceiling (the old code trusted 850 total)
local CHUNK = 800

-- wrap one datagram into ready-to-send fragments (always wrapped, even
-- single-fragment, so the receive path is uniform)
function netsplit.wrap(seq: number, data: buffer): { buffer }
	local len = buffer.len(data)
	local count = math.max(1, math.ceil(len / CHUNK))
	local out = table.create(count)
	for i = 1, count do
		local ofs = (i - 1) * CHUNK
		local n = math.min(CHUNK, len - ofs)
		local frag = buffer.create(HEADER + n)
		buffer.writeu8(frag, 0, MAGIC)
		buffer.writeu32(frag, 1, seq)
		buffer.writeu8(frag, 5, i - 1)
		buffer.writeu8(frag, 6, count)
		buffer.copy(frag, HEADER, data, ofs, n)
		out[i] = frag
	end
	return out
end

type Group = { count: number, got: number, parts: { [number]: buffer } }

-- per-connection reassembler: feed received fragments, get whole datagrams.
-- Delivers a frame at most once, newest-wins; older frames (and partial
-- groups they belonged to) are discarded.
function netsplit.receiver(): (frag: buffer, deliver: (buffer) -> ()) -> ()
	local lastDelivered = 0
	local groups: { [number]: Group } = {}
	return function(frag: buffer, deliver: (buffer) -> ())
		if buffer.len(frag) < HEADER or buffer.readu8(frag, 0) ~= MAGIC then
			return -- not ours; ignore
		end
		local seq = buffer.readu32(frag, 1)
		local idx = buffer.readu8(frag, 5)
		local count = buffer.readu8(frag, 6)
		if seq <= lastDelivered or count == 0 or idx >= count then
			return -- stale or malformed
		end
		local g = groups[seq]
		if not g then
			g = { count = count, got = 0, parts = {} }
			groups[seq] = g
		end
		if g.count ~= count or g.parts[idx] then
			return -- inconsistent resend; keep the first
		end
		local n = buffer.len(frag) - HEADER
		local part = buffer.create(n)
		buffer.copy(part, 0, frag, HEADER, n)
		g.parts[idx] = part
		g.got += 1
		if g.got < g.count then
			return
		end
		-- complete: stitch and deliver, then drop everything at or below
		local total = 0
		for i = 0, g.count - 1 do
			total += buffer.len(g.parts[i])
		end
		local whole = buffer.create(total)
		local ofs = 0
		for i = 0, g.count - 1 do
			local p = g.parts[i]
			buffer.copy(whole, ofs, p, 0, buffer.len(p))
			ofs += buffer.len(p)
		end
		lastDelivered = seq
		for s in groups do
			if s <= seq then
				groups[s] = nil
			end
		end
		deliver(whole)
	end
end

return netsplit
