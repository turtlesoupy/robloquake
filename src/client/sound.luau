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
local SoundService = game:GetService("SoundService")

local engine = ReplicatedStorage:WaitForChild("Shared").engine
local qcoords = require(engine.client.qcoords)

local sound = {}

type Region = { s: number, l: number, ls: number? }

type Channel = { part: Part, sound: Sound }

export type System = {
	assetId: string,
	regions: { [string]: Region },
	folder: Folder,
	-- (entnum*8 + channel) -> persistent channel emitter; a new sound on the
	-- same entity/channel restarts it, like the C channel allocator. The
	-- Sound instance is reused so rapid refire (super nailgun) never hits a
	-- fresh instance whose PlaybackRegion hasn't applied yet.
	channels: { [number]: Channel },
	ambients: { { sound: Sound?, vol: number } }?,
	missing: { [string]: boolean },
	enabled: boolean,
	-- every bank Sound joins this group; its Volume is the "volume" cvar
	group: SoundGroup,
}

function sound.new(parent: Instance): System
	local folder = Instance.new("Folder")
	folder.Name = "QuakeSounds"
	folder.Parent = parent

	-- SoundService (not the folder): clear() empties the folder but the
	-- master must survive level changes
	local group = Instance.new("SoundGroup")
	group.Name = "QuakeSoundMaster"
	group.Volume = 1
	group.Parent = SoundService

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
		group = group,
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
	s.SoundGroup = sys.group
	return s
end

-- the "volume" cvar: master gain over every bank sound via the shared
-- SoundGroup (default.cfg's "volume 0.7" lands here at boot, like S_Init)
function sound.setMasterVolume(sys: System, v: number)
	sys.group.Volume = math.clamp(v, 0, 1)
end

function sound.getMasterVolume(sys: System): number
	return sys.group.Volume
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

	if channel ~= 0 then
		-- entity channels persist: restart (override) in place
		local key = entnum * 8 + channel
		local ch = sys.channels[key]
		if not ch then
			local part = emitterAt(sys, pos)
			local snd = bankSound(sys, r, false)
			snd.Parent = part
			ch = { part = part, sound = snd }
			sys.channels[key] = ch
			-- reclaim emitters that have sat silent for a while
			local function gc()
				task.delay(10, function()
					if sys.channels[key] ~= ch then
						return
					end
					if ch.sound.IsPlaying then
						gc()
					else
						sys.channels[key] = nil
						ch.part:Destroy()
					end
				end)
			end
			gc()
		end
		ch.sound:Stop()
		-- diagnostic name (RQ_* family): the persistent channel Sound shows
		-- which sample currently owns the ent/channel slot
		ch.sound.Name = `RQChan_{entnum}_{channel}_{sample:match("([^/]+)%.wav") or sample}`
		ch.part.Position = qcoords.toRoblox(pos)
		ch.sound.PlaybackRegion = NumberRange.new(r.s, r.s + r.l)
		ch.sound.TimePosition = r.s
		ch.sound.Volume = vol
		ch.sound.RollOffMaxDistance = rolloffFor(atten)
		ch.sound:Play()
		return
	end

	-- CHAN_AUTO: fire-and-forget, never overrides
	local part = emitterAt(sys, pos)
	local s = bankSound(sys, r, false)
	s.Volume = vol
	s.RollOffMaxDistance = rolloffFor(atten)
	s.Parent = part
	s.Ended:Once(function()
		part:Destroy()
	end)
	-- regions can misreport Ended while the asset streams in; make sure
	-- one-shots never linger
	task.delay(r.l + 2, function()
		if part.Parent then
			part:Destroy()
		end
	end)
	s:Play()
end

-- S_StaticSound (looping ambients from the signon)
-- S_StopSound: silence a persistent entity channel
function sound.stop(sys: System, entnum: number, channel: number)
	local ch = sys.channels[entnum * 8 + channel]
	if ch and ch.sound then
		ch.sound:Stop()
	end
end

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

-- S_UpdateAmbientSounds: the water/sky ambient loops whose volumes come
-- from the ambient levels stored in the listener's BSP leaf, faded at
-- ambient_fade (100/sec) toward ambient_level (0.3) * leaf level
local AMBIENT_SAMPLES = { "ambience/water1.wav", "ambience/wind2.wav" }

function sound.updateAmbients(sys: System, leafAmbient: { number }?, dt: number)
	if (sys :: any).ambientsOff then
		leafAmbient = nil -- S_AmbientOff: ambients fade to silence
	end
	if not sys.enabled then
		return
	end
	local amb = sys.ambients
	if not amb then
		amb = {}
		for i = 1, #AMBIENT_SAMPLES do
			local r = sys.regions[AMBIENT_SAMPLES[i]]
			local snd: Sound? = nil
			if r then
				snd = bankSound(sys, r, true)
				snd.Name = "RQAmbient_" .. AMBIENT_SAMPLES[i]:match("([^/]+)%.wav") :: string
				snd.Volume = 0
				snd.Parent = sys.folder -- no Part: unspatialized, like channels 0-1
				snd:Play()
			end
			amb[i] = { sound = snd, vol = 0 }
		end
		sys.ambients = amb
	end
	for i, a in amb do
		if a.sound then
			local target = 0
			if leafAmbient and leafAmbient[i] then
				target = 0.3 * leafAmbient[i] -- ambient_level.value
				if target < 8 then
					target = 0
				end
			end
			if a.vol < target then
				a.vol = math.min(a.vol + dt * 100, target) -- ambient_fade.value
			elseif a.vol > target then
				a.vol = math.max(a.vol - dt * 100, target)
			end
			a.sound.Volume = a.vol / 255
		end
	end
end

-- S_LocalSound: 2D UI sound (menu beeps, talk.wav) — no spatialization,
-- full volume, no entity/channel override
function sound.localSound(sys: System, sample: string, vol: number?): boolean
	local r = regionFor(sys, sample)
	if not r then
		return false
	end
	sound.start(sys, -9999, 0, sample, vector.zero, vol or 1, 0) -- atten 0 = everywhere
	return true
end

-- S_SoundList: every sample in the soundmap with its bank region length
-- (the byte size of the C report has no counterpart — regions replace
-- files); returns the text so consoles/tests can consume it
function sound.soundList(sys: System): string
	local names = {}
	for name in sys.regions do
		table.insert(names, name)
	end
	table.sort(names)
	local out = {}
	for _, name in names do
		local r = sys.regions[name]
		table.insert(out, ("%6.2fs %s\n"):format((r :: any).l or 0, name))
	end
	table.insert(out, `{#names} sounds\n`)
	return table.concat(out)
end

-- S_AmbientOff / S_AmbientOn (snd_ambient gate read by updateAmbients)
function sound.setAmbientsEnabled(sys: System, on: boolean)
	(sys :: any).ambientsOff = not on
end

function sound.clear(sys: System)
	sys.folder:ClearAllChildren()
	table.clear(sys.channels)
	sys.ambients = nil
end

return sound
