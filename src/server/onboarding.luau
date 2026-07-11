--!strict
-- Onboarding (PRODUCT layer, NOT engine): first-session analytics
-- funnel + the one-time join card handshake, shared by both boots.
--
-- Funnel (AnalyticsService onboarding funnel): logged ONLY during a
-- player's first-ever session (DataStore first-seen flag) so later
-- sessions can't re-open it, and skipped in Studio so test runs never
-- pollute the charts. Steps are ordered by inevitability — Roblox
-- treats a skipped step as completed, so no step may be reachable
-- before the ones under it:
--   1 Client Started (platform ping from the client's boot scripts)
--   2 Spawned        (engine client connected: world loaded)
--   3 Moved          (deliberate horizontal movement)
--   4 Fired          (first attack button press)
--   5 First Blood    (first kill OR first death — combat resolved)
--   6 Played 3 Min
-- Every step carries the client platform (CustomField01: touch/
-- desktop/gamepad) — Creator Hub funnel breakdowns read it from step 1,
-- answering "where do mobile players bail" separately from desktop.
--
-- Join card: currently shown EVERY session (product call while paid-ads
-- confusion is the top problem); dismissals are still persisted, so
-- restoring once-only behavior = re-add the `not st.introSeen` guard at
-- the two showIntro sends. Client half: src/client/joincard.luau.
--
-- REMOVAL: delete this file, src/client/joincard.luau, the joincard
-- require in src/client/init.client.luau, and the marked "onboarding"
-- blocks in init.server.luau / qwserver.luau.

local AnalyticsService = game:GetService("AnalyticsService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ONBOARD_STORE = "rq-onboard-1"
local PLATFORM_TIMEOUT = 15 -- secs before step 1 logs as "unknown"
local PLAYED_SECS = 180 -- step 6 threshold, from spawn
local MOVE_SPEED = 50 -- qu/s horizontal: deliberate movement, above jitter
local SHIELD_SECS = 45 -- max invulnerability while the card is up (anti-idle)

local STEP_NAMES = {
	[1] = "Client Started",
	[2] = "Spawned",
	[3] = "Moved",
	[4] = "Fired",
	[5] = "First Blood",
	[6] = "Played 3 Min",
}

-- what a boot's adapter reads out of a live client slot each heartbeat
export type SlotRead = {
	speed: number, -- horizontal velocity magnitude, qu/s
	firing: boolean, -- attack button held
	dead: boolean,
	frags: number,
}
export type Adapter = {
	maxclients: number,
	playerBySlot: (slot: number) -> Player?,
	readSlot: (slot: number) -> SlotRead?, -- nil for inactive slots
	-- reading the card must not get you fragged: while on, the player
	-- edict's takedamage is zeroed (re-applied every heartbeat — QC
	-- respawns rewrite it); off restores DAMAGE_AIM
	setShield: (slot: number, on: boolean) -> (),
}

type State = {
	loaded: boolean, -- store fetch finished: first/introSeen are truth
	first: boolean, -- first-ever session: funnel is live
	introSeen: boolean, -- card already dismissed in some session
	platform: string?,
	step: number, -- funnel high-water mark
	spawnedAt: number?,
	wasFiring: boolean,
	wasDead: boolean,
	lastFrags: number?,
	cardSent: boolean,
	cardAt: number?, -- when the card went up (shield window start)
	cardDone: boolean, -- dismissed THIS session (shield + resend gate)
	shielded: boolean,
}

return function(net: Instance)
	local remote = Instance.new("RemoteEvent")
	remote.Name = "Onboard"
	remote.Parent = net

	-- Studio play sessions must not feed the production funnel; the join
	-- card flow still runs so it stays testable
	local logEnabled = not RunService:IsStudio()

	local disabled = false -- DataStores unreachable: in-memory session only
	local store: DataStore? = nil
	if RunService:IsRunning() then
		local ok, ds = pcall(function()
			return DataStoreService:GetDataStore(ONBOARD_STORE)
		end)
		if ok then
			store = ds
		end
	end

	local states: { [Player]: State } = {}

	local function noteStoreError(err: any)
		local s = tostring(err):lower()
		if s:find("access") or s:find("publish") then
			if not disabled then
				disabled = true
				warn(`[onboard] DataStores unavailable — onboarding runs in-memory only ({err})`)
			end
		else
			warn(`[onboard] store op failed: {err}`)
		end
	end

	local function markStored(player: Player, field: string)
		local ds = store
		if not ds or disabled then
			return
		end
		task.spawn(function()
			local ok, err = pcall(function()
				ds:UpdateAsync(`u{player.UserId}`, function(old: any)
					local doc = if type(old) == "table" then old else {}
					doc[field] = true
					return doc
				end)
			end)
			if not ok then
				noteStoreError(err)
			end
		end)
	end

	local function log(player: Player, st: State, step: number)
		if not st.first or not logEnabled then
			return
		end
		if step <= st.step then
			return
		end
		st.step = step
		pcall(function()
			AnalyticsService:LogOnboardingFunnelStepEvent(player, step, STEP_NAMES[step], {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = st.platform or "unknown",
			})
		end)
	end

	local function onJoin(player: Player)
		local st: State = {
			loaded = false,
			first = false,
			introSeen = false,
			platform = nil,
			step = 0,
			spawnedAt = nil,
			wasFiring = false,
			wasDead = false,
			lastFrags = nil,
			cardSent = false,
			cardAt = nil,
			cardDone = false,
			shielded = false,
		}
		states[player] = st
		-- one read decides both halves: funnel only on a first-ever
		-- session, card only until a dismissal has been persisted
		local doc: any = nil
		local ds = store
		if ds and not disabled then
			local ok, saved = pcall(function()
				return ds:GetAsync(`u{player.UserId}`)
			end)
			if ok then
				doc = saved
			else
				noteStoreError(saved)
			end
		end
		if states[player] ~= st then
			return -- left during the fetch
		end
		st.first = type(doc) ~= "table"
		st.introSeen = type(doc) == "table" and doc.intro == true
		st.loaded = true
		if st.first then
			markStored(player, "seen")
		end
		-- spawn beat the fetch (first player vs a cold server): the card
		-- decision was deferred to here
		if st.spawnedAt and not st.cardSent then
			st.cardSent = true
			st.cardAt = os.clock()
			remote:FireClient(player, "showIntro")
		end
		-- step 1 waits for the platform ping (funnel breakdowns read
		-- custom fields from the FIRST step); fall back so a client that
		-- never pings still enters the funnel
		task.delay(PLATFORM_TIMEOUT, function()
			if states[player] == st then
				log(player, st, 1)
			end
		end)
	end

	Players.PlayerAdded:Connect(onJoin)
	-- the first player beats the boot to the server (pak loading takes
	-- seconds); sweep everyone already here or their join is never seen
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	remote.OnServerEvent:Connect(function(player: Player, msg: unknown, arg: unknown)
		local st = states[player]
		if not st then
			return
		end
		if msg == "platform" and st.platform == nil then
			local p = if arg == "touch" or arg == "gamepad" or arg == "desktop" then arg :: string else "unknown"
			st.platform = p
			log(player, st, 1)
			-- the ping always follows the client's showIntro listener, so
			-- it doubles as "ready — resend": a showIntro pushed before the
			-- listener connected is otherwise lost (RemoteEvents don't
			-- replay; bit us in Studio when the spawn won the race)
			if st.cardSent and not st.cardDone then
				remote:FireClient(player, "showIntro")
			end
		elseif msg == "introDone" then
			st.introSeen = true
			st.cardDone = true
			markStored(player, "intro")
		end
	end)

	local api = {}

	-- boot calls when the engine client connects (world loaded + spawned)
	function api.noteSpawn(player: Player)
		local st = states[player]
		if not st then
			return
		end
		st.spawnedAt = os.clock()
		log(player, st, 2)
		-- only send once the store fetch has settled; a spawn that beats
		-- the fetch is handled at the end of onJoin
		if st.loaded and not st.cardSent then
			st.cardSent = true
			st.cardAt = os.clock()
			remote:FireClient(player, "showIntro")
		end
	end

	-- boot calls every server heartbeat with its slot adapter
	function api.step(a: Adapter)
		for slot = 1, a.maxclients do
			local player = a.playerBySlot(slot)
			local st = player and states[player :: Player]
			if not player or not st then
				continue
			end
			-- card shield: reading must not get you fragged. Re-asserted
			-- every heartbeat while wanted (QC respawns rewrite the field),
			-- dropped on dismissal or after SHIELD_SECS (anti-idle cap)
			local wantShield = st.cardSent
				and not st.cardDone
				and st.cardAt ~= nil
				and os.clock() - (st.cardAt :: number) < SHIELD_SECS
			if wantShield then
				a.setShield(slot, true)
				if not st.shielded then
					st.shielded = true
					player:SetAttribute("RQShield", true) -- diagnostics
				end
			elseif st.shielded then
				a.setShield(slot, false)
				st.shielded = false
				player:SetAttribute("RQShield", nil)
			end
			if not st.first or st.step >= 6 then
				continue -- funnel not live for this player / already done
			end
			local read = a.readSlot(slot)
			if not read then
				continue
			end
			if read.speed > MOVE_SPEED then
				log(player, st, 3)
			end
			if read.firing and not st.wasFiring then
				log(player, st, 4)
			end
			st.wasFiring = read.firing
			-- first blood: a kill (frag gain) or a death, whichever first
			if st.lastFrags ~= nil and read.frags > st.lastFrags then
				log(player, st, 5)
			end
			st.lastFrags = read.frags
			if read.dead and not st.wasDead then
				log(player, st, 5)
			end
			st.wasDead = read.dead
			local t0 = st.spawnedAt
			if t0 and os.clock() - t0 >= PLAYED_SECS then
				log(player, st, 6)
			end
		end
	end

	return api
end
