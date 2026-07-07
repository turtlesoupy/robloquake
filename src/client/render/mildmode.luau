--!strict
-- Mild mode (product layer, shared by the NQ and QW clients): softens
-- the violent presentation for content classification, gated by the
-- mildmode attribute the server mirrors onto QuakeClientFS. Like
-- roblox_avatars it defaults ON when the QuakeAssets attribute is
-- absent; an explicit mildmode=false restores the untouched original
-- rendering. The engine sim and wire protocol are identical either
-- way — everything here is display-only.
--
--   * gib models (chunks + thrown heads) render untextured white
--   * blood particles display white instead of the palette red ramp
--   * player corpses (bodyque) fade out after CORPSE_HOLD seconds
--
-- Detection keys off names/indices hardcoded in the progs and engine
-- (progs/gib*.mdl, progs/h_*.mdl, particle colors 73/67), not the asset
-- pixels, so it holds for any drop-in asset set (id1, librequake).

local mildmode = {}

mildmode.enabled = false

-- read once at client boot (attributes are stamped before the bundle's
-- ready flag, so this is stable for the session)
function mildmode.init(clientAssets: Instance)
	mildmode.enabled = clientAssets:GetAttribute("mildmode") == true
end

--------------------------------------------------------------------------
-- white gibs

-- gib chunks, thrown heads, zombie gibs — the progs model names are the
-- id1 layout every compatible asset set (threewave, librequake) keeps
function mildmode.isGibModel(name: string): boolean
	return name:match("^progs/gib%d%.mdl$") ~= nil
		or name == "progs/zom_gib.mdl"
		or name:match("^progs/h_[%w_]+%.mdl$") ~= nil
end

--------------------------------------------------------------------------
-- white blood

-- palette indices blood particles land on: R_RunParticleEffect color 73
-- spreads to (73 & ~7) + rand&7 = 72..79, and blood/slight-blood trails
-- (R_RocketTrail types 2/4) use 67 + rand&3 = 67..70. These ranges are
-- QuakeC/engine constants, independent of the palette pixels shipped.
-- (TE_LIGHTNINGBLOOD's 225 band is shared with lava splashes and knight
-- spikes, so the QW client substitutes color 73 at that call site
-- instead of whitening the band.)
mildmode.BLOOD_INDICES = { 67, 68, 69, 70, 72, 73, 74, 75, 76, 77, 78, 79 }

--------------------------------------------------------------------------
-- corpse fade

local CORPSE_HOLD = 10 -- seconds a corpse stays fully visible
local CORPSE_FADE = 1 -- seconds of transparency ramp after the hold

-- bodyque entities are a small fixed pool the progs recycle: a new death
-- rewrites the same entity at a new origin, which resets the timer. Time
-- running backwards (level change/restart) also resets.
local corpses: { [string]: { org: vector, since: number } } = {}

-- 0 = fully visible, 1 = fully faded; call every frame a corpse renders
function mildmode.corpseAlpha(key: string, origin: vector, time: number): number
	local c = corpses[key]
	if c and vector.magnitude(origin - c.org) <= 4 and time >= c.since then
		c.org = origin
		return math.clamp((time - c.since - CORPSE_HOLD) / CORPSE_FADE, 0, 1)
	end
	corpses[key] = { org = origin, since = time }
	return 0
end

-- apply a fade to an alias render ent's part. Tracked via a marker so a
-- pooled/reused ent can be cheaply restored (see the callers).
function mildmode.applyFade(re: any, alpha: number)
	if not re then
		return
	end
	if alpha <= 0 and not re.mildFaded then
		return
	end
	re.mildFaded = if alpha > 0 then true else nil
	local part: BasePart? = re.part or re.billboardPart
	if part then
		part.Transparency = alpha
	end
end

return mildmode
