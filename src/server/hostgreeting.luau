--!strict
-- Host greeting (PRODUCT layer, NOT engine): tell the host player they
-- have match controls. Deliberately uses the engine's own notification
-- surface — a server console print, MOTD-style, exactly how Quake
-- servers greet players — so there is no new UI and nothing engine-side
-- changes. The boot supplies the per-engine print mechanics.
--
-- REMOVAL: delete this file and the marked "host greeting" lines in
-- init.server.luau / qwserver.luau.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

-- kept under ~65 chars so it fits one console line at common windows
local GREETING = "You are the host - press P or the gear button for match controls\n"
local DELAY = 3 -- seconds after connect, so the line outlives the join spam

export type Adapter = {
	isHost: (player: Player) -> boolean,
	-- write one console line to this player's client (engine print path)
	sendPrint: (player: Player, text: string) -> (),
}

-- returns greet(player); call it once per player connect
return function(a: Adapter): (player: Player) -> ()
	-- Studio makes everyone host: keep dev sessions quiet unless the
	-- debug attribute asks for the greeting explicitly
	local function enabled(): boolean
		return not RunService:IsStudio() or ServerStorage:GetAttribute("RQDBG_HostGreeting") == true
	end
	return function(player: Player)
		if not (enabled() and a.isHost(player)) then
			return
		end
		task.delay(DELAY, function()
			if player.Parent then
				a.sendPrint(player, GREETING)
			end
		end)
	end
end
