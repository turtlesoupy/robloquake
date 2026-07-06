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

t.finish("modepresets")
