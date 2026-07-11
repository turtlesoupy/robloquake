--!strict
-- STUDIO-RUN test (needs the live Roblox engine — Animator track loading
-- and CreateHumanoidModelFromDescription — so it cannot run under lune
-- like tests/*.luau). Run with Rojo connected and syncing: paste/execute
-- this file's contents in the Studio Edit datamodel (command bar or the
-- Studio MCP execute_luau tool).
--
-- End-to-end over the REAL modules: the server publish-path rig builder
-- (avatarrigs.buildRigFromDescription) feeding the REAL client renderer
-- (avatarrender.create), asserting every movement AnimationTrack comes
-- out playable (Length > 0).
--
-- Why: HumanoidDescription animation properties hold avatar-shop CATALOG
-- asset ids (a Folder container wrapping the playable animation), not
-- animation ids. Animator:LoadAnimation on a container id does NOT error
-- — it returns a track with Length == 0 that silently never poses
-- anything. Vanilla avatars have those properties = 0 and fall back to
-- stock track ids, which is why dev testing passed while prod players
-- with equipped animation packs walked frozen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

-- require CLONES: Studio caches require() per instance, so a re-run after
-- editing module Source would otherwise get the stale cached module
local rigsClone = ServerScriptService:WaitForChild("Server"):WaitForChild("avatarrigs"):Clone()
local renderClone = StarterPlayer:WaitForChild("StarterPlayerScripts")
	:WaitForChild("Client"):WaitForChild("render"):WaitForChild("avatarrender"):Clone()
local avatarrigs = require(rigsClone) :: any
local avatarrender = require(renderClone) :: any

-- "Ninja Animation - Run" catalog item: the id an equipped-pack player's
-- HumanoidDescription actually carries for RunAnimation
local NINJA_RUN_CATALOG = 658830056

local function packDesc(): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	d.RunAnimation = NINJA_RUN_CATALOG
	return d
end

local CASES: { { name: string, uid: number, desc: HumanoidDescription } } = {
	{ name = "vanilla avatar", uid = 900001, desc = Instance.new("HumanoidDescription") },
	{ name = "animation pack avatar", uid = 900002, desc = packDesc() },
}
local STATES = { "idle", "run", "jump", "fall", "swim", "swimidle" }

-- avatarrender.create looks rigs up under ReplicatedStorage.QuakeAvatars
local folder = ReplicatedStorage:FindFirstChild("QuakeAvatars")
local ownsFolder = false
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "QuakeAvatars"
	folder.Parent = ReplicatedStorage
	ownsFolder = true
end
assert(folder)

local failures: { string } = {}
local lines: { string } = {}
local cleanup: { Instance } = { rigsClone, renderClone }

for _, case in CASES do
	local rig = avatarrigs.buildRigFromDescription(case.desc)
	rig.Name = tostring(case.uid)
	rig:PivotTo(CFrame.new(0, -100000, 0))
	rig.Parent = folder
	table.insert(cleanup, rig)

	local ae = avatarrender.create(case.uid, workspace)
	local deadline = os.clock() + 10
	while ae.loading and os.clock() < deadline do
		task.wait(0.1)
	end
	if ae.model then
		table.insert(cleanup, ae.model)
	end
	if not ae.model then
		table.insert(failures, case.name .. ": client rig never loaded")
		continue
	end
	-- track Length populates asynchronously as animation content loads
	deadline = os.clock() + 10
	while os.clock() < deadline do
		local pending = false
		for _, s in STATES do
			local tr = ae.tracks[s]
			if tr and tr.Length == 0 then
				pending = true
			end
		end
		if not pending then
			break
		end
		task.wait(0.25)
	end
	for _, s in STATES do
		local tr = ae.tracks[s]
		local len = if tr then tr.Length else -1
		table.insert(lines, string.format("%s / %-8s Length = %.3f", case.name, s, len))
		if not tr then
			table.insert(failures, case.name .. ": no " .. s .. " track loaded")
		elseif tr.Length == 0 then
			table.insert(failures, case.name .. ": " .. s .. " track is unplayable (Length 0 — catalog container id?)")
		end
	end
	-- the pack rig must have stamped a RESOLVED run id, not the catalog id
	local runAttr = rig:GetAttribute("RunAnim")
	table.insert(lines, string.format("%s RunAnim attr = %s", case.name, tostring(runAttr)))
	if case.desc.RunAnimation ~= 0 and runAttr == case.desc.RunAnimation then
		table.insert(failures, case.name .. ": rig stamped the raw catalog id")
	end
end

for _, inst in cleanup do
	inst:Destroy()
end
if ownsFolder then
	folder:Destroy()
end

if #failures > 0 then
	return "FAIL\n" .. table.concat(failures, "\n") .. "\n\n" .. table.concat(lines, "\n")
end
return "PASS\n" .. table.concat(lines, "\n")
