--!strict
--!optimize 2
-- Player movement — port of WinQuake sv_user.c: SV_ClientThink and the
-- acceleration/friction model, plus V_CalcRoll from view.c which it uses.

local cvarlib = require("../common/cvar")
local mathlib = require("../common/mathlib")
local msg = require("../common/msg")
local defs = require("../progs/defs")
local vmlib = require("../progs/vm")
local qd = require("../quakedef")
local svlib = require("./sv")
local world = require("./world")

local sv_user = {}

local ent = defs.ent

local MAX_FORWARD = 6
local ON_EPSILON = 0.1

-- V_CalcRoll (view.c); cl_rollangle 2.0, cl_rollspeed 200
local function calcRoll(angles: vector, velocity: vector): number
	local _, right = mathlib.angleVectors(angles)
	local side = vector.dot(velocity, right)
	local sign = if side < 0 then -1 else 1
	side = math.abs(side)

	local value = 2.0 -- cl_rollangle
	if side < 200 then -- cl_rollspeed
		side = side * value / 200
	else
		side = value
	end

	return side * sign
end

-- SV_SetIdealPitch
function sv_user.setIdealPitch(svr: svlib.Server, player: vmlib.Edict)
	local w = svr.world

	if bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_ONGROUND) == 0 then
		return
	end

	local origin = vmlib.edVector(player, ent.origin)
	local angleval = vmlib.edVector(player, ent.angles).y * math.pi * 2 / 360
	local sinval = math.sin(angleval)
	local cosval = math.cos(angleval)

	local z: { number } = {}
	for i = 0, MAX_FORWARD - 1 do
		local top = vector.create(
			origin.x + cosval * (i + 3) * 12,
			origin.y + sinval * (i + 3) * 12,
			origin.z + vmlib.edFloat(player, ent.view_ofs + 2)
		)
		local bottom = vector.create(top.x, top.y, top.z - 160)

		local tr = world.move(w, top, vector.zero, vector.zero, bottom, qd.MOVE_NOMONSTERS, player)
		if tr.allsolid then
			return -- looking at a wall, leave ideal the way it was
		end
		if tr.fraction == 1 then
			return -- near a dropoff
		end
		z[i + 1] = top.z + tr.fraction * (bottom.z - top.z)
	end

	local dir, steps = sv_user.idealPitchSteps(z)
	if steps == -1 then
		return -- mixed changes
	end

	if dir == 0 then
		vmlib.edSetFloat(player, ent.idealpitch, 0)
		return
	end
	if steps < 2 then
		return
	end
	vmlib.edSetFloat(player, ent.idealpitch, -dir * cvarlib.value(svr.cvars, "sv_idealpitchscale"))
end

-- the SV_SetIdealPitch step scan; C declares step/dir as int, so each
-- z-delta truncates toward zero before the epsilon/mixed-change tests.
-- Returns dir, steps; steps == -1 signals the mixed-changes bailout.
function sv_user.idealPitchSteps(z: { number }): (number, number)
	local dir = 0
	local steps = 0
	for j = 2, #z do
		local step = mathlib.trunc(z[j] - z[j - 1])
		if step > -ON_EPSILON and step < ON_EPSILON then
			continue
		end
		if dir ~= 0 and (step - dir > ON_EPSILON or step - dir < -ON_EPSILON) then
			return dir, -1 -- mixed changes
		end
		steps += 1
		dir = step
	end
	return dir, steps
end

-- SV_UserFriction
local function userFriction(svr: svlib.Server, player: vmlib.Edict)
	local w = svr.world
	local vel = vmlib.edVector(player, ent.velocity)
	local origin = vmlib.edVector(player, ent.origin)

	local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	if speed == 0 then
		return
	end

	-- if the leading edge is over a dropoff, increase friction
	local startZ = origin.z + vmlib.edVector(player, ent.mins).z
	local start = vector.create(origin.x + vel.x / speed * 16, origin.y + vel.y / speed * 16, startZ)
	local stop = vector.create(start.x, start.y, startZ - 34)

	local trace = world.move(w, start, vector.zero, vector.zero, stop, qd.MOVE_NOMONSTERS, player)

	local friction = cvarlib.value(svr.cvars, "sv_friction")
	if trace.fraction == 1 then
		friction *= cvarlib.value(svr.cvars, "edgefriction")
	end

	-- apply friction
	local stopspeed = cvarlib.value(svr.cvars, "sv_stopspeed")
	local control = if speed < stopspeed then stopspeed else speed
	local newspeed = speed - svr.frametime * control * friction
	if newspeed < 0 then
		newspeed = 0
	end
	newspeed /= speed

	vmlib.edSetVector(player, ent.velocity, vel * newspeed)
end

-- SV_Accelerate
local function accelerate(svr: svlib.Server, player: vmlib.Edict, wishdir: vector, wishspeed: number)
	local vel = vmlib.edVector(player, ent.velocity)
	local currentspeed = vector.dot(vel, wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = cvarlib.value(svr.cvars, "sv_accelerate") * svr.frametime * wishspeed
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	vmlib.edSetVector(player, ent.velocity, vel + wishdir * accelspeed)
end

-- SV_AirAccelerate
local function airAccelerate(svr: svlib.Server, player: vmlib.Edict, wishveloc: vector, wishspeed: number)
	local wishdir, wishspd = mathlib.normalize(wishveloc)
	if wishspd > 30 then
		wishspd = 30
	end
	local vel = vmlib.edVector(player, ent.velocity)
	local currentspeed = vector.dot(vel, wishdir)
	local addspeed = wishspd - currentspeed
	if addspeed <= 0 then
		return
	end
	local accelspeed = cvarlib.value(svr.cvars, "sv_accelerate") * wishspeed * svr.frametime
	if accelspeed > addspeed then
		accelspeed = addspeed
	end
	vmlib.edSetVector(player, ent.velocity, vel + wishdir * accelspeed)
end

-- DropPunchAngle
local function dropPunchAngle(svr: svlib.Server, player: vmlib.Edict)
	local punch = vmlib.edVector(player, ent.punchangle)
	local dir, len = mathlib.normalize(punch)
	len -= 10 * svr.frametime
	if len < 0 then
		len = 0
	end
	vmlib.edSetVector(player, ent.punchangle, dir * len)
end

-- SV_WaterMove
local function waterMove(svr: svlib.Server, player: vmlib.Edict, cmd: svlib.UserCmd)
	-- user intentions
	local forward, right = mathlib.angleVectors(vmlib.edVector(player, ent.v_angle))

	local wishvel = forward * cmd.forwardmove + right * cmd.sidemove

	if cmd.forwardmove == 0 and cmd.sidemove == 0 and cmd.upmove == 0 then
		wishvel = vector.create(wishvel.x, wishvel.y, wishvel.z - 60) -- drift towards bottom
	else
		wishvel = vector.create(wishvel.x, wishvel.y, wishvel.z + cmd.upmove)
	end

	local wishspeed = vector.magnitude(wishvel)
	local maxspeed = cvarlib.value(svr.cvars, "sv_maxspeed")
	if wishspeed > maxspeed then
		wishvel = wishvel * (maxspeed / wishspeed)
		wishspeed = maxspeed
	end
	wishspeed *= 0.7

	-- water friction
	local vel = vmlib.edVector(player, ent.velocity)
	local speed = vector.magnitude(vel)
	local newspeed
	if speed ~= 0 then
		newspeed = speed - svr.frametime * speed * cvarlib.value(svr.cvars, "sv_friction")
		if newspeed < 0 then
			newspeed = 0
		end
		vel = vel * (newspeed / speed)
		vmlib.edSetVector(player, ent.velocity, vel)
	else
		newspeed = 0
	end

	-- water acceleration
	if wishspeed == 0 then
		return
	end

	local addspeed = wishspeed - newspeed
	if addspeed <= 0 then
		return
	end

	local wishdir = mathlib.normalize(wishvel)
	local accelspeed = cvarlib.value(svr.cvars, "sv_accelerate") * wishspeed * svr.frametime
	if accelspeed > addspeed then
		accelspeed = addspeed
	end

	vmlib.edSetVector(player, ent.velocity, vmlib.edVector(player, ent.velocity) + wishdir * accelspeed)
end

-- SV_WaterJump
local function waterJump(svr: svlib.Server, player: vmlib.Edict)
	if svr.time > vmlib.edFloat(player, ent.teleport_time) or vmlib.edFloat(player, ent.waterlevel) == 0 then
		vmlib.edSetFloat(
			player,
			ent.flags,
			bit32.band(vmlib.edFloat(player, ent.flags), bit32.bnot(qd.FL_WATERJUMP))
		)
		vmlib.edSetFloat(player, ent.teleport_time, 0)
	end
	local movedir = vmlib.edVector(player, ent.movedir)
	local vel = vmlib.edVector(player, ent.velocity)
	vmlib.edSetVector(player, ent.velocity, vector.create(movedir.x, movedir.y, vel.z))
end

-- SV_AirMove
local function airMove(svr: svlib.Server, player: vmlib.Edict, cmd: svlib.UserCmd, onground: boolean)
	local forward, right = mathlib.angleVectors(vmlib.edVector(player, ent.angles))

	local fmove = cmd.forwardmove
	local smove = cmd.sidemove

	-- hack to not let you back into teleporter
	if svr.time < vmlib.edFloat(player, ent.teleport_time) and fmove < 0 then
		fmove = 0
	end

	local wishvel = forward * fmove + right * smove

	local movetype = vmlib.edFloat(player, ent.movetype)
	if movetype ~= qd.MOVETYPE_WALK then
		wishvel = vector.create(wishvel.x, wishvel.y, cmd.upmove)
	else
		wishvel = vector.create(wishvel.x, wishvel.y, 0)
	end

	local wishdir, wishspeed = mathlib.normalize(wishvel)
	local maxspeed = cvarlib.value(svr.cvars, "sv_maxspeed")
	if wishspeed > maxspeed then
		wishvel = wishvel * (maxspeed / wishspeed)
		wishspeed = maxspeed
	end

	if movetype == qd.MOVETYPE_NOCLIP then
		-- noclip
		vmlib.edSetVector(player, ent.velocity, wishvel)
	elseif onground then
		userFriction(svr, player)
		accelerate(svr, player, wishdir, wishspeed)
	else
		-- not on ground, so little effect on velocity
		airAccelerate(svr, player, wishvel, wishspeed)
	end
end

-- SV_ClientThink: the move fields specify an intended velocity in pix/sec;
-- the angle fields specify an exact angular motion in degrees
function sv_user.clientThink(svr: svlib.Server, client: svlib.Client)
	local player = client.edict

	if vmlib.edFloat(player, ent.movetype) == qd.MOVETYPE_NONE then
		return
	end

	local onground = bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_ONGROUND) ~= 0

	dropPunchAngle(svr, player)

	-- if dead, behave differently
	if vmlib.edFloat(player, ent.health) <= 0 then
		return
	end

	-- angles: show 1/3 the pitch angle and all the roll angle
	local cmd = client.cmd
	local v_angle = vmlib.edVector(player, ent.v_angle) + vmlib.edVector(player, ent.punchangle)
	local angles = vmlib.edVector(player, ent.angles)
	local roll = calcRoll(angles, vmlib.edVector(player, ent.velocity)) * 4
	if vmlib.edFloat(player, ent.fixangle) == 0 then
		angles = vector.create(-v_angle.x / 3, v_angle.y, roll)
	else
		angles = vector.create(angles.x, angles.y, roll)
	end
	vmlib.edSetVector(player, ent.angles, angles)

	if bit32.band(vmlib.edFloat(player, ent.flags), qd.FL_WATERJUMP) ~= 0 then
		waterJump(svr, player)
		return
	end

	-- walk
	if vmlib.edFloat(player, ent.waterlevel) >= 2 and vmlib.edFloat(player, ent.movetype) ~= qd.MOVETYPE_NOCLIP then
		waterMove(svr, player, cmd)
		return
	end

	airMove(svr, player, cmd, onground)
end

-- SV_ReadClientMove: parse a clc_move payload into the client state
function sv_user.readClientMove(svr: svlib.Server, client: svlib.Client, r: msg.Reader)
	local player = client.edict

	-- ping bookkeeping: the move carries cl.mtime[0] (the last server
	-- message time the client saw); C keeps a NUM_PING_TIMES=16 ring
	local sentTime = msg.readFloat(r)
	local cc = client :: any
	if not cc.ping_times then
		cc.ping_times = table.create(16, 0)
		cc.num_pings = 0
	end
	cc.ping_times[cc.num_pings % 16 + 1] = svr.time - sentTime
	cc.num_pings += 1

	-- read current angles
	local v_angle = vector.create(msg.readAngle(r), msg.readAngle(r), msg.readAngle(r))
	vmlib.edSetVector(player, ent.v_angle, v_angle)

	-- read movement
	client.cmd.forwardmove = msg.readShort(r)
	client.cmd.sidemove = msg.readShort(r)
	client.cmd.upmove = msg.readShort(r)

	-- read buttons
	local bits = msg.readByte(r)
	vmlib.edSetFloat(player, ent.button0, bit32.band(bits, 1))
	vmlib.edSetFloat(player, ent.button2, bit32.rshift(bit32.band(bits, 2), 1))

	local impulse = msg.readByte(r)
	if impulse ~= 0 then
		vmlib.edSetFloat(player, ent.impulse, impulse)
	end
end

return sv_user
