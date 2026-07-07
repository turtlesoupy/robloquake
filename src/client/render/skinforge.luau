--!strict
--!optimize 2
-- Procedural weapon skins: pure generators that take a model's base
-- palettized skin plus a recipe string and produce an RGBA8 buffer for an
-- EditableImage. Recipes are deterministic — the same spec renders the
-- same pixels on every client, so a skin replicates as a short string.
--
-- The pixel half is pure (no `game`) so lune tests can run it against the
-- real .mdl skins, same split as textures.turbFramePixels.

local gotSvc, svc = pcall(function()
	return game:GetService("AssetService")
end)
local AssetService = (if gotSvc then svc else nil) :: AssetService

local skinforge = {}

-- structurally identical to textures.Palette (kept local so lune can load
-- this module without the Roblox-only sibling requires)
export type Palette = { r: { number }, g: { number }, b: { number } }

export type Recipe = {
	kind: string,
	seed: number,
}

-- generator registry (populated below, after the pixel functions)
local GENERATORS: { [string]: { fn: (buffer, number, number, Palette, number) -> buffer, unlit: boolean? } } = {}

-- "camo" | "camo:1234" -> Recipe (nil when the spec is unknown/malformed)
function skinforge.parse(spec: string): Recipe?
	local kind, arg = string.match(spec, "^(%a+):?(%d*)$")
	if not kind or not GENERATORS[kind] then
		return nil
	end
	return { kind = kind, seed = tonumber(arg) or 0 }
end

-- unlit skins render at full brightness (entrender.setLight's fullbright
-- path) so saturated colors stay vivid in dark rooms
function skinforge.isUnlit(spec: string): boolean
	local recipe = skinforge.parse(spec)
	return recipe ~= nil and GENERATORS[recipe.kind].unlit == true
end

----------------------------------------------------------------------
-- seeded value noise (integer hashing only: doubles hold 32-bit mixing
-- exactly as long as every product stays under 2^53, hence mul32)

local function mul32(a: number, b: number): number
	local alo = bit32.band(a, 0xffff)
	local ahi = bit32.rshift(a, 16)
	return bit32.band(alo * b + bit32.lshift(bit32.band(ahi * b, 0xffff), 16), 0xffffffff)
end

-- lattice hash -> [0, 1)
local function hash2(x: number, y: number, seed: number): number
	local h = bit32.bxor(mul32(x, 0x9E3779B1), mul32(y, 0x85EBCA77), mul32(seed, 0xC2B2AE3D))
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = mul32(h, 0x27D4EB2F)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	return h / 4294967296
end

-- bilinear value noise at pixel (x, y) with the given cell size
local function valueNoise(x: number, y: number, cell: number, seed: number): number
	local gx, gy = x / cell, y / cell
	local x0, y0 = math.floor(gx), math.floor(gy)
	local fx, fy = gx - x0, gy - y0
	-- smoothstep the lattice fractions so blob edges curve
	fx = fx * fx * (3 - 2 * fx)
	fy = fy * fy * (3 - 2 * fy)
	local n00 = hash2(x0, y0, seed)
	local n10 = hash2(x0 + 1, y0, seed)
	local n01 = hash2(x0, y0 + 1, seed)
	local n11 = hash2(x0 + 1, y0 + 1, seed)
	local nx0 = n00 + (n10 - n00) * fx
	local nx1 = n01 + (n11 - n01) * fx
	return nx0 + (nx1 - nx0) * fy
end

----------------------------------------------------------------------
-- camo: two-octave noise thresholded into blotch bands, each band a flat
-- camo color modulated by the base skin's luminance so the hand-painted
-- shading (barrel highlights, grip shadows) survives the recolor

local CAMO_COLORS = {
	{ 74, 93, 58 }, -- olive
	{ 110, 90, 56 }, -- brown
	{ 138, 138, 90 }, -- khaki
	{ 43, 47, 38 }, -- near-black green
}

-- shared painter: computes contrast-stretched base luminance (weapon
-- skins are painted very dark; without the stretch recolors come out
-- flat and the gun's form stops reading), preserves fullbright pixels
-- (palette 224+: muzzle flame glow details), and calls colorAt per
-- painted pixel with the position, stretched luminance, and the base
-- pixel's palette RGB (for skins that keep some authentic paint).
local function paint(
	basePixels: buffer,
	w: number,
	h: number,
	pal: Palette,
	colorAt: (x: number, y: number, lum: number, br: number, bg: number, bb: number) -> (number, number, number)
): buffer
	local out = buffer.create(w * h * 4)
	local pr, pg, pb = pal.r, pal.g, pal.b
	local count = w * h

	local lums = buffer.create(count)
	local histo = table.create(256, 0)
	local painted = 0
	for i = 0, count - 1 do
		local p = buffer.readu8(basePixels, i)
		local lum = (pr[p + 1] * 299 + pg[p + 1] * 587 + pb[p + 1] * 114) // 1000
		buffer.writeu8(lums, i, lum)
		if p < 224 then
			histo[lum + 1] += 1
			painted += 1
		end
	end
	-- 2nd..98th percentile range, robust against stray outlier pixels
	local lo, hi = 0, 255
	local acc = 0
	for v = 0, 255 do
		acc += histo[v + 1]
		if acc <= painted * 0.02 then
			lo = v
		end
		if acc < painted * 0.98 then
			hi = v
		end
	end
	local span = math.max(hi - lo, 1)

	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x
			local p = buffer.readu8(basePixels, i)
			local o = i * 4
			if p >= 224 then
				buffer.writeu8(out, o, pr[p + 1])
				buffer.writeu8(out, o + 1, pg[p + 1])
				buffer.writeu8(out, o + 2, pb[p + 1])
			else
				local lum = math.clamp((buffer.readu8(lums, i) - lo) / span, 0, 1)
				local r, g, b = colorAt(x, y, lum, pr[p + 1], pg[p + 1], pb[p + 1])
				buffer.writeu8(out, o, math.min(255, r // 1))
				buffer.writeu8(out, o + 1, math.min(255, g // 1))
				buffer.writeu8(out, o + 2, math.min(255, b // 1))
			end
			buffer.writeu8(out, o + 3, 255)
		end
	end
	return out
end

function skinforge.camoPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local nbands = #CAMO_COLORS
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 11, seed) * 0.72 + valueNoise(x, y, 4, seed + 1) * 0.28
		local band = math.min(math.floor(n * nbands) + 1, nbands)
		local c = CAMO_COLORS[band]
		-- contrast-stretched base luminance drives shading (0.35 floor so
		-- dark paint doesn't crush to black)
		local m = 0.35 + 1.15 * lum
		return c[1] * m, c[2] * m, c[3] * m
	end)
end

-- quake-style shading shared by every skin: contrast-stretched base
-- luminance with a floor so dark paint doesn't crush to black
local function qshade(lum: number): number
	return 0.35 + 1.15 * lum
end

-- zebra: white hide with wavy black stripes via noise-warped diagonals
function skinforge.zebraPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local warp = valueNoise(x, y, 13, seed) * 22 + valueNoise(x, y, 5, seed + 1) * 6
		local band = math.sin((x + y * 0.55 + warp) * math.pi / 8)
		local m = qshade(lum)
		if band > -0.25 then
			return 235 * m, 235 * m, 232 * m -- hide (slightly warm white)
		end
		return 30 * m, 30 * m, 34 * m -- stripe
	end)
end

-- lightning: electric bolts (ridged noise) over a storm-blue base
function skinforge.lightningPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local r1 = math.abs(valueNoise(x, y, 17, seed) * 2 - 1)
		local r2 = math.abs(valueNoise(x, y, 6, seed + 3) * 2 - 1)
		local ridge = r1 * 0.8 + r2 * 0.2
		local m = qshade(lum)
		if ridge < 0.05 then
			return 240 * m, 245 * m, 255 * m -- bolt core
		elseif ridge < 0.13 then
			return 110 * m, 150 * m, 255 * m -- glow
		end
		return 22 * m, 28 * m, 58 * m -- storm sky
	end)
end

-- leopard print: tan coat, dark rosette rings with rich centers
function skinforge.leopardPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 8, seed) * 0.7 + valueNoise(x, y, 3, seed + 1) * 0.3
		local m = qshade(lum)
		if n > 0.72 then
			return 155 * m, 95 * m, 35 * m -- rosette center
		elseif n > 0.62 then
			return 40 * m, 25 * m, 12 * m -- dark ring
		end
		return 215 * m, 180 * m, 110 * m -- tan coat
	end)
end

-- cotton candy: soft pink/blue pastel swirls
function skinforge.cottoncandyPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local warp = valueNoise(x, y, 15, seed) * 30
		local t = 0.5 + 0.5 * math.sin((x * 0.7 + y * 0.4 + warp) * math.pi / 22)
		local m = qshade(lum)
		return (248 - 83 * t) * m, (165 + 40 * t) * m, (205 + 43 * t) * m
	end)
end

-- tortoise shell: amber/brown/near-black mottling
function skinforge.tortoisePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 10, seed) * 0.65 + valueNoise(x, y, 4, seed + 2) * 0.35
		local m = qshade(lum)
		if n < 0.35 then
			return 25 * m, 16 * m, 10 * m -- near-black patch
		elseif n < 0.55 then
			return 100 * m, 55 * m, 20 * m -- brown
		end
		return 195 * m, 125 * m, 45 * m -- amber
	end)
end

-- matte black: flat near-black, shading only
function skinforge.matteblackPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local _ = seed
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = 0.45 + 0.9 * lum -- raised floor so detail survives
		return 40 * m, 40 * m, 44 * m
	end)
end

-- ghost white: pale bone-white, shading only
function skinforge.ghostwhitePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local _ = seed
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		return 228 * m, 230 * m, 236 * m
	end)
end

-- deep purple: rich violet with subtle noise variation
function skinforge.deeppurplePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 12, seed) * 22
		local m = qshade(lum)
		return (82 + n) * m, 28 * m, (138 + n) * m
	end)
end

-- grass: green turf with vertical blade streaks (noise squashed in x)
function skinforge.grassPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x * 3, y, 7, seed) * 0.6 + valueNoise(x, y, 3, seed + 1) * 0.4
		local m = qshade(lum)
		if n > 0.62 then
			return 118 * m, 200 * m, 70 * m -- lit blade
		elseif n < 0.38 then
			return 25 * m, 80 * m, 30 * m -- shadowed blade
		end
		return 55 * m, 140 * m, 45 * m -- turf
	end)
end

-- clouds: white cumulus over sky blue
function skinforge.cloudsPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 16, seed) * 0.6 + valueNoise(x, y, 7, seed + 1) * 0.4
		local t = math.clamp((n - 0.45) * 3.5, 0, 1)
		local m = qshade(lum)
		return (120 + 130 * t) * m, (170 + 82 * t) * m, (235 + 20 * t) * m
	end)
end

-- stone: mottled granite grays with speckle
function skinforge.stonePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local n = valueNoise(x, y, 9, seed) * 0.6 + valueNoise(x, y, 3, seed + 1) * 0.4
		local g = 125 + (n - 0.5) * 70
		local speck = hash2(x, y, seed + 9)
		if speck > 0.97 then
			g += 45
		elseif speck < 0.03 then
			g -= 45
		end
		local m = qshade(lum)
		return g * m, g * m, (g + 6) * m
	end)
end

-- herringbone: alternating diagonal weave columns, two-tone tweed
function skinforge.herringbonePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local COL = 10
	local ofs = math.floor(hash2(1, 1, seed) * COL)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local xs = x + ofs
		local col = xs // COL
		local d = if col % 2 == 0 then (xs + y) % COL else (xs - y) % COL
		local m = qshade(lum)
		if d < 1.5 then
			return 190 * m, 180 * m, 165 * m -- seam thread
		end
		if col % 2 == 0 then
			return 112 * m, 88 * m, 62 * m -- warp tweed
		end
		return 88 * m, 68 * m, 48 * m -- weft tweed
	end)
end

-- checkered: classic black/white checkerboard
function skinforge.checkeredPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local SQ = 12
	local ofs = math.floor(hash2(1, 1, seed) * SQ)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		if (((x + ofs) // SQ) + ((y + ofs) // SQ)) % 2 == 0 then
			return 232 * m, 232 * m, 232 * m
		end
		return 26 * m, 26 * m, 30 * m
	end)
end

-- pinstripe: banker's navy with thin chalk stripes
function skinforge.pinstripePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local PERIOD = 11
	local ofs = math.floor(hash2(1, 1, seed) * PERIOD)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		if (x + ofs) % PERIOD < 1.5 then
			return 205 * m, 208 * m, 218 * m -- chalk stripe
		end
		return 30 * m, 35 * m, 52 * m -- navy
	end)
end

-- argyle: burgundy/navy diamond lattice with pale crossing lines
function skinforge.argylePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local ou = hash2(1, 1, seed)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local du = x / 14 + y / 20 + ou
		local dv = x / 14 - y / 20 + ou
		local fu, fv = du % 1, dv % 1
		local m = qshade(lum)
		if math.abs(fu - 0.5) > 0.46 or math.abs(fv - 0.5) > 0.46 then
			return 215 * m, 212 * m, 205 * m -- lattice line
		end
		if ((du // 1) + (dv // 1)) % 2 == 0 then
			return 135 * m, 32 * m, 48 * m -- burgundy diamond
		end
		return 42 * m, 56 * m, 92 * m -- navy diamond
	end)
end

-- dragon: emerald scales in staggered rows with dark rims
function skinforge.dragonPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local SW, SH = 12, 9
	local ofs = math.floor(hash2(1, 1, seed) * SW)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local row = y // SH
		local shift = if row % 2 == 1 then SW / 2 else 0
		local gx = (x + shift + ofs) % SW - SW / 2
		local gy = y % SH
		-- distance from the scale's bottom-center: rings read as the
		-- overlapping arc of the scale above
		local d = math.sqrt(gx * gx + (SH - gy) * (SH - gy) * 0.85)
		local m = qshade(lum)
		if d > SW * 0.78 then
			return 18 * m, 55 * m, 30 * m -- rim shadow
		elseif d > SW * 0.62 then
			return 42 * m, 105 * m, 52 * m -- scale edge
		end
		return 72 * m, 165 * m, 82 * m -- emerald scale
	end)
end

-- lava: dark crust with molten cracks (ridged noise, warm ramp)
function skinforge.lavaPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local r1 = math.abs(valueNoise(x, y, 14, seed) * 2 - 1)
		local r2 = math.abs(valueNoise(x, y, 5, seed + 3) * 2 - 1)
		local ridge = r1 * 0.75 + r2 * 0.25
		local m = qshade(lum)
		if ridge < 0.06 then
			return 255 * m, 235 * m, 120 * m -- molten core
		elseif ridge < 0.16 then
			return 235 * m, 110 * m, 30 * m -- glow
		elseif ridge < 0.24 then
			return 120 * m, 45 * m, 22 * m -- hot rock
		end
		return 36 * m, 27 * m, 25 * m -- crust
	end)
end

-- ocean: noise-warped swells from navy to teal with foam crests
function skinforge.oceanPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local warp = valueNoise(x, y, 12, seed) * 18
		local t = 0.5 + 0.5 * math.sin((y * 0.9 + x * 0.25 + warp) * math.pi / 10)
		local m = qshade(lum)
		if t > 0.92 then
			return 235 * m, 245 * m, 250 * m -- foam crest
		end
		return (18 + 40 * t) * m, (60 + 110 * t) * m, (110 + 105 * t) * m
	end)
end

-- circuit board: PCB green, per-cell traces, gold pads
function skinforge.circuitPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local CELL = 12
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local cx, cy = x // CELL, y // CELL
		local fx, fy = x % CELL, y % CELL
		local m = qshade(lum)
		if hash2(cx, cy, seed + 5) > 0.6 and (fx - CELL / 2) ^ 2 + (fy - CELL / 2) ^ 2 <= 3 then
			return 220 * m, 180 * m, 70 * m -- gold pad
		end
		local dir = hash2(cx, cy, seed)
		local onTrace = if dir < 0.45
			then math.abs(fy - CELL / 2) < 1
			elseif dir < 0.9 then math.abs(fx - CELL / 2) < 1
			else false
		if onTrace then
			return 70 * m, 190 * m, 110 * m -- trace
		end
		return 18 * m, 78 * m, 46 * m -- solder mask
	end)
end

-- rust: the authentic skin survives where corrosion hasn't reached;
-- blotches eat in with rust bloom and dark pitting
function skinforge.rustPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum, br, bg, bb)
		local n = valueNoise(x, y, 9, seed) * 0.65 + valueNoise(x, y, 4, seed + 1) * 0.35
		if n < 0.52 then
			-- original paint, slightly darkened at the corrosion edge
			local edge = math.clamp((n - 0.42) * 6, 0, 1)
			local k = 1 - 0.3 * edge
			return br * k, bg * k, bb * k
		end
		local m = qshade(lum)
		if n > 0.68 then
			return 70 * m, 36 * m, 20 * m -- deep pit
		end
		return 172 * m, 92 * m, 40 * m -- rust bloom
	end)
end

-- galaxy: nebula clouds from deep blue to magenta, hashed star field
function skinforge.galaxyPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		local star = hash2(x, y, seed + 9)
		if star > 0.988 then
			return 250 * m, 250 * m, 255 * m -- bright star
		elseif star > 0.978 then
			return 175 * m, 185 * m, 228 * m -- dim star
		end
		local n = valueNoise(x, y, 15, seed) * 0.6 + valueNoise(x, y, 6, seed + 1) * 0.4
		local t = math.clamp((n - 0.35) * 2.2, 0, 1)
		return (25 + 115 * t) * m, (18 + 30 * t) * m, (62 + 110 * t) * m
	end)
end

-- honeycomb: amber hex cells with dark seams (offset-row hex distance)
function skinforge.honeycombPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local ofs = math.floor(hash2(1, 1, seed) * 12)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local row = y // 9
		local shift = if row % 2 == 1 then 6 else 0
		local gx = math.abs((x + shift + ofs) % 12 - 6)
		local gy = math.abs(y % 9 - 4.5)
		local d = math.max(gx * 0.9 + gy * 0.5, gy * 1.1)
		local m = qshade(lum)
		if d > 4.6 then
			return 118 * m, 76 * m, 26 * m -- seam
		end
		return 232 * m, 172 * m, 58 * m -- honey cell
	end)
end

-- tiger: orange coat, bold black stripes flowing mostly horizontally
function skinforge.tigerPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local warp = valueNoise(x, y, 11, seed) * 26 + valueNoise(x, y, 4, seed + 1) * 8
		local band = math.sin((x * 0.25 + y + warp) * math.pi / 11)
		local m = qshade(lum)
		if band > -0.45 then
			return 224 * m, 128 * m, 32 * m -- orange coat
		end
		return 26 * m, 21 * m, 18 * m -- stripe
	end)
end

-- snakeskin: small sand-colored scales, hashed dark diamond centers
function skinforge.snakeskinPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local SW, SH = 8, 6
	local ofs = math.floor(hash2(1, 1, seed) * SW)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local row = y // SH
		local shift = if row % 2 == 1 then SW / 2 else 0
		local gx = (x + shift + ofs) % SW - SW / 2
		local gy = y % SH
		local d = math.sqrt(gx * gx * 1.3 + (SH - gy) * (SH - gy) * 0.7)
		local m = qshade(lum)
		if d > SW * 0.7 then
			return 62 * m, 56 * m, 36 * m -- seam
		end
		if d < SW * 0.32 and hash2((x + shift + ofs) // SW, row, seed + 3) > 0.55 then
			return 52 * m, 46 * m, 26 * m -- dark diamond
		end
		return 190 * m, 170 * m, 112 * m -- sand scale
	end)
end

-- blueprint: drafting blue with minor/major grid lines
function skinforge.blueprintPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local G = 12
	local ofs = math.floor(hash2(1, 1, seed) * G)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		if (x + ofs) % (G * 4) < 1.5 or (y + ofs) % (G * 4) < 1.5 then
			return 235 * m, 240 * m, 245 * m -- major line
		end
		if (x + ofs) % G < 1 or (y + ofs) % G < 1 then
			return 148 * m, 178 * m, 214 * m -- minor line
		end
		return 26 * m, 72 * m, 142 * m -- drafting blue
	end)
end

-- glitch: TV static with shifted, chroma-tinted tear bands
function skinforge.glitchPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local band = y // 4
		local tear = hash2(1, band, seed)
		local xx = x
		local tint = 0
		if tear > 0.9 then
			xx = x + math.floor((tear - 0.9) * 250)
			tint = if hash2(2, band, seed) > 0.5 then 1 else 2
		end
		local g = 40 + hash2(xx, y, seed + 7) * 190
		local m = qshade(lum)
		if tint == 1 then
			return g * 0.4 * m, g * m, g * m -- cyan tear
		elseif tint == 2 then
			return g * m, g * 0.4 * m, g * m -- magenta tear
		end
		return g * m, g * m, g * m
	end)
end

-- wood grain: warped vertical bands in warm browns
function skinforge.woodPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local warp = valueNoise(x, y, 9, seed) * 14
		local t = 0.5 + 0.5 * math.sin((x + warp) * math.pi / 6)
		local streak = (valueNoise(x, y, 5, seed + 2) - 0.5) * 0.3
		local v = math.clamp(t + streak, 0, 1)
		local m = qshade(lum)
		return (115 + 65 * v) * m, (72 + 42 * v) * m, (36 + 22 * v) * m
	end)
end

-- candy cane: hard diagonal red/white stripes
function skinforge.candycanePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local P = 14
	local ofs = math.floor(hash2(1, 1, seed) * P)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		if (x + y + ofs) % P < P / 2 then
			return 218 * m, 40 * m, 52 * m -- red
		end
		return 240 * m, 238 * m, 235 * m -- white
	end)
end

-- hazard stripes: black/yellow chevrons
function skinforge.hazardPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	local P = 16
	local ofs = math.floor(hash2(1, 1, seed) * P)
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		if (x + y + ofs) % P < P / 2 then
			return 235 * m, 196 * m, 40 * m -- yellow
		end
		return 30 * m, 28 * m, 26 * m -- black
	end)
end

-- oil slick: iridescent film, RGB phases cycling through noise
function skinforge.oilslickPixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local ph = (valueNoise(x, y, 12, seed) * 2 + valueNoise(x, y, 5, seed + 1)) * math.pi * 2
		local m = qshade(lum)
		local r = 90 + 80 * math.sin(ph)
		local g = 90 + 80 * math.sin(ph + 2.094)
		local b = 90 + 80 * math.sin(ph + 4.189)
		return r * m, g * m, b * m
	end)
end

-- mossy stone: the granite base with green growth in noise pockets
function skinforge.mossystonePixels(basePixels: buffer, w: number, h: number, pal: Palette, seed: number): buffer
	return paint(basePixels, w, h, pal, function(x, y, lum)
		local m = qshade(lum)
		local moss = valueNoise(x, y, 7, seed + 11) * 0.7 + valueNoise(x, y, 3, seed + 12) * 0.3
		if moss > 0.58 then
			local g = math.min(90 + (moss - 0.58) * 320, 165)
			return 42 * m, g * m, 40 * m -- moss
		end
		local n = valueNoise(x, y, 9, seed) * 0.6 + valueNoise(x, y, 3, seed + 1) * 0.4
		local g = 125 + (n - 0.5) * 70
		local speck = hash2(x, y, seed + 9)
		if speck > 0.97 then
			g += 40
		elseif speck < 0.03 then
			g -= 40
		end
		return g * m, g * m, (g + 6) * m
	end)
end

GENERATORS.camo = { fn = skinforge.camoPixels }
GENERATORS.zebra = { fn = skinforge.zebraPixels }
GENERATORS.lightning = { fn = skinforge.lightningPixels }
GENERATORS.leopard = { fn = skinforge.leopardPixels }
GENERATORS.cottoncandy = { fn = skinforge.cottoncandyPixels }
GENERATORS.tortoise = { fn = skinforge.tortoisePixels }
GENERATORS.matteblack = { fn = skinforge.matteblackPixels }
GENERATORS.ghostwhite = { fn = skinforge.ghostwhitePixels }
GENERATORS.deeppurple = { fn = skinforge.deeppurplePixels }
GENERATORS.grass = { fn = skinforge.grassPixels }
GENERATORS.clouds = { fn = skinforge.cloudsPixels }
GENERATORS.stone = { fn = skinforge.stonePixels }
GENERATORS.herringbone = { fn = skinforge.herringbonePixels }
GENERATORS.checkered = { fn = skinforge.checkeredPixels }
GENERATORS.pinstripe = { fn = skinforge.pinstripePixels }
GENERATORS.argyle = { fn = skinforge.argylePixels }
GENERATORS.dragon = { fn = skinforge.dragonPixels }
GENERATORS.lava = { fn = skinforge.lavaPixels }
GENERATORS.ocean = { fn = skinforge.oceanPixels }
GENERATORS.circuit = { fn = skinforge.circuitPixels }
GENERATORS.rust = { fn = skinforge.rustPixels }
GENERATORS.galaxy = { fn = skinforge.galaxyPixels }
GENERATORS.honeycomb = { fn = skinforge.honeycombPixels }
GENERATORS.tiger = { fn = skinforge.tigerPixels }
GENERATORS.snakeskin = { fn = skinforge.snakeskinPixels }
GENERATORS.blueprint = { fn = skinforge.blueprintPixels }
GENERATORS.glitch = { fn = skinforge.glitchPixels }
GENERATORS.wood = { fn = skinforge.woodPixels }
GENERATORS.candycane = { fn = skinforge.candycanePixels }
GENERATORS.hazard = { fn = skinforge.hazardPixels }
GENERATORS.oilslick = { fn = skinforge.oilslickPixels }
GENERATORS.mossystone = { fn = skinforge.mossystonePixels }

-- sorted generator keys (menus, tests)
function skinforge.kinds(): { string }
	local out = {}
	for k in GENERATORS do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- recipe dispatch: RGBA8 pixels for a base skin (pure)
function skinforge.generatePixels(recipe: Recipe, basePixels: buffer, w: number, h: number, pal: Palette): buffer
	return GENERATORS[recipe.kind].fn(basePixels, w, h, pal, recipe.seed)
end

-- spec string -> EditableImage (nil when the spec is unknown, the Mesh &
-- Image APIs are disabled, or the image budget is exhausted)
function skinforge.createImage(spec: string, basePixels: buffer, w: number, h: number, pal: Palette): EditableImage?
	local recipe = skinforge.parse(spec)
	if not recipe then
		return nil
	end
	local rgba = skinforge.generatePixels(recipe, basePixels, w, h, pal)
	local ok, img = pcall(function(): EditableImage?
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		if not image then
			return nil -- budget exhausted (returns nil, no throw)
		end
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), rgba)
		return image
	end)
	if not ok then
		return nil
	end
	return img
end

return skinforge
