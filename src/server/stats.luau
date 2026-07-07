--!strict
-- Stats capture (PRODUCT layer, NOT engine): observes engine state
-- through a small per-boot adapter — same pattern as the match
-- director — and drives statscore sessions + statstore persistence.
-- The engine is never modified; everything is read out of edict fields
-- the servers already maintain (frags/health/deadflag/weapon).
--
-- REMOVAL: delete this file, statscore.luau, statstore.luau,
-- src/client/leaderboardui.luau and the marked "stats" blocks in
-- init.server.luau / qwserver.luau / the client boots.

local Players = game:GetService("Players")

local statscore = require(script.Parent.statscore)

local stats = {}

export type SlotRead = {
	frags: number,
	health: number,
	deadflag: number,
	weapon: number,
}

export type Adapter = {
	store: any, -- statstore.new() result
	maxclients: number,
	playerBySlot: (slot: number) -> Player?,
	readSlot: (slot: number) -> SlotRead?, -- nil for inactive slots
	getIntermission: () -> boolean,
	getCurrentMap: () -> string,
	competitive: boolean, -- wins only make sense under deathmatch rules
}

function stats.attach(a: Adapter)
	local store = a.store

	local lastFrags: { [Player]: number } = {}
	local wasDead: { [Player]: boolean } = {}
	local sessDeaths: { [Player]: number } = {}
	local playtimeAccum: { [Player]: number } = {}
	local wonPending: { [Player]: boolean } = {}
	local matchPending = false
	local wasIntermission = false
	local lastMap = a.getCurrentMap()

	Players.PlayerRemoving:Connect(function(player)
		lastFrags[player] = nil
		wasDead[player] = nil
		sessDeaths[player] = nil
		playtimeAccum[player] = nil
		wonPending[player] = nil
		store.remove(player)
	end)

	local api = {}

	-- call every server heartbeat
	function api.step(dt: number)
		-- intermission rising edge: snapshot the scoreboard NOW — QC
		-- resets frags at the changelevel that follows
		local inter = a.getIntermission()
		if inter and not wasIntermission then
			matchPending = true
			table.clear(wonPending)
			if a.competitive then
				local frags: { [number]: number } = {}
				for slot = 1, a.maxclients do
					local read = if a.playerBySlot(slot) then a.readSlot(slot) else nil
					if read then
						frags[slot] = read.frags
					end
				end
				for slot in statscore.winners(frags) do
					local p = a.playerBySlot(slot)
					if p then
						wonPending[p] = true
					end
				end
			end
		end
		wasIntermission = inter

		-- map change: close the round for everyone still here
		local map = a.getCurrentMap()
		if map ~= lastMap then
			lastMap = map
			for player in lastFrags do
				store.session(player) -- ensure
				statscore.applyRoundEnd(store.session(player), matchPending, wonPending[player] == true)
			end
			-- QC reset frags to 0: forget observed values so the drop is
			-- not misread as a pile of suicides
			table.clear(lastFrags)
			table.clear(wonPending)
			matchPending = false
		end

		for slot = 1, a.maxclients do
			local player = a.playerBySlot(slot)
			if not player then
				continue
			end
			local read = a.readSlot(slot)
			if not read then
				continue
			end
			local sess = store.session(player)

			-- frags: first observation just baselines
			local last = lastFrags[player]
			if last ~= nil and read.frags ~= last then
				statscore.applyFragDelta(sess, read.frags - last, read.weapon)
			end
			lastFrags[player] = read.frags

			-- deaths: deadflag edge (covers gib deaths where health is
			-- long gone before the corpse settles)
			local dead = read.deadflag ~= 0
			if dead and not wasDead[player] then
				statscore.applyDeath(sess)
				sessDeaths[player] = (sessDeaths[player] or 0) + 1
			end
			wasDead[player] = dead

			-- playtime in whole seconds
			local acc = (playtimeAccum[player] or 0) + dt
			if acc >= 1 then
				local whole = math.floor(acc)
				statscore.applyPlaytime(sess, whole)
				acc -= whole
			end
			playtimeAccum[player] = acc

			-- native playerlist mirrors the live scoreboard
			store.setLeaderstats(player, read.frags, sessDeaths[player] or 0)
		end

		store.step() -- staggered autosave flushes
	end

	return api
end

return stats
