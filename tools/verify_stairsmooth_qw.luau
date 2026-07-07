--!strict
-- QW V_CalcRefdef stair-smoothing verification (qw-client manifest row).
-- Runs inside Roblox Studio via the MCP execute_luau tool (Client
-- datamodel) with the QW boot on dm3 (QuakeAssets attrs engine="qw",
-- startmap="dm3").
--
-- Procedure:
--  1. SERVER: set ServerStorage RQDBG = true (SVDBG_* hooks are gated,
--     audit H9), then ServerStorage SVDBG_SetOrigin = Vector3.new(-64, 470, 44)
--     (bottom of the dm3 staircase at x=-64, risers 56/72/88/104).
--  2. CLIENT: run this chunk. It locks yaw 90 (straight up the stairs),
--     forces forwardmove 400 through the real input path, samples the
--     camera and predicted player z every RenderStepped for ~3 seconds,
--     then reports:
--       simMaxStep — the largest per-frame jump of the PLAYER z
--                    (expected ~riser-sized while climbing), and
--       camMaxStep — the largest per-frame rise of the CAMERA z
--                    (expected <= 80 u/s * frame dt + slack: the oldz
--                    glide; without smoothing it equals simMaxStep).
--     PASS invariant (matches C, including the 12-unit cap): the camera
--     NEVER replicates a riser instantaneously — camMaxStep stays under
--     the 12-unit cap catch-up (<= 13 with bob slack) and strictly below
--     simMaxStep. Consecutive risers at run speed legitimately outpace
--     the 80 u/s glide, so the cap produces jumps up to ~12 in C too;
--     "no jump above the cap" is the faithful bound, not "80*dt only".
--
--     MEASURED 2026-07-04 (commit at time of run): 181 heartbeat
--     samples over 3s, climbed 80 units, simMaxStep 14.6 (risers),
--     camMaxStep 10.04 — smoothing active and C-shaped. Without the
--     smoothing port, camMaxStep equals the riser (16).
--
-- The chunk (paste into execute_luau, Client):
local RunService = game:GetService("RunService")
local cam = workspace.CurrentCamera
local SCALE = 0.125 -- qcoords.SCALE: roblox studs -> quake units is /SCALE

workspace:SetAttribute("RQDBG_QWDiag", true) -- enable the QW_* diagnostics
workspace:SetAttribute("RQ_ForceYaw", 90)
workspace:SetAttribute("RQ_ForcePitch", 0)
task.wait(0.3)
local samples: { { cam: number, sim: number } } = {}
local conn = RunService.Heartbeat:Connect(function()
	local sim = workspace:GetAttribute("QW_SimOrg")
	if typeof(sim) == "Vector3" then
		table.insert(samples, { cam = cam.CFrame.Position.Y / SCALE, sim = sim.Z })
	end
end)
workspace:SetAttribute("RQ_ForceForward", 400)
task.wait(3)
workspace:SetAttribute("RQ_ForceForward", nil)
conn:Disconnect()
workspace:SetAttribute("RQ_ForceYaw", nil)
workspace:SetAttribute("RQ_ForcePitch", nil)

local camMaxStep, simMaxStep = 0, 0
for i = 2, #samples do
	camMaxStep = math.max(camMaxStep, samples[i].cam - samples[i - 1].cam)
	simMaxStep = math.max(simMaxStep, samples[i].sim - samples[i - 1].sim)
end
local climbed = #samples > 0 and (samples[#samples].sim - samples[1].sim) or 0
return game:GetService("HttpService"):JSONEncode({
	samples = #samples,
	camMaxStep = camMaxStep,
	simMaxStep = simMaxStep,
	climbed = climbed,
	pass = camMaxStep <= 13 and camMaxStep < simMaxStep - 2 and simMaxStep >= 14 and climbed > 60,
})
