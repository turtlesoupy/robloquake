--!strict
-- Mode presets: every key used must be in the canonical KEYS set, and
-- structural invariants that keep boots sane.

local t = require("./testutil")
local modepresets = require("../src/server/modepresets")

local keySet: { [string]: boolean } = {}
for _, k in modepresets.KEYS do
	keySet[k] = true
end

local count = 0
for name, preset in modepresets.PRESETS :: { [string]: { [string]: any } } do
	count += 1
	for key in preset do
		t.check(keySet[key] == true, `{name}: key "{key}" is in KEYS`)
	end
	local engine = preset.engine
	t.check(engine == "nq" or engine == "qw", `{name}: engine valid`)
	t.check(typeof(preset.startmap) == "string", `{name}: has a startmap`)
	if preset.maplist ~= nil then
		t.check(typeof(preset.maplist) == "string" and preset.maplist ~= "", `{name}: maplist non-empty when set`)
	end
	if name == "arena" then
		t.check(preset.maplist == nil, "arena leaves rotation to the mod (localinfo)")
	end
end
t.check(count >= 5, "expected preset catalog present")
t.check(modepresets.PRESETS["campaign"].deathmatch == nil, "campaign has no deathmatch")
t.check(modepresets.PRESETS["campaign"].maplist == nil, "campaign has no maplist (authentic exit chain)")

-- modifiers: every key must be canonical, and resolve composes them
-- over any preset
for name, mod in modepresets.MODIFIERS :: { [string]: { [string]: any } } do
	for key in mod do
		t.check(keySet[key] == true, `modifier {name}: key "{key}" is in KEYS`)
	end
end
t.check(modepresets.MODIFIERS.original.mildmode == false, "original modifier opts out of mildmode")

local plain = modepresets.resolve("qw-dm") :: { [string]: any }
t.check(plain ~= nil and plain.mildmode == nil, "qw-dm resolves with mildmode absent (default-on mirror)")
local original = modepresets.resolve("qw-dm+original") :: { [string]: any }
t.check(original ~= nil and original.mildmode == false, "qw-dm+original resolves with mildmode=false")
t.check(original.engine == "qw" and original.maplist == plain.maplist, "modifier keeps the base preset intact")
local coriginal = modepresets.resolve("campaign+original") :: { [string]: any }
t.check(coriginal ~= nil and coriginal.mildmode == false, "modifiers compose over any preset")
t.check(modepresets.resolve("qw-dm+nope") == nil, "unknown modifier resolves nil")
t.check(modepresets.resolve("nope+original") == nil, "unknown preset resolves nil")

t.finish("modepresets")
