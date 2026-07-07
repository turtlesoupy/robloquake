--!strict
-- Map-transition mesh-budget gauntlet (evidence:
-- docs/coverage/evidence/nq-e1m1-flicker.txt). Not a lune test: the
-- EditableMesh memory budget only exists inside Roblox Studio, so these
-- chunks run there via the MCP execute_luau tool (or the command bar).
--
-- WHAT IT GUARDS: world rebuilds used to run in the same frame that tore
-- the previous level down. Destroying signals are deferred and several
-- mesh owners (brush templates, RenderEnt alias meshes, the beam pool,
-- the canUseMeshApi probe) leaked outright, so every rebuild after the
-- first starved CreateEditableMesh into silently skipped batches —
-- missing world faces that read as crisp black rectangles (the user's
-- e1m1 "black square"), or in the worst case a world Model with zero
-- parts. The fix releases meshes synchronously (worldmesh.destroyBuild,
-- entrender.destroy of re.em) and defers the rebuild one Heartbeat.
--
-- Procedure:
--  1. Start Play on the NQ boot (default engine). Wait for signon.
--  2. CLIENT datamodel: run the GAUNTLET chunk. It cycles FOUR world
--     rebuilds (demo -> stop -> map e1m1 -> map e1m2 -> map e1m1) and
--     then asserts the render world survived. Takes ~60s.
--  3. Expected result string: "PASS ..." with a world part count >= 50
--     and an animated alcove atlas region. Any "EditableMesh budget
--     exhausted" / "fixed mesh copy failed" console line during the
--     gauntlet is a regression.
--  4. Optional visual: teleport to the user vantage (SERVER chunk below)
--     and screen_capture twice ~0.5s apart — the alcove around
--     q(688,56,80) must flicker with lightstyle 10, never stay black
--     while the ceiling fixture animates.

--------------------------------------------------------------------------
-- GAUNTLET (CLIENT datamodel)
local function gauntlet(): string
	local con = workspace:FindFirstChild("RQDBG_Console") :: BindableFunction?
	local atlas = workspace:FindFirstChild("RQDBG_Atlas") :: BindableFunction?
	if not con or not atlas then
		return "FAIL: RQDBG hooks missing (need the NQ boot in Play mode)"
	end
	con:Invoke("exec", "playdemo demo1")
	task.wait(10)
	con:Invoke("exec", "stopdemo")
	task.wait(1)
	for _, map in { "e1m1", "e1m2", "e1m1" } do
		con:Invoke("exec", "map " .. map)
		task.wait(10)
	end

	local wf = workspace:FindFirstChild("QuakeWorld")
	if not wf then
		return "FAIL: no QuakeWorld folder"
	end
	local parts = 0
	for _, d in wf:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	-- e1m1 alcove wall surf 4810 (lightofs 151584, styles 10,255,255,255):
	-- the exact face family the pre-fix starvation dropped
	local region = atlas:Invoke("region", "151584") :: string
	if parts < 50 then
		return `FAIL: world has {parts} parts after 4 rebuilds (starved build)`
	end
	if not region:find("animated=true") then
		return `FAIL: alcove region unhealthy after 4 rebuilds: {region}`
	end
	return `PASS: world parts={parts}; alcove region {region}`
end
print(gauntlet())

--------------------------------------------------------------------------
-- USER VANTAGE (SERVER datamodel, then capture from the client)
-- game:GetService("ServerStorage"):SetAttribute("RQDBG", true) -- SVDBG_* hooks are gated (audit H9)
-- game:GetService("ServerStorage"):SetAttribute("SVDBG_SetOrigin", Vector3.new(523, 314, 24))
-- CLIENT: workspace:SetAttribute("RQ_ForceYaw", 302.6)
--         workspace:SetAttribute("RQ_ForcePitch", -8)
-- cleanup: set both attributes to nil
