--!strict
-- QW netchan.c over Roblox remotes. The original protocol survives
-- whole: bit 31 of the sequence word flags in-band reliable content,
-- bit 31 of the ack word carries the 1-bit reliable-ack sequence, and
-- unacknowledged reliable data retransmits once the peer provably saw a
-- later packet without toggling its reliable-ack bit (netchan.c's
-- resend condition). This lets datagrams ride an UnreliableRemoteEvent:
-- drops and reordering are recovered exactly like QW over UDP. Senders
-- get (packet, hasReliable) back from transmit so the transport can
-- route reliable-bearing packets over the guaranteed RemoteEvent — the
-- handshake is a strict content-driven lockstep with no retry clock, so
-- it must never lose a packet. Sequence numbers keep their exact
-- protocol role: delta compression and prediction key off them
-- (frames[seq & UPDATE_MASK]).

local msg = require("../common/msg")

local qwnetchan = {}

local RELIABLE_BIT = 0x80000000
local SEQ_MASK = 0x7FFFFFFF

export type Netchan = {
	outgoing_sequence: number,
	incoming_sequence: number,
	incoming_acknowledged: number,
	incoming_reliable_acknowledged: number, -- single bit: peer's last reliable-ack
	incoming_reliable_sequence: number, -- single bit, maintained local (our ack)
	reliable_sequence: number, -- single bit: sequence of the pending reliable
	last_reliable_sequence: number, -- outgoing seq AFTER the last reliable send
	drop_count: number, -- net_drop: dropped packets detected on receive
	message: msg.SizeBuf, -- reliable stream, copied out into reliable_buf
	reliable_buf: buffer, -- unacknowledged reliable message (retransmits)
	reliable_length: number,
}

function qwnetchan.new(): Netchan
	return {
		-- first packet is seq 1: C's memset-zero start loses each
		-- channel's first packet to the stale guard (seq 0 <= 0) and
		-- heals by retransmit; starting at 1 keeps the guard exact —
		-- crucial here because reliable-bearing packets are duplicated
		-- across both remotes and the duplicate must always be discarded
		outgoing_sequence = 1,
		incoming_sequence = 0,
		incoming_acknowledged = 0,
		incoming_reliable_acknowledged = 0,
		incoming_reliable_sequence = 0,
		reliable_sequence = 0,
		last_reliable_sequence = 0,
		drop_count = 0,
		-- net_chan.c sets allowoverflow: an overfull reliable stream
		-- flags + clears instead of erroring; the server's per-frame
		-- sweep drops the client (sv_send.c SV_SendClientMessages)
		message = msg.newBuf(8192, true),
		reliable_buf = buffer.create(8192),
		reliable_length = 0,
	}
end

-- Netchan_Transmit: [w1:seq|rel<<31][w2:ack|relseq<<31][reliable][datagram]
-- — the receiver parses the payload as one svc/clc stream, same as the C.
-- Returns the packet and whether it carries reliable content.
function qwnetchan.transmit(chan: Netchan, datagram: msg.SizeBuf?): (buffer, boolean)
	-- if the remote side dropped the last reliable message, resend it:
	-- it acked a packet sent after the reliable one, yet its reliable-ack
	-- bit still doesn't match — the reliable packet was never processed
	local send_reliable = false
	if chan.incoming_acknowledged > chan.last_reliable_sequence and chan.incoming_reliable_acknowledged ~= chan.reliable_sequence then
		send_reliable = true
	end

	-- if the reliable transmit buffer is empty, copy the current message out
	if chan.reliable_length == 0 and chan.message.cursize > 0 then
		buffer.copy(chan.reliable_buf, 0, chan.message.data, 0, chan.message.cursize)
		chan.reliable_length = chan.message.cursize
		msg.clear(chan.message)
		chan.reliable_sequence = bit32.bxor(chan.reliable_sequence, 1)
		send_reliable = true
	end

	-- C semantics: the packet carries the CURRENT outgoing_sequence and
	-- increments after — senders store per-sequence state (cmds, frames)
	-- at outgoing_sequence & UPDATE_MASK before transmitting
	local reliableLen = if send_reliable then chan.reliable_length else 0
	local dgLen = if datagram then datagram.cursize else 0
	local out = buffer.create(8 + reliableLen + dgLen)
	buffer.writeu32(out, 0, bit32.bor(chan.outgoing_sequence, if send_reliable then RELIABLE_BIT else 0))
	buffer.writeu32(out, 4, bit32.bor(chan.incoming_sequence, bit32.lshift(chan.incoming_reliable_sequence, 31)))
	chan.outgoing_sequence += 1
	if send_reliable then
		buffer.copy(out, 8, chan.reliable_buf, 0, reliableLen)
		chan.last_reliable_sequence = chan.outgoing_sequence
	end
	if datagram then
		if dgLen > 0 then
			buffer.copy(out, 8 + reliableLen, datagram.data, 0, dgLen)
		end
		msg.clear(datagram)
	end
	return out, send_reliable
end

-- Netchan_Process: updates sequences, returns a reader over the
-- payload (reliable content followed by the datagram, in order), or
-- nil for stale/duplicated packets (which the caller must discard —
-- an unreliable transport delivers out of order)
function qwnetchan.process(chan: Netchan, packet: buffer): msg.Reader?
	local w1 = buffer.readu32(packet, 0)
	local w2 = buffer.readu32(packet, 4)
	local seq = bit32.band(w1, SEQ_MASK)
	local ack = bit32.band(w2, SEQ_MASK)
	local reliable_message = bit32.rshift(w1, 31)
	local reliable_ack = bit32.rshift(w2, 31)
	if seq <= chan.incoming_sequence then
		return nil -- out of order / duplicated packet, discard
	end
	chan.drop_count = math.max(seq - (chan.incoming_sequence + 1), 0)
	-- if the current outgoing reliable message has been acknowledged,
	-- clear the buffer to make way for the next
	if reliable_ack == chan.reliable_sequence then
		chan.reliable_length = 0 -- it has been received
	end
	chan.incoming_sequence = seq
	chan.incoming_acknowledged = ack
	chan.incoming_reliable_acknowledged = reliable_ack
	if reliable_message == 1 then
		chan.incoming_reliable_sequence = bit32.bxor(chan.incoming_reliable_sequence, 1)
	end
	local payload = buffer.create(buffer.len(packet) - 8)
	buffer.copy(payload, 0, packet, 8)
	return msg.reader(payload)
end

return qwnetchan
