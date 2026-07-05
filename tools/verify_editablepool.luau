--!strict
-- verify_editablepool — Studio executor snippets (Client VM) for the
-- session-cumulative editable-asset pool exhaustion investigation
-- ("black textures" playtest reports).
--
-- ESTABLISHED (2026-07-04 sessions):
--   * Objects render black with HEALTHY CPU pixels (ReadPixelsBuffer
--     returns correct art) and healthy properties; whole templates go
--     black by CREATION ORDER (all clones of one late-built b_*.bsp).
--   * LIVE usage is NOT the trigger: black objects on screen with only
--     87 live EditableImages / 81 EditableMeshes (47k verts, 6.4 MB).
--   * Yet the pool is objectively exhausted at that moment: PART 1's
--     dynamic-EM canary is REFUSED (nil) while small EI creation
--     still succeeds. Fresh play sessions start clean.
--   * Hypothesis: the platform's editable memory budget leaks or
--     fragments across a session; teardown/rebuild churn (changelevel)
--     burns it. Late creations then fail to BIND (render black) long
--     before they fail to CREATE.
--
-- PART 1 — canary: can the pool satisfy allocations right now?
local PART1 = [[
local AssetService = game:GetService("AssetService")
local dyn = AssetService:CreateEditableMesh() -- reserves the 60k-vert max
local dynOk = dyn ~= nil
if dyn then dyn:Destroy() end
local ok, img = pcall(function()
  return AssetService:CreateEditableImage({ Size = Vector2.new(1024, 1024) })
end)
local imgOk = ok and img ~= nil
if imgOk then img:Destroy() end
return "dynamic EM: " .. (dynOk and "OK" or "REFUSED")
  .. " | 1024^2 EI: " .. (imgOk and "OK" or "REFUSED")
]]

-- PART 2 — live census: what is actually alive and referenced?
local PART2 = [[
local ems, imgs = {}, {}
for _, d in workspace:GetDescendants() do
  if d:IsA("MeshPart") then
    local mc = d.MeshContent
    if mc and mc.Object and mc.Object:IsA("EditableMesh") then ems[mc.Object] = true end
    local tc = d.TextureContent
    if tc and tc.Object and tc.Object:IsA("EditableImage") then imgs[tc.Object] = true end
  end
end
local plr = game:GetService("Players").LocalPlayer
for _, d in plr.PlayerGui:GetDescendants() do
  if d:IsA("ImageLabel") then
    local ic = d.ImageContent
    if ic and ic.Object and ic.Object:IsA("EditableImage") then imgs[ic.Object] = true end
  end
end
local ne, verts = 0, 0
for em in ems do ne += 1; verts += #em:GetVertices() end
local ni, bytes = 0, 0
for img in imgs do ni += 1; bytes += img.Size.X * img.Size.Y * 4 end
return string.format("%d EMs (%d verts) | %d EIs (%.1f MB)", ne, verts, ni, bytes / 1e6)
]]

-- PART 3 — background monitor: stamps workspace attributes every 5s so a
-- playtest report ("that crate is black!") can be correlated with the
-- pool state at that instant. Survives across execute_luau invocations.
local PART3 = [[
local AssetService = game:GetService("AssetService")
local plr = game:GetService("Players").LocalPlayer
task.spawn(function()
  while true do
    local imgs = {}
    pcall(function()
      for _, d in workspace:GetDescendants() do
        if d:IsA("MeshPart") then
          local tc = d.TextureContent
          if tc and tc.Object and tc.Object:IsA("EditableImage") then imgs[tc.Object] = true end
        end
      end
    end)
    local n = 0
    for _ in imgs do n += 1 end
    local dyn = AssetService:CreateEditableMesh()
    workspace:SetAttribute("RQDBG_EICount", n)
    workspace:SetAttribute("RQDBG_PoolCanary", dyn ~= nil)
    workspace:SetAttribute("RQDBG_EICountAt", os.clock())
    if dyn then dyn:Destroy() end
    task.wait(5)
  end
end)
return "monitor running"
]]

-- CONTROLLED REPRO PROTOCOL (each run: fresh Play session):
--   A. boot DIRECTLY into e1m1 (no changelevel), play through, watch
--      RQDBG_PoolCanary — expect it to stay true longer than:
--   B. boot start, "map e1m1", play through — the extra build/teardown
--      churn should flip the canary earlier if churn is the driver.
--   Note the canary state + EI count the moment anything renders black.

print("Studio-only verification; snippets:")
print(PART1)
print(PART2)
print(PART3)
