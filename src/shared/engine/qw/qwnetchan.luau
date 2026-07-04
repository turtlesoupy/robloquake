--!strict
-- Netchan-lite: QW netchan.c sequence/ack bookkeeping over a reliable,
-- ordered transport (Roblox remotes). The original interleaves a
-- retransmitted reliable stream with the datagram via fragment bits in
-- the sequence words; the transport already guarantees delivery and
-- order, so the reliable stream rides in-band with an explicit length
-- word instead. Sequence numbers keep their exact protocol role: delta
-- compression and prediction key off them (frames[seq & UPDATE_MASK]).

local msg = require("../common/msg")

local qwnetchan = {}

export type Netchan = {
	outgoing_sequence: number,
	incoming_sequence: number,
	incoming_acknowledged: number,
	drop_count: number, -- net_drop: dropped packets detected on receive
	message: msg.SizeBuf, -- reliable stream, flushed into each transmit
}

function qwnetchan.new(): Netchan
	return {
		outgoing_sequence = 0,
		incoming_sequence = 0,
		incoming_acknowledged = 0,
		drop_count = 0,
		message = msg.newBuf(8192),
	}
end

-- Netchan_Transmit: [seq:long][ack:long][reliable][datagram] — the
-- receiver parses the payload as one svc/clc stream, same as the C
function qwnetchan.transmit(chan: Netchan, datagram: msg.SizeBuf?): buffer
	-- C semantics: the packet carries the CURRENT outgoing_sequence and
	-- increments after — senders store per-sequence state (cmds, frames)
	-- at outgoing_sequence & UPDATE_MASK before transmitting
	local reliableLen = chan.message.cursize
	local dgLen = if datagram then datagram.cursize else 0
	local out = buffer.create(8 + reliableLen + dgLen)
	buffer.writeu32(out, 0, chan.outgoing_sequence)
	buffer.writeu32(out, 4, chan.incoming_sequence)
	chan.outgoing_sequence += 1
	buffer.copy(out, 8, chan.message.data, 0, reliableLen)
	if datagram and dgLen > 0 then
		buffer.copy(out, 8 + reliableLen, datagram.data, 0, dgLen)
	end
	msg.clear(chan.message)
	if datagram then
		msg.clear(datagram)
	end
	return out
end

-- Netchan_Process: updates sequences, returns a reader over the
-- payload (reliable content followed by the datagram, in order)
function qwnetchan.process(chan: Netchan, packet: buffer): msg.Reader?
	local seq = buffer.readu32(packet, 0)
	local ack = buffer.readu32(packet, 4)
	if seq <= chan.incoming_sequence and chan.incoming_sequence > 0 then
		return nil -- out of order / duplicated packet, discard
	end
	chan.drop_count = seq - (chan.incoming_sequence + 1)
	chan.incoming_sequence = seq
	chan.incoming_acknowledged = ack
	local payload = buffer.create(buffer.len(packet) - 8)
	buffer.copy(payload, 0, packet, 8)
	return msg.reader(payload)
end

return qwnetchan
