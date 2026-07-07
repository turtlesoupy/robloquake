--!strict
-- Global admins (PRODUCT layer): the user-id allowlist behind the replicated
-- RQAdmin attribute, which gates DEV surfaces client-side (tweaks menu,
-- engine menu, console). Distinct from the per-server host rules
-- (playerIsHost in the boots): owning a private server grants match
-- control via the director, not dev tooling.

local RunService = game:GetService("RunService")

local ADMIN_IDS: { [number]: boolean } = {
	[1488222384] = true, -- turtlesoupy
}

return function(player: Player): boolean
	return RunService:IsStudio() or ADMIN_IDS[player.UserId] == true
end
