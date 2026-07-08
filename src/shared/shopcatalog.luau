--!strict
-- Shop catalog (PRODUCT layer, NOT engine): single source of truth for the
-- skin economy — hand-curated rarity per skinforge kind, Frag Coin prices,
-- Robux developer products, coin earn rates, and the daily 3-up shop
-- rotation. Shared so the server validates purchases against exactly the
-- data the pause menu renders. Pure (no `game`) so lune tests can check it
-- against skinforge's generator registry.
--
-- REMOVAL: delete this file, src/server/shop.luau, src/client/shopclient.luau,
-- the coin-award hooks in src/server/stats.luau, the wallet block in
-- src/server/statstore.luau, and the shop wiring in both server/client boots.

local shopcatalog = {}

-- Fragcoin earn rate (server-authoritative, applied in stats.luau on
-- positive frag deltas only — self-kills/suicides never award)
shopcatalog.COINS_PER_KILL = 1

export type Rarity = {
	name: string,
	coins: number, -- Frag Coin price
	-- FALLBACK display price only: the products use managed pricing, so the
	-- real price varies by region/time. shopclient fetches the live price via
	-- GetProductInfo; this constant shows until that fetch lands (and in lune
	-- tests, which have no MarketplaceService). The charge itself always
	-- comes from the platform prompt, never from here.
	robux: number,
	productId: number, -- MarketplaceService developer product; 0 = not set up yet
}

-- Robux product ids are per-RARITY (three products total, created once in the
-- Creator Dashboard) because skins are procedural — a product per skin would
-- need dashboard work for every new generator. Fill the ids in after creating
-- the products; until then the Robux button reports "coming soon".
-- prices are 1:1 across the two payment paths (a skin's Fragcoin price
-- equals its Robux price)
shopcatalog.RARITIES = {
	COMMON = { name = "COMMON", coins = 99, robux = 99, productId = 3608770508 },
	RARE = { name = "RARE", coins = 199, robux = 199, productId = 3608770558 },
	LEGENDARY = { name = "LEGENDARY", coins = 399, robux = 399, productId = 3608770587 },
} :: { [string]: Rarity }

-- daily shop card order, cheapest first (matches the 3-up page)
shopcatalog.TIER_ORDER = { "COMMON", "RARE", "LEGENDARY" }

-- hand-curated rarity per skinforge kind (replaces the old deterministic
-- shuffle in pausemenu). tests/test_shopcatalog.luau asserts this table and
-- skinforge's generator registry stay in exact sync.
shopcatalog.KINDS = {
	-- COMMON: plain materials and simple patterns
	camo = "COMMON",
	zebra = "COMMON",
	tortoise = "COMMON",
	matteblack = "COMMON",
	ghostwhite = "COMMON",
	grass = "COMMON",
	clouds = "COMMON",
	stone = "COMMON",
	herringbone = "COMMON",
	checkered = "COMMON",
	pinstripe = "COMMON",
	argyle = "COMMON",
	rust = "COMMON",
	honeycomb = "COMMON",
	wood = "COMMON",
	mossystone = "COMMON",
	-- RARE: showy prints and themes
	leopard = "RARE",
	cottoncandy = "RARE",
	deeppurple = "RARE",
	ocean = "RARE",
	circuit = "RARE",
	tiger = "RARE",
	snakeskin = "RARE",
	blueprint = "RARE",
	candycane = "RARE",
	hazard = "RARE",
	-- LEGENDARY: the flashy animated-feel exotics
	lightning = "LEGENDARY",
	dragon = "LEGENDARY",
	lava = "LEGENDARY",
	galaxy = "LEGENDARY",
	glitch = "LEGENDARY",
	oilslick = "LEGENDARY",
} :: { [string]: string }

function shopcatalog.rarityOf(kind: string): Rarity?
	local name = shopcatalog.KINDS[kind]
	return if name then shopcatalog.RARITIES[name] else nil
end

-- ProcessReceipt reverse lookup; 0 (unconfigured) never matches
function shopcatalog.productRarity(productId: number): Rarity?
	if productId == 0 then
		return nil
	end
	for _, r in shopcatalog.RARITIES do
		if r.productId == productId then
			return r
		end
	end
	return nil
end

-- sorted kind list per tier (stable across client/server for the rotation)
local tierLists: { [string]: { string } }? = nil
local function getTierLists(): { [string]: { string } }
	if tierLists then
		return tierLists :: { [string]: { string } }
	end
	local lists: { [string]: { string } } = {}
	for _, tier in shopcatalog.TIER_ORDER do
		lists[tier] = {}
	end
	for kind, tier in shopcatalog.KINDS do
		table.insert(lists[tier], kind)
	end
	for _, list in lists do
		table.sort(list)
	end
	tierLists = lists
	return lists
end

-- deterministic integer hash (skinforge's mul32/hash2 recipe) so the daily
-- rotation agrees on every client AND the server without Random (lune-safe)
local function mul32(a: number, b: number): number
	local alo = bit32.band(a, 0xffff)
	local ahi = bit32.rshift(a, 16)
	return bit32.band(alo * b + bit32.lshift(bit32.band(ahi * b, 0xffff), 16), 0xffffffff)
end
local function hash(day: number, salt: number): number
	local h = bit32.bxor(mul32(day, 0x9E3779B1), mul32(salt + 1, 0x85EBCA77))
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = mul32(h, 0x27D4EB2F)
	return bit32.bxor(h, bit32.rshift(h, 13))
end

export type Pick = { kind: string, spec: string, rarity: string }

-- the three skins on sale for a given UTC day, one per tier (card order =
-- TIER_ORDER). The seed only varies the look of the featured spec; buying
-- grants the KIND (every seed of it, via the MY SKINS page's kind:7 apply).
function shopcatalog.picks(day: number): { Pick }
	local lists = getTierLists()
	local out: { Pick } = {}
	for i, tier in shopcatalog.TIER_ORDER do
		local list = lists[tier]
		local kind = list[hash(day, i) % #list + 1]
		out[i] = { kind = kind, spec = `{kind}:{hash(day, i + 16) % 1000000}`, rarity = tier }
	end
	return out
end

return shopcatalog
