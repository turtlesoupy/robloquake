--!strict
--!optimize 2
-- Exclusive slot for editable-mesh build attempts (worldmesh chunks +
-- entrender alias builds): at most ONE scratch dynamic EditableMesh is
-- alive at any moment, and queued builds drip one per Heartbeat so the
-- engine reclaims freed budget between them.
--
-- Why: the async mesh APIs yield, so a build that spans frames lets the
-- next Heartbeat re-enter the render loop and start more builds —
-- sighting-bursts ran several builds concurrently, each holding a scratch
-- dynamic EM (a 60k-vertex reservation), transiently filling the editable
-- memory budget. That margin is where fixed copies fail and EditableImages
-- zombie (GPU upload silently refused → black textures). Serializing the
-- scratch window removes the transient saturation at its source.

-- runs under both Roblox (global task) and lune (offline tests)
local task = task or (require)("@lune/task") :: any

-- lune has no `game`; the drip then falls back to task.defer
local gotRun, runSvc = pcall(function()
	return game:GetService("RunService")
end)
local RunService = (if gotRun then runSvc else nil) :: RunService?

local buildqueue = {}

local busy = false
local waiters: { thread } = {}
local handoffScheduled = false

local function handoff()
	local waiter = table.remove(waiters, 1)
	if waiter then
		task.spawn(waiter) -- resumes acquire()'s yield; the slot stays claimed
	else
		busy = false
	end
end

local function scheduleHandoff()
	if handoffScheduled then
		return
	end
	handoffScheduled = true
	task.defer(function()
		-- one queued build per Heartbeat: destroyed fixed-mesh budget is
		-- reclaimed asynchronously, so back-to-back builds in the same
		-- frame still see the previous build's pressure
		if RunService then
			RunService.Heartbeat:Wait()
		end
		handoffScheduled = false
		handoff()
	end)
end

local function acquire()
	if not busy then
		busy = true
		return
	end
	table.insert(waiters, coroutine.running())
	coroutine.yield()
end

local function release()
	if #waiters > 0 then
		-- busy stays true: the slot passes straight to the next waiter
		scheduleHandoff()
	else
		busy = false
	end
end

-- Run fn while holding the exclusive build slot. fn may yield (the async
-- mesh APIs do); errors release the slot and re-raise.
function buildqueue.run<T>(fn: () -> T): T
	acquire()
	local ok, result = pcall(fn)
	release()
	if not ok then
		error(result, 0)
	end
	return result :: T
end

return buildqueue
