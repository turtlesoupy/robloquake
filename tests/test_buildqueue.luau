--!strict
-- buildqueue: the exclusive editable-mesh build slot (black-texture root
-- cause, 2026-07-05). Serialization is the contract: at most one build
-- attempt (scratch dynamic EditableMesh window) runs at a time, waiters
-- run FIFO, results and errors pass through, and an error still releases
-- the slot.
local t = require("./testutil")
local task = require("@lune/task")
local buildqueue = require("../src/client/render/buildqueue")

local active = 0
local maxActive = 0
local order: { number } = {}
local done = 0

for i = 1, 5 do
	task.spawn(function()
		local r = buildqueue.run(function()
			active += 1
			maxActive = math.max(maxActive, active)
			task.wait(0.02) -- span "frames" like the async mesh APIs
			active -= 1
			table.insert(order, i)
			return i * 10
		end)
		t.eq(r, i * 10, `run() returns the builder's result ({i})`)
		done += 1
	end)
end
while done < 5 do
	task.wait(0.01)
end

t.eq(maxActive, 1, "at most one build holds the slot")
t.eq(#order, 5, "every queued build ran")
t.eq(table.concat(order, ","), "1,2,3,4,5", "waiters run FIFO")

-- an error inside the builder re-raises but releases the slot
local ok, err = pcall(function()
	return buildqueue.run(function()
		error("boom", 0)
	end)
end)
t.check(not ok, "builder errors propagate to the caller")
t.eq(err, "boom", "error message passes through")

local ranAfter = false
buildqueue.run(function()
	ranAfter = true
end)
t.check(ranAfter, "slot is free again after an error")

-- idleFor: 0 while a build holds the slot, grows once fully idle
local during = -1
task.spawn(function()
	buildqueue.run(function()
		during = buildqueue.idleFor()
		task.wait(0.02)
	end)
end)
task.wait(0.05)
t.eq(during, 0, "idleFor is 0 while a build runs")
t.check(buildqueue.idleFor() > 0, "idleFor grows once the queue is idle")

t.finish("test_buildqueue")
