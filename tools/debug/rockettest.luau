--!strict
-- reproduce the missing rocket explosion sound: fire a rocket at the floor
-- and log every SV_StartSound the server emits
local t = require("../../tests/testutil")
local defs = require("../../src/shared/engine/progs/defs")
local vmlib = require("../../src/shared/engine/progs/vm")
local host = require("../../src/shared/engine/server/host")
local svlib = require("../../src/shared/engine/server/sv")
local msg = require("../../src/shared/engine/common/msg")
local proto = require("../../src/shared/engine/protocol")

local ent = defs.ent

local origStartSound = svlib.startSound
local sounds: { string } = {}
;(svlib :: any).startSound = function(svr, entity, channel, sample, volume, attenuation)
	table.insert(sounds, ("%s @ent%d ch%d"):format(sample, entity.num, channel))
	return origStartSound(svr, entity, channel, sample, volume, attenuation)
end

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(s: string)
	print("[sv] " .. s)
end
host.spawnServer(svr, "e1m1")
local vm = svr.vm

local clientnum = host.findFreeClient(svr) :: number
local client = svr.clients[clientnum]
client.sendUnreliable = function()
	return true
end
client.sendReliable = function()
	return true
end
host.connectClient(svr, clientnum)

local function sendCmd(s: string)
	local out = msg.newBuf(1024)
	msg.writeByte(out, proto.clc_stringcmd)
	msg.writeString(out, s)
	table.insert(client.inbox, msg.snapshot(out))
end

sendCmd("prespawn")
host.frame(svr, 0.05)
sendCmd("spawn")
host.frame(svr, 0.05)
sendCmd("begin")
host.frame(svr, 0.05)
assert(client.spawned, "client spawned")

-- give rocket launcher + rockets, select it
host.clientCommand(svr, client, "give 7")
host.clientCommand(svr, client, "give r 100")

local function move(pitch: number, buttons: number, impulse: number)
	local out = msg.newBuf(64)
	msg.writeByte(out, proto.clc_move)
	msg.writeFloat(out, svr.time)
	msg.writeAngle(out, pitch)
	msg.writeAngle(out, 0)
	msg.writeAngle(out, 0)
	msg.writeShort(out, 0)
	msg.writeShort(out, 0)
	msg.writeShort(out, 0)
	msg.writeByte(out, buttons)
	msg.writeByte(out, impulse)
	table.insert(client.inbox, msg.snapshot(out))
	host.frame(svr, 0.05)
end

move(80, 0, 7) -- select rocket launcher, look at floor
for _ = 1, 5 do
	move(80, 0, 0)
end
print("--- firing ---")
move(80, 1, 0) -- +attack
for i = 1, 40 do
	move(80, 0, 0)
	for en = 0, vm.num_edicts - 1 do
		local e = vm.edicts[en + 1]
		if not e.free and vmlib.edString(vm, e, ent.classname) == "missile" then
			local o = vmlib.edVector(e, ent.origin)
			local v = vmlib.edVector(e, ent.velocity)
			local touchf = vmlib.edFloat(e, ent.touch)
			print(("f%02d missile ent%d org=(%.0f,%.0f,%.0f) vel=(%.0f,%.0f,%.0f) touch=%d movetype=%d solid=%d model=%d frame=%d think=%d nextthink=%.2f"):format(
				i, en, o.x, o.y, o.z, v.x, v.y, v.z, touchf, vmlib.edFloat(e, ent.movetype),
				vmlib.edFloat(e, ent.solid), vmlib.edFloat(e, ent.modelindex), vmlib.edFloat(e, ent.frame),
				vmlib.edFloat(e, ent.think), vmlib.edFloat(e, ent.nextthink)))
		end
	end
end

print("sounds emitted:")
for _, s in sounds do
	print("  " .. s)
end
