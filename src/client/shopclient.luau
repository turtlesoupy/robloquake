--!strict
-- Shop bridge (PRODUCT layer): the client's view of the skin economy. The
-- server publishes the wallet as player attributes — RQCoins (number,
-- live-updates on every kill) and RQOwnedSkins (JSON array of owned
-- skinforge kinds) — so reads are free; only purchases invoke the Shop
-- RemoteFunction (src/server/shop.luau). Robux purchases resolve
-- asynchronously: the invoke just opens the platform prompt, and the
-- receipt lands later as an attribute change (onChanged fires).
--
-- REMOVAL: delete this file, its attach in both client boots, and the
-- SHOP/MY SKINS purchase wiring in pausemenu.luau (opts.shop).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local shopclient = {}

export type Handle = {
	getCoins: () -> number,
	isOwned: (kind: string) -> boolean,
	-- yields; returns ok plus a server error code (LOADING | POOR | ERROR |
	-- NOPRODUCT | SLOW | BAD | OFFLINE)
	buy: (kind: string, pay: "coins" | "robux") -> (boolean, string?),
	onChanged: (cb: () -> ()) -> (), -- wallet/ownership attribute changed
}

function shopclient.attach(opts: { net: Instance }): Handle
	local player = Players.LocalPlayer
	local owned: { [string]: boolean } = {}
	local callbacks: { () -> () } = {}

	local function refreshOwned()
		table.clear(owned)
		local raw = player:GetAttribute("RQOwnedSkins")
		if type(raw) == "string" then
			pcall(function()
				for _, kind in HttpService:JSONDecode(raw) :: { string } do
					owned[kind] = true
				end
			end)
		end
	end
	refreshOwned()

	local function fire()
		for _, cb in callbacks do
			task.spawn(cb)
		end
	end
	player:GetAttributeChangedSignal("RQOwnedSkins"):Connect(function()
		refreshOwned()
		fire()
	end)
	player:GetAttributeChangedSignal("RQCoins"):Connect(fire)

	local rf: RemoteFunction? = nil
	task.spawn(function()
		local r = opts.net:WaitForChild("Shop", 15)
		if r and r:IsA("RemoteFunction") then
			rf = r
		end
	end)

	return {
		getCoins = function(): number
			return tonumber(player:GetAttribute("RQCoins")) or 0
		end,
		isOwned = function(kind: string): boolean
			return owned[kind] == true
		end,
		buy = function(kind: string, pay: "coins" | "robux"): (boolean, string?)
			local remote = rf
			if not remote then
				return false, "OFFLINE"
			end
			local ok, res = pcall(function()
				return remote:InvokeServer({ kind = kind, pay = pay })
			end)
			if not ok or typeof(res) ~= "table" then
				return false, "ERROR"
			end
			return (res :: any).ok == true, (res :: any).err
		end,
		onChanged = function(cb: () -> ())
			table.insert(callbacks, cb)
		end,
	}
end

return shopclient
