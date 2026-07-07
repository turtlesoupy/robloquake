--!strict
-- Visual anchor capture procedure (scenario rows S3/S4 in
-- docs/coverage/README.md). Not a lune test: these chunks run inside
-- Roblox Studio via the MCP execute_luau tool (or the command bar),
-- staging a DETERMINISTIC vantage so screenshots are comparable across
-- commits. The captured image is committed under docs/coverage/evidence/
-- with a sidecar .txt recording engine, map, viewsize, and commit.
--
-- Anchor definitions (fixed forever — new anchors get new names):
--   S3  nq-e1m1-start : engine=nq  map=e1m1 pos(480,-352,88) yaw 90 pitch 0
--   S4  qw-dm3-stairs : engine=qw  map=dm3  pos(-64,480,44)  yaw 90 pitch 0
--   viewsize 100 (default sbar), fov 90 (default), game id1 (local dev)
--
-- Procedure:
--  1. EDIT mode: set ServerStorage.QuakeAssets attributes
--       engine   = nil for S3 / "qw" for S4
--       startmap = "e1m1" for S3 / "dm3" for S4
--  2. Start Play. Wait for signon (workspace RQ_Signon == 4 on NQ,
--     QW_State == "active" on QW).
--  3. SERVER datamodel: run the SERVER STAGE chunk below (teleports the
--     player through the stuck-probing debug hook).
--  4. CLIENT datamodel: run the CLIENT STAGE chunk (locks view angles
--     through the real input path via the RQ_Force* harness hooks).
--  5. Wait ~1s for the wire + camera to settle, then screen_capture.
--  6. CLIENT datamodel: run the CLEANUP chunk. Stop Play.
--  7. Commit the image as docs/coverage/evidence/<anchor>.png with
--     <anchor>.txt: engine, map, viewsize, fov, position, commit hash.

local ANCHORS = {
	["nq-e1m1-start"] = { pos = Vector3.new(480, -352, 88), yaw = 90, pitch = 0 },
	["qw-dm3-stairs"] = { pos = Vector3.new(-64, 480, 44), yaw = 90, pitch = 0 },
}

-- ==== SERVER STAGE (run in the Server datamodel; edit the anchor name)
local function serverStage(anchor: string)
	game:GetService("ServerStorage"):SetAttribute("RQDBG", true) -- SVDBG_* hooks are gated (audit H9)
	game:GetService("ServerStorage"):SetAttribute("SVDBG_SetOrigin", ANCHORS[anchor].pos)
end

-- ==== CLIENT STAGE (run in the Client datamodel)
local function clientStage(anchor: string)
	local a = ANCHORS[anchor]
	workspace:SetAttribute("RQ_ForceYaw", a.yaw)
	workspace:SetAttribute("RQ_ForcePitch", a.pitch)
end

-- ==== CLEANUP (run in the Client datamodel after the capture)
local function cleanup()
	workspace:SetAttribute("RQ_ForceYaw", nil)
	workspace:SetAttribute("RQ_ForcePitch", nil)
end

return { anchors = ANCHORS, serverStage = serverStage, clientStage = clientStage, cleanup = cleanup }
