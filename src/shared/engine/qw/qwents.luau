--!strict
-- QW entity/usercmd delta codec — sv_ents.c writers and the matching
-- client parsers (cl_ents.c), plus MSG_Write/ReadDeltaUsercmd. Shared by
-- qwsv (encode) and qwcl (decode); the loopback test round-trips both.

local msg = require("../common/msg")
local qwp = require("./qwprotocol")

local qwents = {}

qwents.MAX_PACKET_ENTITIES = 64

export type EntityState = {
	number: number,
	flags: number,
	origin: vector,
	angles: vector,
	modelindex: number,
	frame: number,
	colormap: number,
	skinnum: number,
	effects: number,
}

export type PacketEntities = { EntityState }

function qwents.nullState(number: number): EntityState
	return {
		number = number,
		flags = 0,
		origin = vector.zero,
		angles = vector.zero,
		modelindex = 0,
		frame = 0,
		colormap = 0,
		skinnum = 0,
		effects = 0,
	}
end

export type UserCmdWire = {
	angles: vector,
	forwardmove: number,
	sidemove: number,
	upmove: number,
	buttons: number,
	impulse: number,
	msec: number,
}

function qwents.nullCmd(): UserCmdWire
	return { angles = vector.zero, forwardmove = 0, sidemove = 0, upmove = 0, buttons = 0, impulse = 0, msec = 0 }
end

--------------------------------------------------------------------------
-- MSG_WriteDeltaUsercmd / MSG_ReadDeltaUsercmd

function qwents.writeDeltaUsercmd(sb: msg.SizeBuf, from: UserCmdWire, cmd: UserCmdWire)
	local bits = 0
	if cmd.angles.x ~= from.angles.x then
		bits = bit32.bor(bits, qwp.CM_ANGLE1)
	end
	if cmd.angles.y ~= from.angles.y then
		bits = bit32.bor(bits, qwp.CM_ANGLE2)
	end
	if cmd.angles.z ~= from.angles.z then
		bits = bit32.bor(bits, qwp.CM_ANGLE3)
	end
	if cmd.forwardmove ~= from.forwardmove then
		bits = bit32.bor(bits, qwp.CM_FORWARD)
	end
	if cmd.sidemove ~= from.sidemove then
		bits = bit32.bor(bits, qwp.CM_SIDE)
	end
	if cmd.upmove ~= from.upmove then
		bits = bit32.bor(bits, qwp.CM_UP)
	end
	if cmd.buttons ~= from.buttons then
		bits = bit32.bor(bits, qwp.CM_BUTTONS)
	end
	if cmd.impulse ~= from.impulse then
		bits = bit32.bor(bits, qwp.CM_IMPULSE)
	end

	msg.writeByte(sb, bits)
	if bit32.band(bits, qwp.CM_ANGLE1) ~= 0 then
		msg.writeAngle16(sb, cmd.angles.x)
	end
	if bit32.band(bits, qwp.CM_ANGLE2) ~= 0 then
		msg.writeAngle16(sb, cmd.angles.y)
	end
	if bit32.band(bits, qwp.CM_ANGLE3) ~= 0 then
		msg.writeAngle16(sb, cmd.angles.z)
	end
	if bit32.band(bits, qwp.CM_FORWARD) ~= 0 then
		msg.writeShort(sb, cmd.forwardmove)
	end
	if bit32.band(bits, qwp.CM_SIDE) ~= 0 then
		msg.writeShort(sb, cmd.sidemove)
	end
	if bit32.band(bits, qwp.CM_UP) ~= 0 then
		msg.writeShort(sb, cmd.upmove)
	end
	if bit32.band(bits, qwp.CM_BUTTONS) ~= 0 then
		msg.writeByte(sb, cmd.buttons)
	end
	if bit32.band(bits, qwp.CM_IMPULSE) ~= 0 then
		msg.writeByte(sb, cmd.impulse)
	end
	msg.writeByte(sb, cmd.msec)
end

function qwents.readDeltaUsercmd(r: msg.Reader, from: UserCmdWire): UserCmdWire
	local bits = msg.readByte(r)
	local ax, ay, az = from.angles.x, from.angles.y, from.angles.z
	if bit32.band(bits, qwp.CM_ANGLE1) ~= 0 then
		ax = msg.readAngle16(r)
	end
	if bit32.band(bits, qwp.CM_ANGLE2) ~= 0 then
		ay = msg.readAngle16(r)
	end
	if bit32.band(bits, qwp.CM_ANGLE3) ~= 0 then
		az = msg.readAngle16(r)
	end
	local cmd: UserCmdWire = {
		angles = vector.create(ax, ay, az),
		forwardmove = if bit32.band(bits, qwp.CM_FORWARD) ~= 0 then msg.readShort(r) else from.forwardmove,
		sidemove = if bit32.band(bits, qwp.CM_SIDE) ~= 0 then msg.readShort(r) else from.sidemove,
		upmove = if bit32.band(bits, qwp.CM_UP) ~= 0 then msg.readShort(r) else from.upmove,
		buttons = if bit32.band(bits, qwp.CM_BUTTONS) ~= 0 then msg.readByte(r) else from.buttons,
		impulse = if bit32.band(bits, qwp.CM_IMPULSE) ~= 0 then msg.readByte(r) else from.impulse,
		msec = 0,
	}
	cmd.msec = msg.readByte(r)
	return cmd
end

--------------------------------------------------------------------------
-- SV_WriteDelta

function qwents.writeDelta(sb: msg.SizeBuf, from: EntityState, to: EntityState, force: boolean)
	local bits = 0

	local miss = to.origin.x - from.origin.x
	if miss < -0.1 or miss > 0.1 then
		bits = bit32.bor(bits, qwp.U_ORIGIN1)
	end
	miss = to.origin.y - from.origin.y
	if miss < -0.1 or miss > 0.1 then
		bits = bit32.bor(bits, qwp.U_ORIGIN2)
	end
	miss = to.origin.z - from.origin.z
	if miss < -0.1 or miss > 0.1 then
		bits = bit32.bor(bits, qwp.U_ORIGIN3)
	end

	if to.angles.x ~= from.angles.x then
		bits = bit32.bor(bits, qwp.U_ANGLE1)
	end
	if to.angles.y ~= from.angles.y then
		bits = bit32.bor(bits, qwp.U_ANGLE2)
	end
	if to.angles.z ~= from.angles.z then
		bits = bit32.bor(bits, qwp.U_ANGLE3)
	end
	if to.colormap ~= from.colormap then
		bits = bit32.bor(bits, qwp.U_COLORMAP)
	end
	if to.skinnum ~= from.skinnum then
		bits = bit32.bor(bits, qwp.U_SKIN)
	end
	if to.frame ~= from.frame then
		bits = bit32.bor(bits, qwp.U_FRAME)
	end
	if to.effects ~= from.effects then
		bits = bit32.bor(bits, qwp.U_EFFECTS)
	end
	if to.modelindex ~= from.modelindex then
		bits = bit32.bor(bits, qwp.U_MODEL)
	end

	if bit32.band(bits, 511) ~= 0 then
		bits = bit32.bor(bits, qwp.U_MOREBITS)
	end
	if bit32.band(to.flags, qwp.U_SOLID) ~= 0 then
		bits = bit32.bor(bits, qwp.U_SOLID)
	end

	if to.number == 0 then
		error("Unset entity number")
	end
	if to.number >= 512 then
		error("Entity number >= 512")
	end

	if bits == 0 and not force then
		return
	end

	msg.writeShort(sb, bit32.bor(to.number, bit32.band(bits, bit32.bnot(511))))
	if bit32.band(bits, qwp.U_MOREBITS) ~= 0 then
		msg.writeByte(sb, bit32.band(bits, 255))
	end
	if bit32.band(bits, qwp.U_MODEL) ~= 0 then
		msg.writeByte(sb, to.modelindex)
	end
	if bit32.band(bits, qwp.U_FRAME) ~= 0 then
		msg.writeByte(sb, to.frame)
	end
	if bit32.band(bits, qwp.U_COLORMAP) ~= 0 then
		msg.writeByte(sb, to.colormap)
	end
	if bit32.band(bits, qwp.U_SKIN) ~= 0 then
		msg.writeByte(sb, to.skinnum)
	end
	if bit32.band(bits, qwp.U_EFFECTS) ~= 0 then
		msg.writeByte(sb, to.effects)
	end
	if bit32.band(bits, qwp.U_ORIGIN1) ~= 0 then
		msg.writeCoord(sb, to.origin.x)
	end
	if bit32.band(bits, qwp.U_ANGLE1) ~= 0 then
		msg.writeAngleQW(sb, to.angles.x)
	end
	if bit32.band(bits, qwp.U_ORIGIN2) ~= 0 then
		msg.writeCoord(sb, to.origin.y)
	end
	if bit32.band(bits, qwp.U_ANGLE2) ~= 0 then
		msg.writeAngleQW(sb, to.angles.y)
	end
	if bit32.band(bits, qwp.U_ORIGIN3) ~= 0 then
		msg.writeCoord(sb, to.origin.z)
	end
	if bit32.band(bits, qwp.U_ANGLE3) ~= 0 then
		msg.writeAngleQW(sb, to.angles.z)
	end
end

--------------------------------------------------------------------------
-- SV_EmitPacketEntities: delta the new frame against the client-acked one

function qwents.emitPacketEntities(
	sb: msg.SizeBuf,
	to: PacketEntities,
	from: PacketEntities?, -- acked frame's entities, nil = no delta
	deltaSequence: number?, -- what the client asked to delta from
	baselineFor: (number) -> EntityState
)
	local oldmax
	if from then
		msg.writeByte(sb, qwp.svc_deltapacketentities)
		msg.writeByte(sb, deltaSequence :: number)
		oldmax = #from
	else
		msg.writeByte(sb, qwp.svc_packetentities)
		oldmax = 0
	end

	local newindex, oldindex = 1, 1
	while newindex <= #to or oldindex <= oldmax do
		local newnum = if newindex <= #to then to[newindex].number else 9999
		local oldnum = if oldindex <= oldmax then (from :: PacketEntities)[oldindex].number else 9999

		if newnum == oldnum then
			qwents.writeDelta(sb, (from :: PacketEntities)[oldindex], to[newindex], false)
			oldindex += 1
			newindex += 1
		elseif newnum < oldnum then
			-- new entity: send from the baseline
			qwents.writeDelta(sb, baselineFor(newnum), to[newindex], true)
			newindex += 1
		else
			-- the old entity isn't in the new message
			msg.writeShort(sb, bit32.bor(oldnum, qwp.U_REMOVE))
			oldindex += 1
		end
	end

	msg.writeShort(sb, 0) -- end of packetentities
end

--------------------------------------------------------------------------
-- CL_ParsePacketEntities / CL_ParseDelta (the client side)

-- parse one entity delta given its from-state; returns the new state
function qwents.parseDelta(r: msg.Reader, from: EntityState, number: number, bits: number): EntityState
	if bit32.band(bits, qwp.U_MOREBITS) ~= 0 then
		bits = bit32.bor(bits, msg.readByte(r))
	end
	local to: EntityState = {
		number = number,
		flags = bits,
		origin = from.origin,
		angles = from.angles,
		modelindex = from.modelindex,
		frame = from.frame,
		colormap = from.colormap,
		skinnum = from.skinnum,
		effects = from.effects,
	}
	if bit32.band(bits, qwp.U_MODEL) ~= 0 then
		to.modelindex = msg.readByte(r)
	end
	if bit32.band(bits, qwp.U_FRAME) ~= 0 then
		to.frame = msg.readByte(r)
	end
	if bit32.band(bits, qwp.U_COLORMAP) ~= 0 then
		to.colormap = msg.readByte(r)
	end
	if bit32.band(bits, qwp.U_SKIN) ~= 0 then
		to.skinnum = msg.readByte(r)
	end
	if bit32.band(bits, qwp.U_EFFECTS) ~= 0 then
		to.effects = msg.readByte(r)
	end
	local ox, oy, oz = to.origin.x, to.origin.y, to.origin.z
	local ax, ay, az = to.angles.x, to.angles.y, to.angles.z
	if bit32.band(bits, qwp.U_ORIGIN1) ~= 0 then
		ox = msg.readCoord(r)
	end
	if bit32.band(bits, qwp.U_ANGLE1) ~= 0 then
		ax = msg.readAngle(r)
	end
	if bit32.band(bits, qwp.U_ORIGIN2) ~= 0 then
		oy = msg.readCoord(r)
	end
	if bit32.band(bits, qwp.U_ANGLE2) ~= 0 then
		ay = msg.readAngle(r)
	end
	if bit32.band(bits, qwp.U_ORIGIN3) ~= 0 then
		oz = msg.readCoord(r)
	end
	if bit32.band(bits, qwp.U_ANGLE3) ~= 0 then
		az = msg.readAngle(r)
	end
	to.origin = vector.create(ox, oy, oz)
	to.angles = vector.create(ax, ay, az)
	return to
end

-- parse a whole svc_packetentities / svc_deltapacketentities payload
-- (after the svc byte and, for deltas, the from-sequence byte).
-- from = the acked frame's entities (empty for a full update).
function qwents.parsePacketEntities(
	r: msg.Reader,
	from: PacketEntities,
	baselineFor: (number) -> EntityState
): PacketEntities
	local out: PacketEntities = {}
	local oldindex = 1
	local function capCheck()
		if #out > qwents.MAX_PACKET_ENTITIES then
			error("CL_ParsePacketEntities: newindex == MAX_PACKET_ENTITIES")
		end
	end

	while true do
		local word = msg.readShort(r)
		if r.badread then
			error("msg_badread in packetentities")
		end
		if word < 0 then
			word += 65536 -- readShort is signed; the wire word is not
		end
		if word == 0 then
			-- copy the rest of the old entities
			while oldindex <= #from do
				capCheck()
			table.insert(out, from[oldindex])
				oldindex += 1
			end
			break
		end

		local newnum = bit32.band(word, 511)
		local bits = bit32.band(word, bit32.bnot(511))

		-- copy unchanged old entities below newnum
		while oldindex <= #from and from[oldindex].number < newnum do
			capCheck()
			table.insert(out, from[oldindex])
			oldindex += 1
		end

		if bit32.band(bits, qwp.U_REMOVE) ~= 0 then
			-- old entity removed: skip it in from
			if oldindex <= #from and from[oldindex].number == newnum then
				oldindex += 1
			end
			continue
		end

		if oldindex <= #from and from[oldindex].number == newnum then
			-- delta from the old state
			capCheck()
			table.insert(out, qwents.parseDelta(r, from[oldindex], newnum, bits))
			oldindex += 1
		else
			-- delta from the baseline
			capCheck()
			table.insert(out, qwents.parseDelta(r, baselineFor(newnum), newnum, bits))
		end
	end

	return out
end

return qwents
