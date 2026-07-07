--!strict
-- Client asset bundle: publishes only what the renderer needs (gfx, the
-- precached models/sprites, config scripts, soundmap) into
-- ReplicatedStorage.QuakeClientFS instead of replicating whole paks.
-- Shared by the NetQuake and QuakeWorld server boots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local base64 = require(Shared.engine.common.base64)
local vfs = require(Shared.engine.common.vfs)

local clientbundle = {}

export type Bundle = {
	clientFS: Folder,
	publishFile: (path: string) -> (),
	publishAll: (svr: any) -> (),
}

function clientbundle.new(
	fsys: vfs.Vfs,
	gameDir: string,
	gameFolder: Instance,
	modDir: string?,
	modFolder: Instance?
): Bundle
	local clientFS = Instance.new("Folder")
	clientFS.Name = "QuakeClientFS"
	clientFS:SetAttribute("game", gameDir)
	if modDir then
		clientFS:SetAttribute("gamedir", modDir)
	end
	-- mild mode (content softening, render-only; see client/render/
	-- mildmode.luau): a product-layer default like roblox_avatars —
	-- ON when absent, explicit false = the original presentation.
	-- Mirrored before the folder replicates so clients read it at boot.
	local assets = gameFolder.Parent
	if assets then
		clientFS:SetAttribute("mildmode", assets:GetAttribute("mildmode") ~= false)
	end
	clientFS.Parent = ReplicatedStorage

	local publishedFiles: { [string]: boolean } = {}
	local publishCount = 0

	local function publishFile(path: string)
		if publishedFiles[path] then
			return
		end
		publishedFiles[path] = true
		local fbuf = vfs.loadFile(fsys, path)
		if not fbuf then
			return
		end
		local b64 = base64.encode(fbuf)
		local fileFolder = Instance.new("Folder")
		fileFolder.Name = path
		local n = 0
		for i = 1, #b64, 147000 do
			n += 1
			local sv = Instance.new("StringValue")
			sv.Name = string.format("%04d", n)
			sv.Value = b64:sub(i, i + 146999)
			sv.Parent = fileFolder
		end
		fileFolder:SetAttribute("chunks", n)
		fileFolder:SetAttribute("len", buffer.len(fbuf))
		fileFolder.Parent = clientFS
		publishCount += 1
		if publishCount % 24 == 0 then
			task.wait()
		end
	end

	local function publishAll(svr: any)
		publishFile("gfx.wad")
		-- config scripts for the client's exec command
		publishFile("default.cfg")
		publishFile("quake.rc")
		publishFile("autoexec.cfg")
		publishFile("config.cfg")
		for _, sp in fsys.searchpaths do
			local pack = sp.pack
			if pack then
				for _, entry in pack.entries do
					if entry.name:sub(1, 4) == "gfx/" then
						publishFile(entry.name)
					end
				end
			end
		end
		for i = 2, #svr.model_precache do
			local name = svr.model_precache[i]
			if name:sub(1, 1) ~= "*" then
				publishFile(name)
			end
		end
		-- soundmap (bank asset id + regions) is a StringValue, mirrored as-is;
		-- a mod gamedir's bank (base + mod sounds) overrides the base game's
		local assets = gameFolder.Parent
		local soundmap = (modFolder and modFolder:FindFirstChild("soundmap"))
			or gameFolder:FindFirstChild("soundmap")
			or (assets and assets:FindFirstChild("soundmap"))
		if soundmap and not clientFS:FindFirstChild("soundmap") then
			soundmap:Clone().Parent = clientFS
		end
		clientFS:SetAttribute("ready", true)
		print(`[robloquake] client bundle: {publishCount} files published`)
	end

	return {
		clientFS = clientFS,
		publishFile = publishFile,
		publishAll = publishAll,
	}
end

return clientbundle
