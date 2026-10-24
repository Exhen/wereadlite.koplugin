--[[--
Cooperative time slicing for CPU-heavy background work (chapter prefetch).

Everything here runs on KOReader's single UI thread, so one long Lua loop freezes
page turns for its whole duration.  Work run through Slice.run is executed in a
coroutine that yields back to the UI loop whenever its CPU budget is used up, and
is resumed on a later tick.  Heavy loops only need to call Slice.point() from time
to time; outside Slice.run (e.g. a foreground load) it does nothing.
]]

local unpack = table.unpack or unpack
local pack = table.pack or function(...)
    return { n = select("#", ...), ... }
end

local Slice = {
    -- CPU seconds a slice may use before it yields to the UI loop.
    BUDGET = 0.008,
    -- Idle seconds left between two slices of a low priority job.
    GAP = 0.016,
    -- Budget for jobs somebody is waiting on; no idle gap.
    FAST_BUDGET = 0.04,
}

local current
local deadline = 0

--- Yield to the UI loop when the running slice has used up its budget.
function Slice.point()
    if current and current == coroutine.running() and os.clock() >= deadline then
        coroutine.yield()
    end
end

--- Run `compute` across as many UI ticks as needed, then call done(ok, ...).
-- `compute` must be pure CPU work: it runs inside a coroutine and may be abandoned
-- (cancelled) between slices.  `done` always runs outside the coroutine, on a later
-- tick than this call.
-- opts.cancelled() -> true stops the job silently; opts.fast() -> true while somebody
-- waits for the result (bigger slices, no idle gap).
function Slice.run(compute, done, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local co = coroutine.create(compute)
    local function pace()
        if opts.fast and opts.fast() then
            return Slice.FAST_BUDGET, 0
        end
        return opts.budget or Slice.BUDGET, opts.gap or Slice.GAP
    end
    local step
    local function schedule(gap)
        if gap > 0 then
            UIManager:scheduleIn(gap, step)
        else
            UIManager:nextTick(step)
        end
    end
    step = function()
        if opts.cancelled and opts.cancelled() then
            return
        end
        local budget, gap = pace()
        local outer, outer_deadline = current, deadline
        current, deadline = co, os.clock() + budget
        local results = pack(coroutine.resume(co))
        current, deadline = outer, outer_deadline
        if not results[1] then
            done(false, debug.traceback(co, tostring(results[2])))
        elseif coroutine.status(co) == "dead" then
            done(true, unpack(results, 2, results.n))
        else
            schedule(gap)
        end
    end
    local _, gap = pace()
    schedule(gap)
end

return Slice
