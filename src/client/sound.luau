--!strict
-- Sound — S_StartSound / S_StaticSound semantics over Roblox Sound
-- instances. Roblox cannot synthesize PCM at runtime, so samples must be
-- uploaded as audio assets (tools/upload_sounds.py) and mapped by name in
-- ReplicatedStorage.QuakeClientFS.soundmap (a StringValue of JSON
-- { ["weapons/guncock.wav"] = "rbxassetid://..." }). Without the map,
-- everything no-ops quietly.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local sound = {}

export type System = {
	map: { [string]: string },
	folder: Folder,
	-- (entnum*8 + channel) -> playing sound part; new sounds on the same
	-- entity/channel override, like the C channel allocator
	channels: { [number]: Part },
	missing: { [string]: boolean },
	enabled: boolean,
}

function sound.new(parent: Instance): System
	local folder = Instance.new("Folder")
	folder.Name = "QuakeSounds"
	folder.Parent = parent

	local map: { [string]: string } = {}
	local assets = ReplicatedStorage:FindFirstChild("QuakeClientFS")
	local mapValue = assets and assets:FindFirstChild("soundmap")
	if mapValue and mapValue:IsA("StringValue") and #mapValue.Value > 2 then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, mapValue.Value)
		if ok then
			map = decoded
		end
	end

	local enabled = next(map) ~= nil
	if not enabled then
		warn("[robloquake] no soundmap found — running silent (see tools/upload_sounds.py)")
	end

	return { map = map, folder = folder, channels = {}, missing = {}, enabled = enabled }
end

local function emitterAt(sys: System, pos: vector): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Position = qcoords.toRoblox(pos)
	part.Parent = sys.folder
	return part
end

-- attenuation → audible radius: quake sounds fade to nothing at
-- ~1000/atten units (sound_nominal_clip_dist)
local function rolloffFor(atten: number): number
	if atten <= 0 then
		return 100000
	end
	return 1000 / atten * qcoords.SCALE
end

-- S_StartSound
function sound.start(sys: System, entnum: number, channel: number, sample: string, pos: vector, vol: number, atten: number)
	if not sys.enabled then
		return
	end
	local assetId = sys.map[sample]
	if not assetId then
		if not sys.missing[sample] then
			sys.missing[sample] = true
			warn("[robloquake] no audio asset for " .. sample)
		end
		return
	end

	-- override anything already running on this entity/channel pair
	local key = entnum * 8 + channel
	local old = sys.channels[key]
	if old then
		old:Destroy()
		sys.channels[key] = nil
	end

	local part = emitterAt(sys, pos)
	local s = Instance.new("Sound")
	s.SoundId = assetId
	s.Volume = vol
	s.RollOffMaxDistance = rolloffFor(atten)
	s.RollOffMinDistance = 2
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Parent = part
	s.Ended:Once(function()
		part:Destroy()
		if sys.channels[key] == part then
			sys.channels[key] = nil
		end
	end)
	s:Play()
	if channel ~= 0 then -- CHAN_AUTO sounds never override
		sys.channels[key] = part
	end
end

-- S_StaticSound (looping ambients from the signon)
function sound.static(sys: System, pos: vector, sample: string, vol: number, atten: number)
	if not sys.enabled then
		return
	end
	local assetId = sys.map[sample]
	if not assetId then
		return
	end
	local part = emitterAt(sys, pos)
	local s = Instance.new("Sound")
	s.SoundId = assetId
	s.Volume = vol / 255
	s.RollOffMaxDistance = rolloffFor(atten / 64)
	s.RollOffMinDistance = 2
	s.RollOffMode = Enum.RollOffMode.Linear
	s.Looped = true
	s.Parent = part
	s:Play()
end

function sound.clear(sys: System)
	sys.folder:ClearAllChildren()
	table.clear(sys.channels)
end

return sound
