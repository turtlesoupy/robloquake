--!strict
-- verify_crosshair — Studio executor snippets (Client VM) that produced
-- docs/coverage/evidence/nq-crosshair-aim.jpg and its numeric context.
-- The Roblox camera projects through the WINDOW centre (it cannot emulate
-- the C vrect's raised projection centre — see qcoords.vrect), so the
-- SCR_DrawCrosshair '+' must sit at the window centre or shots land below
-- it. Run each PART in Studio Play (NQ boot) via the MCP execute_luau
-- tool against the Client datamodel.

-- PART 1 — glyph centre == projection centre (expect delta (0.0, 0.0)).
-- AbsolutePosition is reported in inset-relative space even on an
-- IgnoreGuiInset gui, so add GetGuiInset() before comparing.
local PART1 = [[
local inset = game:GetService("GuiService"):GetGuiInset()
local plr = game:GetService("Players").LocalPlayer
local ch = plr.PlayerGui.QuakeOverlay.crosshair
local cam = workspace.CurrentCamera
local c = ch.AbsolutePosition + Vector2.new(inset.X, inset.Y) + ch.AbsoluteSize/2
local vp = cam.ViewportSize
return string.format("delta=(%.1f,%.1f)", c.X - vp.X/2, c.Y - vp.Y/2)
]]

-- PART 2 — fire a rocket, track the missile part (the fast mover inside
-- workspace.QuakeEnts), project its final position: expect the screen
-- delta from the viewport centre to stay under ~20px at long range (the
-- residue is the authentic 6qu below-eye spawn line plus mesh-centre
-- offset). Recorded run: dist=673qu delta=(-14.0,18.8).
local PART2 = [[
local RS = game:GetService("RunService")
local cam = workspace.CurrentCamera
local ef = workspace.QuakeEnts
local prev = {}
for _, d in ef:GetDescendants() do
  if d:IsA("BasePart") then prev[d] = d.Position end
end
workspace:SetAttribute("RQ_ForceAttack", true)
task.delay(0.1, function() workspace:SetAttribute("RQ_ForceAttack", false) end)
local lastFast
local t0 = os.clock()
while os.clock() - t0 < 2.5 do
  RS.RenderStepped:Wait()
  for _, d in ef:GetDescendants() do
    if d:IsA("BasePart") then
      local p0, p1 = prev[d], d.Position
      if p0 and (p1 - p0).Magnitude > 1 and (p1 - p0).Magnitude < 20 then lastFast = p1 end
      prev[d] = p1
    end
  end
end
if not lastFast then return "no missile tracked" end
local sp = cam:WorldToViewportPoint(lastFast)
local vp = cam.ViewportSize
return string.format("delta=(%.1f,%.1f)", sp.X - vp.X/2, sp.Y - vp.Y/2)
]]

-- PART 3 — the committed screenshot: fire at a wall ~140qu ahead, then
-- console "pause" ~0.3s after the trigger. BecomeExplosion is a SERVER
-- think chain, so pausing freezes the fireball mid-frame; capture at
-- leisure, then "pause" again to resume. The '+' overlaps the fireball's
-- upper edge (the gap is the 6qu spawn offset, ~29px at that range).
local PART3 = [[
local dbg = workspace.RQDBG_Console
workspace:SetAttribute("RQ_ForceAttack", true)
task.wait(0.1)
workspace:SetAttribute("RQ_ForceAttack", false)
task.wait(0.22)
dbg:Invoke("exec", "pause")
return "frozen — screenshot now, then exec pause again"
]]

print("Studio-only verification; snippets:")
print(PART1)
print(PART2)
print(PART3)
