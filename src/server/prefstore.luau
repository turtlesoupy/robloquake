--!strict
-- Prefs store (PRODUCT layer, NOT engine): per-player persisted client
-- preferences — the pause menu's settings sliders (look speed, invert
-- mouse, always run, volume) and weapon skin picks. The client fetches
-- its prefs once at boot (Prefs RemoteFunction) and pushes a full
-- sanitized snapshot after changes (PrefsPush RemoteEvent); the server
-- writes the document whole — last write wins, which is safe because a
-- player is only ever in one server at a time. Follows statstore.luau's
-- persistence conventions: disabled flag on the no-API-access error
-- class, throttled writes, flush on leave and BindToClose.
--
-- REMOVAL: delete this file, its require in both server boots, and
-- src/client/prefs.luau (pass the raw settings/setWeaponSkin hooks
-- straight to the menus again).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PREFS_STORE = "rq-prefs-1"
local PREFS_VERSION = 1
local WRITE_INTERVAL = 30 -- min seconds between DataStore writes per player
local SWEEP_INTERVAL = 10 -- how often dirty entries are checked for writing
local LOAD_TIMEOUT = 10 -- secs the boot fetch waits on a slow GetAsync
local MAX_SKINS = 16 -- viewmodel count is 8; headroom, not a quota

export type Prefs = {
	v: number,
	settings: { [string]: any }, -- sensitivity/invertMouse/alwaysRun/volume
	skins: { [string]: string }, -- viewmodel name -> recipe spec
}

local function sanitizeSettings(raw: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(raw) ~= "table" then
		return out
	end
	if type(raw.sensitivity) == "number" then
		out.sensitivity = math.clamp(raw.sensitivity, 1, 11)
	end
	if type(raw.invertMouse) == "boolean" then
		out.invertMouse = raw.invertMouse
	end
	if type(raw.alwaysRun) == "boolean" then
		out.alwaysRun = raw.alwaysRun
	end
	if type(raw.volume) == "number" then
		out.volume = math.clamp(raw.volume, 0, 1)
	end
	if type(raw.topcolor) == "number" then
		out.topcolor = math.clamp(math.floor(raw.topcolor), 0, 13)
	end
	if type(raw.bottomcolor) == "number" then
		out.bottomcolor = math.clamp(math.floor(raw.bottomcolor), 0, 13)
	end
	return out
end

-- shape check only: keys must look like viewmodel paths and specs like
-- skinforge recipes ("kind:seed"); the client validates specs against
-- its actual generator registry when it applies them
local function sanitizeSkins(raw: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(raw) ~= "table" then
		return out
	end
	local n = 0
	for mdl, spec in raw do
		if n >= MAX_SKINS then
			break
		end
		if
			type(mdl) == "string"
			and type(spec) == "string"
			and #spec <= 32
			and mdl:match("^progs/v_[%w_]+%.mdl$") ~= nil
			and spec:match("^%a+:?%d*$") ~= nil
		then
			out[mdl] = spec
			n += 1
		end
	end
	return out
end

-- isKindOwned: the shop economy's equip gate (statstore.isOwned) — a pushed
-- skin whose kind the player doesn't own is dropped instead of persisted or
-- replicated. nil (unwired boot) keeps the old trust-the-shape behavior.
return function(net: Instance, isKindOwned: ((player: Player, kind: string) -> boolean)?)
	local disabled = false -- flips on when DataStores are unreachable (Studio)

	local function noteWriteError(err: any)
		local s = tostring(err):lower()
		if s:find("access") or s:find("publish") then
			if not disabled then
				disabled = true
				warn(`[prefs] DataStores unavailable — prefs run in-memory only ({err})`)
			end
		else
			warn(`[prefs] write failed (will retry): {err}`)
		end
	end

	local store: DataStore? = nil
	if RunService:IsRunning() then
		local ok, ds = pcall(function()
			return DataStoreService:GetDataStore(PREFS_STORE)
		end)
		if ok then
			store = ds
		else
			noteWriteError(ds)
		end
	end

	-- skin picks replicate to every client as a JSON attribute so other
	-- players' render layers can forge this player's held-gun skin
	-- (avatarlayer reads RQWeaponSkins; specs are already sanitized here)
	local function publishSkins(player: Player, skins: { [string]: string })
		player:SetAttribute("RQWeaponSkins", if next(skins) then HttpService:JSONEncode(skins) else nil)
	end

	type Entry = {
		userId: number,
		prefs: Prefs,
		loaded: boolean,
		dirty: boolean,
		lastWrite: number,
	}
	local entries: { [Player]: Entry } = {}

	local function load(player: Player)
		local e: Entry = {
			userId = player.UserId,
			prefs = { v = PREFS_VERSION, settings = {}, skins = {} },
			loaded = false,
			dirty = false,
			lastWrite = -math.huge,
		}
		entries[player] = e
		if store and not disabled then
			local ok, saved = pcall(function()
				return (store :: DataStore):GetAsync("u" .. e.userId)
			end)
			if ok and type(saved) == "table" then
				e.prefs.settings = sanitizeSettings((saved :: any).settings)
				e.prefs.skins = sanitizeSkins((saved :: any).skins)
			elseif not ok then
				noteWriteError(saved)
			end
		end
		e.loaded = true
		if player.Parent then
			publishSkins(player, e.prefs.skins)
		end
	end

	local function write(e: Entry)
		if not e.dirty or not store or disabled then
			return
		end
		e.dirty = false
		e.lastWrite = os.clock()
		local ok, err = pcall(function()
			(store :: DataStore):SetAsync("u" .. e.userId, e.prefs)
		end)
		if not ok then
			e.dirty = true
			noteWriteError(err)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local e = entries[player]
		entries[player] = nil
		if e then
			task.spawn(write, e)
		end
	end)

	game:BindToClose(function()
		for _, e in entries do
			write(e)
		end
	end)

	-- throttled autosave sweep (a push marks dirty; the next sweep past
	-- WRITE_INTERVAL writes it, so slider drags never burst the API)
	task.spawn(function()
		while true do
			task.wait(SWEEP_INTERVAL)
			local now = os.clock()
			for _, e in entries do
				if e.dirty and now - e.lastWrite >= WRITE_INTERVAL then
					task.spawn(write, e)
				end
			end
		end
	end)

	-- boot fetch: the client blocks its apply on this, so wait out a slow
	-- GetAsync rather than answering empty
	local rf = Instance.new("RemoteFunction")
	rf.Name = "Prefs"
	rf.Parent = net
	rf.OnServerInvoke = function(player: Player): Prefs?
		local deadline = os.clock() + LOAD_TIMEOUT
		local e = entries[player]
		while not (e and e.loaded) and os.clock() < deadline do
			task.wait(0.1)
			e = entries[player]
		end
		return if e and e.loaded then e.prefs else nil
	end

	-- change pushes: full snapshot each time, sanitized and swapped in
	-- whole (the client owns its own document; no merge needed)
	local push = Instance.new("RemoteEvent")
	push.Name = "PrefsPush"
	push.Parent = net
	push.OnServerEvent:Connect(function(player: Player, raw: any)
		local e = entries[player]
		if not e or type(raw) ~= "table" then
			return
		end
		local skins = sanitizeSkins((raw :: any).skins)
		-- ownership gate: only owned kinds may be equipped (saved skins were
		-- gated when pushed, so the load path stays trust-the-document)
		if isKindOwned then
			local dropped: { string } = {}
			for mdl, spec in skins do
				local kind = spec:match("^(%a+)")
				if kind and not isKindOwned(player, kind) then
					table.insert(dropped, mdl)
				end
			end
			for _, mdl in dropped do
				skins[mdl] = nil
			end
		end
		e.prefs.settings = sanitizeSettings((raw :: any).settings)
		e.prefs.skins = skins
		e.dirty = true
		publishSkins(player, e.prefs.skins)
	end)
end
