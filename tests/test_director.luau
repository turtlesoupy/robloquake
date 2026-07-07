--!strict
-- Match director pure logic: rotation, vote candidates, tally, winner.

local t = require("./testutil")
local director = require("../src/server/director")

-- parseMaplist
t.eq(#director.parseMaplist(nil), 0, "nil maplist -> empty")
t.eq(#director.parseMaplist(""), 0, "empty maplist -> empty")
local list = director.parseMaplist("dm3 dm4  dm6\tdm2")
t.eq(#list, 4, "maplist splits on whitespace")
t.eq(list[3], "dm6", "maplist order kept")

-- mapLabel: sanitized title + codename
t.eq(director.mapLabel("lqdm1", "Solstice"), "Solstice (lqdm1)", "clean title keeps codename")
t.eq(director.mapLabel("lqdm2", "Torture Pit"), "Grotto (lqdm2)", "unsuitable title overridden")
t.eq(director.mapLabel("lqdm10", "Lucifer's Gambit"), "Midnight Gambit (lqdm10)", "occult title overridden")
t.eq(director.mapLabel("lqdm13", "Death Provides No Return"), "No Way Back (lqdm13)", "dark title overridden")
t.eq(director.mapLabel("lqdm5", nil), "lqdm5", "no title -> just codename")
t.eq(director.mapLabel("lqdm5", ""), "lqdm5", "empty title -> just codename")

-- rotationNext
t.eq(director.rotationNext(list, "dm3"), "dm4", "rotation successor")
t.eq(director.rotationNext(list, "dm2"), "dm3", "rotation wraps")
t.eq(director.rotationNext(list, "e1m1"), "dm3", "unknown current -> first")
t.eq(director.rotationNext({}, "dm3"), nil, "empty list -> nil")

-- candidates
local c = director.candidates(list, "dm3", 3)
t.eq(#c, 3, "three candidates")
t.eq(c[1], "dm4", "candidates start at rotation successor")
t.eq(c[2], "dm6", "candidates follow rotation order")
t.eq(c[3], "dm2", "candidates wrap past the end")
t.eq(table.find(c, "dm3"), nil, "current map excluded")
local short = director.candidates({ "dm3", "dm4" }, "dm3", 3)
t.eq(#short, 1, "short lists yield fewer candidates, no dupes")
local dup = director.candidates({ "dm3", "dm4", "dm4", "dm6" }, "dm3", 3)
t.eq(#dup, 2, "duplicate maplist entries collapse")

-- tally
local counts = director.tally({ a = 1, b = 3, c = 3, d = 99 }, 3)
t.eq(counts[1], 1, "tally counts index 1")
t.eq(counts[2], 0, "tally zero for unvoted")
t.eq(counts[3], 2, "tally counts index 3")
-- index 99 out of range ignored

-- winner
t.eq(director.winner(c, { 0, 2, 1 }, "fb"), "dm6", "most votes wins")
t.eq(director.winner(c, { 1, 1, 1 }, "fb"), "dm4", "tie breaks toward rotation order")
t.eq(director.winner(c, { 0, 0, 0 }, "fb"), "fb", "zero votes -> fallback")
t.eq(director.winner({}, {}, nil), nil, "no candidates, no fallback -> nil")

-- callvote: proposal validation against the VOTABLE view layer
local ml = director.parseMaplist("dm3 dm4 dm6")
local p1, e1 = director.validateProposal(ml, "map", "dm4")
t.eq(e1, nil, "rotation map proposal accepted")
t.eq((p1 :: any).kind, "map", "map proposal kind")
t.eq((p1 :: any).desc, "map dm4", "map proposal desc")
local p2, e2 = director.validateProposal(ml, "map", "e1m1")
t.eq(p2, nil, "off-rotation map rejected")
t.eq(e2 ~= nil, true, "off-rotation map has a reason")
t.eq((director.validateProposal(ml, "map", "dm4; rm -rf")), nil, "map name pattern enforced")
local p3 = director.validateProposal(ml, "fraglimit", "30")
t.eq((p3 :: any).value, 30, "rule proposal coerces number")
t.eq((p3 :: any).desc, "fraglimit 30", "rule proposal desc")
t.eq((director.validateProposal(ml, "fraglimit", 1000)), nil, "rule out of range rejected")
t.eq((director.validateProposal(ml, "fraglimit", 2)), nil, "rule below floor rejected")
local p4 = director.validateProposal(ml, "roblox_avatars", false)
t.eq((p4 :: any).desc, "roblox_avatars off", "toggle proposal desc")
t.eq((director.validateProposal(ml, "roblox_avatars", "yes")), nil, "toggle requires boolean")
t.eq((director.validateProposal(ml, "deathmatch", 0)), nil, "game-defining rule not votable")
t.eq((director.validateProposal(ml, nil, 1)), nil, "nil key rejected")

-- callvote: early decision against present players
t.eq(director.cvDecided(2, 0, 3), "pass", "strict majority of present passes early")
t.eq(director.cvDecided(1, 0, 3), nil, "half is not enough to pass early")
t.eq(director.cvDecided(1, 2, 4), "fail", "no reaching half fails early")
t.eq(director.cvDecided(0, 0, 4), nil, "no votes yet -> undecided")
t.eq(director.cvDecided(1, 0, 1), "pass", "lone player passes own vote")
t.eq(director.cvDecided(2, 2, 4), "fail", "even split fails early (majority impossible)")

-- callvote: expiry decided by votes cast
t.eq(director.cvExpired(2, 1), true, "majority of cast passes at expiry")
t.eq(director.cvExpired(1, 1), false, "tie fails at expiry")
t.eq(director.cvExpired(0, 0), false, "zero participation fails at expiry")
t.eq(director.cvExpired(1, 0), true, "single yes passes at expiry")

t.finish("director")
