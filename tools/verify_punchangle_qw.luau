--!strict
-- QW DropPunchAngle verification (qw-client manifest row) — a
-- faithfulness-by-absence check. Runs inside Roblox Studio via the MCP
-- execute_luau tool (Client datamodel), QW boot, player armed with the
-- shotgun and shells.
--
-- C truth (QW/client/view.c + cl_parse.c):
--   svc_smallkick sets cl.punchangle = -2 (negative);
--   V_RenderView calls DropPunchAngle() IMMEDIATELY BEFORE V_CalcRefdef;
--   DropPunchAngle does punchangle -= 10*dt then clamps below 0 to 0.
-- Consequence: the negative kick is clamped to zero before the refdef
-- ever reads it — gun kicks DO NOT display in authentic QuakeWorld
-- (the lingering recoil players remember is NetQuake behavior). The
-- port replicates the same order (decay+clamp at the top of the camera
-- block), so the correct measurement is ZERO pitch deflection.
--
-- MEASURED 2026-07-04: 55 heartbeat samples during sustained forced
-- shotgun fire (shells 25 -> 2, muzzleflash + TE_GUNSHOT visible —
-- evidence/qw-fire-muzzleflash.jpg): maxDelta 0, minDelta 0. PASS.
--
-- The chunk (paste into execute_luau, Client):
local RunService = game:GetService("RunService")
local cam = workspace.CurrentCamera
workspace:SetAttribute("RQ_ForcePitch", 0)
task.wait(0.3)
local samples: { number } = {}
local conn = RunService.Heartbeat:Connect(function()
	table.insert(samples, math.deg(math.asin(cam.CFrame.LookVector.Y)))
end)
workspace:SetAttribute("RQ_ForceAttack", true)
task.wait(0.5)
workspace:SetAttribute("RQ_ForceAttack", nil)
task.wait(0.4)
conn:Disconnect()
workspace:SetAttribute("RQ_ForcePitch", nil)
local base = samples[1]
local mx, mn = -100, 100
for _, p in samples do
	mx = math.max(mx, p - base)
	mn = math.min(mn, p - base)
end
return game:GetService("HttpService"):JSONEncode({
	n = #samples,
	maxDelta = mx,
	minDelta = mn,
	pass = math.abs(mx) < 0.3 and math.abs(mn) < 0.3, -- authentic QW: no visible kick
})
