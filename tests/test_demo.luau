--!strict
-- Demo record/playback round-trip (cl_demo.c): record a loopback
-- session's wire stream in the exact .dem block format init.client
-- writes ([i32 len][f32 pitch][f32 yaw][f32 roll][payload], forced
-- "-1\n" track line), then play it back through a FRESH client with
-- the same reader loop init.client's demoFrame uses, and assert the
-- replayed view entity actually moves through the recorded run.
local t = require("./testutil")
local cllib = require("../src/shared/engine/client/cl")
local defs = require("../src/shared/engine/progs/defs")
local vmlib = require("../src/shared/engine/progs/vm")
local host = require("../src/shared/engine/server/host")

local ent = defs.ent

local fsys = t.gameFs()
local svr = host.newGame(fsys, 4)
svr.print = function(_s: string) end
host.spawnServer(svr, "e1m1")

--------------------------------------------------------------------------
-- record: every buffer the server sends is a demo block, like the
-- init.client tap on the inbound remotes
local c = cllib.new("Ranger", 0)
c.print = function(_s: string) end
local demo: { string } = { "-1\n" }
local recording = true
local function tap(d: buffer)
	if recording then
		local hdr = buffer.create(16)
		buffer.writei32(hdr, 0, buffer.len(d))
		buffer.writef32(hdr, 4, 0)
		buffer.writef32(hdr, 8, 90)
		buffer.writef32(hdr, 12, 0)
		table.insert(demo, buffer.tostring(hdr))
		table.insert(demo, buffer.tostring(d))
	end
	cllib.parseServerMessage(c, d)
	return true
end
local sc = svr.clients[1]
sc.sendUnreliable = tap
sc.sendReliable = tap
host.connectClient(svr, 1)

local function pump()
	local rel = cllib.takeReliable(c)
	if rel then
		table.insert(sc.inbox, rel)
	end
	host.frame(svr, 0.05)
end
for _ = 1, 8 do
	pump()
end
t.eq(c.signon, cllib.SIGNONS, "recording client signed on")

-- run forward for 2 seconds so the demo contains real motion
local startOrg = vmlib.edVector(svr.clients[1].edict, ent.origin)
for _ = 1, 40 do
	local move = cllib.buildMove(c, 200, 0, 0, false, false, 0)
	if move then
		table.insert(sc.inbox, move)
	end
	pump()
end
local endOrg = vmlib.edVector(svr.clients[1].edict, ent.origin)
t.check(vector.magnitude(endOrg - startOrg) > 100, `recorded run moved ({vector.magnitude(endOrg - startOrg)})`)
recording = false

local blob = buffer.fromstring(table.concat(demo))
t.check(buffer.len(blob) > 5000, `demo blob has content ({buffer.len(blob)} bytes)`)

--------------------------------------------------------------------------
-- playback: fresh client, the demoFrame reader loop from init.client
local pc = cllib.new("Viewer", 0)
pc.print = function(_s: string) end
local pos = 0
local n = buffer.len(blob)
while pos < n and buffer.readu8(blob, pos) ~= 10 do
	pos += 1
end
pos += 1

local demoTime = 0
local maxViewMove = 0
local lastView: vector? = nil
local parseErrors = 0
local blocksFed = 0
-- simulate 6 seconds of playback at 60Hz with the exact pacing rule
for _ = 1, 360 do
	demoTime += 1 / 60
	pc.time = demoTime
	while true do
		if pc.signon == cllib.SIGNONS and pc.time <= pc.mtime0 then
			break
		end
		if pos + 16 > n then
			break
		end
		local msglen = buffer.readi32(blob, pos)
		pos += 16
		if msglen < 0 or pos + msglen > n then
			break
		end
		local block = buffer.create(msglen)
		buffer.copy(block, 0, blob, pos, msglen)
		pos += msglen
		local ok = pcall(cllib.parseServerMessage, pc, block)
		cllib.takeReliable(pc)
		if not ok then
			parseErrors += 1
			break
		end
		blocksFed += 1
	end
	-- CL_RelinkEntities runs each frame in the render loop
	if pc.signon == cllib.SIGNONS then
		cllib.relinkEntities(pc, function()
			return 0
		end)
		local ve = pc.entities[pc.viewentity]
		if ve then
			if lastView then
				maxViewMove = math.max(maxViewMove, vector.magnitude(ve.origin - (lastView :: vector)))
			end
			lastView = ve.origin
		end
	end
	if pos + 16 > n then
		break
	end
end

t.eq(parseErrors, 0, "no parse errors during playback")
t.check(blocksFed > 40, `blocks fed ({blocksFed})`)
t.eq(pc.signon, cllib.SIGNONS, "playback client reached full signon from the recorded stream")
local pcOrg = pc.entities[pc.viewentity] and pc.entities[pc.viewentity].origin or vector.zero
local totalMove = vector.magnitude(pcOrg - startOrg)
t.check(totalMove > 100, `playback view entity replayed the run ({string.format("%.1f", totalMove)} units from spawn)`)

--------------------------------------------------------------------------
-- playback REUSING the live client (the Studio path: playdemo resets
-- signon on the same object; svc_serverinfo must clear state cleanly)
c.signon = 0
c.time = 999 -- stale live-session clock; svc_time must re-anchor it
pos = 0
while pos < n and buffer.readu8(blob, pos) ~= 10 do
	pos += 1
end
pos += 1
demoTime = 0
local reuseErrors = 0
local reuseFed = 0
for _ = 1, 360 do
	demoTime += 1 / 60
	-- host-style clock: advance from wherever the client clock is
	c.time += 1 / 60
	while true do
		if c.signon == cllib.SIGNONS and c.time <= c.mtime0 then
			break
		end
		if pos + 16 > n then
			break
		end
		local msglen = buffer.readi32(blob, pos)
		pos += 16
		if msglen < 0 or pos + msglen > n then
			break
		end
		local block = buffer.create(msglen)
		buffer.copy(block, 0, blob, pos, msglen)
		pos += msglen
		local ok = pcall(cllib.parseServerMessage, c, block)
		cllib.takeReliable(c)
		if not ok then
			reuseErrors += 1
			break
		end
		reuseFed += 1
	end
	if c.signon == cllib.SIGNONS then
		cllib.relinkEntities(c, function()
			return 0
		end)
	end
	if pos + 16 > n then
		break
	end
end
t.eq(reuseErrors, 0, "no parse errors on client reuse")
t.eq(c.signon, cllib.SIGNONS, "reused client re-signed on from the demo")
local reOrg = c.entities[c.viewentity] and c.entities[c.viewentity].origin or vector.zero
t.check(vector.magnitude(reOrg - startOrg) > 100, `reused-client playback replayed the run ({string.format("%.1f", vector.magnitude(reOrg - startOrg))} units)`)

t.finish("test_demo")
