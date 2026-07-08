--!strict
-- Shop (PRODUCT layer, NOT engine): server authority for skin purchases.
-- Two payment paths per skin, both validated against the shared catalog
-- (src/shared/shopcatalog.luau):
--
--   Frag Coins  client invokes the Shop RemoteFunction; the wallet debit +
--               ownership grant is one guarded UpdateAsync in statstore.
--   Robux       one developer product per rarity tier. The invoke records a
--               purchase intent (which kind the player is buying) and opens
--               the platform prompt; ProcessReceipt fulfils it. A receipt
--               with no matching intent (server crashed between prompt and
--               receipt) grants the tier's Frag Coin value instead so the
--               Robux is never lost — those coins buy the same skin.
--
-- ProcessReceipt rules honoured here: only return PurchaseGranted after the
-- profile write succeeded (statstore records the purchase id, so Roblox's
-- redelivery after a crash can't double-grant); NotProcessedYet retries.
--
-- REMOVAL: delete this file, its require in both server boots,
-- src/client/shopclient.luau, src/shared/shopcatalog.luau, the coin hooks
-- in stats.luau and the wallet block in statstore.luau.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shopcatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("shopcatalog"))

local REQUEST_COOLDOWN = 1 -- per-player rate limit on the RemoteFunction
local INTENT_TTL = 3600 -- seconds a robux purchase intent stays valid

export type Deps = {
	net: Instance, -- the Shop RemoteFunction parents here (QuakeNet)
	store: any, -- statstore.new() result (wallet lives there)
}

return function(deps: Deps)
	local store = deps.store

	-- userId -> the kind mid-purchase; survives the player rejoining this
	-- same server, pruned by age (receipts usually land within seconds)
	local intents: { [number]: { kind: string, at: number } } = {}

	local lastReq: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(p)
		lastReq[p] = nil
	end)

	local rf = Instance.new("RemoteFunction")
	rf.Name = "Shop"
	rf.Parent = deps.net

	-- request: { kind: string, pay: "coins" | "robux" }
	-- response: { ok: boolean, err: string? } — err codes the client maps to
	-- messages: LOADING | POOR | ERROR | NOPRODUCT | SLOW | BAD
	rf.OnServerInvoke = function(player: Player, req: any)
		if typeof(req) ~= "table" or type(req.kind) ~= "string" then
			return { ok = false, err = "BAD" }
		end
		local now = os.clock()
		if now - (lastReq[player] or -math.huge) < REQUEST_COOLDOWN then
			return { ok = false, err = "SLOW" }
		end
		lastReq[player] = now
		local rarity = shopcatalog.rarityOf(req.kind)
		if not rarity then
			return { ok = false, err = "BAD" }
		end
		if req.pay == "coins" then
			local ok, err = store.trySpend(player, rarity.coins, req.kind)
			return { ok = ok, err = err }
		elseif req.pay == "robux" then
			if rarity.productId == 0 then
				return { ok = false, err = "NOPRODUCT" } -- dashboard not set up
			end
			intents[player.UserId] = { kind = req.kind, at = os.time() }
			local ok = pcall(function()
				MarketplaceService:PromptProductPurchase(player, rarity.productId)
			end)
			-- ok just means the prompt opened; fulfilment happens in
			-- ProcessReceipt and reaches the client as an attribute change
			return { ok = ok, err = if ok then nil else "ERROR" }
		end
		return { ok = false, err = "BAD" }
	end

	MarketplaceService.ProcessReceipt = function(info): Enum.ProductPurchaseDecision
		local rarity = shopcatalog.productRarity(info.ProductId)
		if not rarity then
			-- not one of ours (or ids unconfigured): let Roblox keep retrying
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		-- prune stale intents while we're here
		local cutoff = os.time() - INTENT_TTL
		for userId, intent in intents do
			if intent.at < cutoff then
				intents[userId] = nil
			end
		end
		-- the intent must match the paid tier, or the player could prompt a
		-- cheap product while intending a legendary kind
		local intent = intents[info.PlayerId]
		local kind = if intent and shopcatalog.rarityOf(intent.kind) == rarity then intent.kind else nil
		local res: string
		if kind then
			res = store.grantProduct(info.PlayerId, { kind = kind, purchaseId = info.PurchaseId })
		else
			-- no intent (redelivery on another server / crash): refund the
			-- tier's value in Frag Coins so the purchase keeps its worth
			res = store.grantProduct(info.PlayerId, { coins = rarity.coins, purchaseId = info.PurchaseId })
		end
		if res == "granted" then
			intents[info.PlayerId] = nil
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end
