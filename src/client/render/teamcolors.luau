--!strict
-- Team/identity colors (product layer, shared by the pause-menu picker,
-- the avatar rig tints, and every HUD shirt/pants bar). Quake keyed these
-- off palette translation rows, but the shipped LibreQuake palette's rows
-- are too muddy to signal identity (its brightest RED is (127,0,0), its
-- GREEN a grey sage) — playtests read the bars as "wrong colors". So the
-- 14 rows map to hand-picked vivid, name-true display colors instead;
-- the wire/prefs value stays the classic 0..13 row (and the packed
-- top*16+bottom byte), so nothing off the display path changes.

local teamcolors = {}

-- picker labels for rows 0..13 (1-based table)
teamcolors.NAMES = {
	"WHITE", "BROWN", "LAVENDER", "KHAKI", "RED", "OLIVE", "ORANGE",
	"PEACH", "PURPLE", "MAGENTA", "TAN", "GREEN", "YELLOW", "BLUE",
}

-- vivid, mutually distinguishable, true to the classic row names
local COLORS: { Color3 } = {
	Color3.fromRGB(235, 235, 235), -- WHITE
	Color3.fromRGB(141, 92, 45), -- BROWN
	Color3.fromRGB(159, 159, 223), -- LAVENDER
	Color3.fromRGB(171, 163, 108), -- KHAKI
	Color3.fromRGB(217, 42, 32), -- RED
	Color3.fromRGB(126, 125, 34), -- OLIVE
	Color3.fromRGB(235, 131, 30), -- ORANGE
	Color3.fromRGB(240, 181, 141), -- PEACH
	Color3.fromRGB(134, 62, 165), -- PURPLE
	Color3.fromRGB(205, 63, 152), -- MAGENTA
	Color3.fromRGB(202, 165, 121), -- TAN
	Color3.fromRGB(60, 172, 71), -- GREEN
	Color3.fromRGB(240, 214, 34), -- YELLOW
	Color3.fromRGB(53, 82, 222), -- BLUE
}

-- display color for a picker/translation row 0..13
function teamcolors.forRow(row: number): Color3
	return COLORS[math.clamp(math.floor(row), 0, 13) + 1]
end

-- display colors for the wire's packed colors byte (top*16 + bottom)
function teamcolors.shirt(colors: number): Color3
	return teamcolors.forRow(bit32.rshift(bit32.band(colors, 0xf0), 4))
end

function teamcolors.pants(colors: number): Color3
	return teamcolors.forRow(bit32.band(colors, 15))
end

return teamcolors
