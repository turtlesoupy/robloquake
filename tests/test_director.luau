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

t.finish("director")
