--!strict
-- Leaderboard data source (PRODUCT layer, NOT engine): resolves the server's
-- Leaderboards RemoteFunction (src/server/statstore.luau) and exposes a paced
-- fetch for the pause menu's RANKINGS page (src/client/pausemenu.luau, which
-- owns the UI). The daily/weekly/all-time kill boards come from the stats
-- pipeline; this stays dormant (ready() == false) when the server has no
-- DataStore access, leaving the page to show "unavailable". Deletable at any
-- time (see the REMOVAL note in src/server/stats.luau): drop this file and
-- pass `leaderboards = nil` to pausemenu.attach.

local leaderboardui = {}

export type Opts = {
	net: Instance, -- the Leaderboards RemoteFunction is parented here
}

export type Entry = { userId: number, name: string, value: number }
export type Result = { disabled: boolean?, entries: { Entry }? }
-- the caller's own card (pause-menu MAIN page): all-time frags/wins plus
-- day/all-time GLOBAL kill ranks (rank nil = unranked/outside the top page)
export type MyStats = { frags: number, wins: number, rankDay: number?, rankAll: number?, disabled: boolean? }

-- structurally matches pausemenu.Leaderboards
export type Handle = {
	ready: () -> boolean,
	fetch: (period: string, scope: string) -> (boolean, Result?),
	myStats: () -> (boolean, MyStats?),
}

function leaderboardui.attach(opts: Opts): Handle
	-- the remote appears asynchronously (server may still be booting, or the
	-- stats pipeline may be absent entirely); resolve it in the background and
	-- leave ready() false until it lands
	local rf: RemoteFunction? = nil
	task.spawn(function()
		local remote = opts.net:WaitForChild("Leaderboards", 30)
		if remote and remote:IsA("RemoteFunction") then
			rf = remote
		end
	end)

	return {
		ready = function(): boolean
			return rf ~= nil
		end,
		-- yields on the round-trip; returns (ok, result). ok is false on a
		-- transport error, result.disabled means stats are off this session.
		fetch = function(period: string, scope: string): (boolean, Result?)
			local r = rf
			if not r then
				return false, nil
			end
			local ok, res = pcall(function()
				return r:InvokeServer({ period = period, scope = scope })
			end)
			if not ok or typeof(res) ~= "table" then
				return false, nil
			end
			return true, res :: Result
		end,
		-- the caller's own persistent card; returns (ok, stats). Same
		-- transport contract as fetch: false ok is a transport error.
		myStats = function(): (boolean, MyStats?)
			local r = rf
			if not r then
				return false, nil
			end
			local ok, res = pcall(function()
				return r:InvokeServer({ kind = "me" })
			end)
			if not ok or typeof(res) ~= "table" then
				return false, nil
			end
			return true, res :: MyStats
		end,
	}
end

return leaderboardui
