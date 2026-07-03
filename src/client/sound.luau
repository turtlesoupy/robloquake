--!strict
-- Sound — S_StartSound / S_StaticSound semantics over Roblox Sound
-- instances. Roblox cannot synthesize PCM at runtime, so every pak wav is
-- concatenated into ONE uploaded soundbank asset (tools/build_soundbank.py)
-- and played back as time slices via Sound.PlaybackRegion. The soundmap
-- StringValue in ReplicatedStorage.QuakeClientFS holds the bank asset id
-- and the per-sample regions:
--   { assetId = "rbxassetid://...", rate = 22050,
--     regions = { ["weapons/guncock.wav"] = {s=288.88, l=1.29, ls=0.0} } }
-- (s = start seconds, l = length, ls = loopstart offset from the wav cue
-- chunk, present only for looping samples). Without the map, everything
-- no-ops quietly.

local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local sound = {}

type Region = { s: number, l: number, ls: number? }

export type System = {
	assetId: string,
	regions: { [string]: Region },
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

	local assetId = ""
	local regions: { [string]: Region } = {}
	local assets = ReplicatedStorage:FindFirstChild("QuakeClientFS")
	local mapValue = assets and assets:FindFirstChild("soundmap")
	if mapValue and mapValue:IsA("StringValue") and #mapValue.Value > 2 then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, mapValue.Value)
		if ok and typeof(decoded) == "table" and typeof(decoded.assetId) == "string" then
			assetId = decoded.assetId
			regions = decoded.regions or {}
		end
	end

	local enabled = assetId ~= "" and next(regions) ~= nil
	if not enabled then
		warn("[robloquake] no soundbank — running silent (see tools/build_soundbank.py)")
	else
		-- warm the bank so the first shot isn't late
		task.spawn(function()
			local s = Instance.new("Sound")
			s.SoundId = assetId
			ContentProvider:PreloadAsync({ s })
			s:Destroy()
		end)
	end

	return {
		assetId = assetId,
		regions = regions,
		folder = folder,
		channels = {},
		missing = {},
		enabled = enabled,
	}
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

local function regionFor(sys: System, sample: string): Region?
	local r = sys.regions[sample]
	if not r and not sys.missing[sample] then
		sys.missing[sample] = true
		warn("[robloquake] soundbank has no region for " .. sample)
	end
	return r
end

local function bankSound(sys: System, r: Region, looped: boolean): Sound
	local s = Instance.new("Sound")
	s.SoundId = sys.assetId
	s.PlaybackRegionsEnabled = true
	s.PlaybackRegion = NumberRange.new(r.s, r.s + r.l)
	if looped then
		s.Looped = true
		s.LoopRegion = NumberRange.new(r.s + (r.ls or 0), r.s + r.l)
	end
	s.RollOffMinDistance = 2
	s.RollOffMode = Enum.RollOffMode.Linear
	return s
end

-- S_StartSound
function sound.start(sys: System, entnum: number, channel: number, sample: string, pos: vector, vol: number, atten: number)
	if not sys.enabled then
		return
	end
	local r = regionFor(sys, sample)
	if not r then
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
	local s = bankSound(sys, r, false)
	s.Volume = vol
	s.RollOffMaxDistance = rolloffFor(atten)
	s.Parent = part
	local function cleanup()
		part:Destroy()
		if sys.channels[key] == part then
			sys.channels[key] = nil
		end
	end
	s.Ended:Once(cleanup)
	-- regions can misreport Ended while the asset streams in; make sure
	-- one-shots never linger
	task.delay(r.l + 2, function()
		if part.Parent then
			cleanup()
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
	local r = regionFor(sys, sample)
	if not r then
		return
	end
	local part = emitterAt(sys, pos)
	local s = bankSound(sys, r, true)
	s.Volume = vol / 255
	s.RollOffMaxDistance = rolloffFor(atten / 64)
	s.Parent = part
	s:Play()
end

function sound.clear(sys: System)
	sys.folder:ClearAllChildren()
	table.clear(sys.channels)
end

return sound
