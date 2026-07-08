--!strict
-- Shop catalog: the hand-curated rarity table must cover skinforge's
-- generator registry exactly, prices must be sane, and the daily rotation
-- must be deterministic (client and server derive it independently).

local t = require("./testutil")
local shopcatalog = require("../src/shared/shopcatalog")
local skinforge = require("../src/client/render/skinforge")

-- every generator kind has a rarity, and no catalog entry is stale
local kinds = skinforge.kinds()
local seen: { [string]: boolean } = {}
for _, kind in kinds do
	seen[kind] = true
	t.check(shopcatalog.KINDS[kind] ~= nil, `kind "{kind}" has a rarity`)
end
for kind in shopcatalog.KINDS do
	t.check(seen[kind] == true, `catalog kind "{kind}" exists in skinforge`)
end

-- rarity names resolve, prices are positive, tiers are ordered cheap->dear
local lastCoins = 0
for _, tier in shopcatalog.TIER_ORDER do
	local r = shopcatalog.RARITIES[tier]
	t.check(r ~= nil, `tier "{tier}" defined`)
	t.check(r.coins > lastCoins, `tier "{tier}" costs more coins than the previous tier`)
	t.check(r.robux > 0, `tier "{tier}" has a robux display price`)
	lastCoins = r.coins
end
for kind, name in shopcatalog.KINDS do
	t.check(shopcatalog.RARITIES[name] ~= nil, `kind "{kind}" maps to a real rarity`)
	t.check(shopcatalog.rarityOf(kind) == shopcatalog.RARITIES[name], `rarityOf("{kind}") resolves`)
end
t.check(shopcatalog.rarityOf("plaid") == nil, "unknown kind has no rarity")

-- each tier actually has kinds to rotate through
do
	local counts: { [string]: number } = {}
	for _, name in shopcatalog.KINDS do
		counts[name] = (counts[name] or 0) + 1
	end
	for _, tier in shopcatalog.TIER_ORDER do
		t.check((counts[tier] or 0) >= 3, `tier "{tier}" has at least 3 kinds`)
	end
end

-- unconfigured product ids (0) never reverse-match
t.check(shopcatalog.productRarity(0) == nil, "product id 0 never matches")

-- daily picks: deterministic, one per tier in card order, valid specs
local a = shopcatalog.picks(20612)
local b = shopcatalog.picks(20612)
t.eq(#a, 3, "three picks per day")
for i = 1, 3 do
	t.eq(a[i].kind, b[i].kind, `pick {i} kind deterministic`)
	t.eq(a[i].spec, b[i].spec, `pick {i} spec deterministic`)
	t.eq(a[i].rarity, shopcatalog.TIER_ORDER[i], `pick {i} rarity matches card order`)
	t.eq(shopcatalog.KINDS[a[i].kind], a[i].rarity, `pick {i} kind belongs to its tier`)
	local recipe = skinforge.parse(a[i].spec)
	t.check(recipe ~= nil and recipe.kind == a[i].kind, `pick {i} spec parses via skinforge`)
end
-- different days rotate (a fixed pick would make the countdown a lie); check
-- a window wide enough that a repeated kind on neighboring days can't fail us
do
	local varied = false
	for day = 20612, 20619 do
		local p = shopcatalog.picks(day)
		if p[1].kind ~= a[1].kind or p[2].kind ~= a[2].kind or p[3].kind ~= a[3].kind then
			varied = true
			break
		end
	end
	t.check(varied, "picks vary across days")
end

t.finish("shopcatalog")
