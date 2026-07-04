-- Bounded-concurrency task pool for async fan-out. Generic (knows nothing
-- about git or pickers); shared by config.telescope_smart's per-submodule
-- status recursion and config.ignore_filter's check-ignore oracle.
local M = {}

-- The shared bound on concurrent git processes a superproject fan-out may
-- spawn, so hundreds of submodules can't fork-bomb the machine.
M.GIT_CONCURRENCY = 8

-- Run worker(item, done) over `items` with at most `limit` in flight, calling
-- on_complete after the last done(). Workers run asynchronously (vim.system)
-- and MUST call done() exactly once.
function M.run(items, limit, worker, on_complete)
  local n = #items
  if n == 0 then
    return on_complete()
  end
  local idx, active, finished = 0, 0, 0
  local function pump()
    while active < limit and idx < n do
      idx = idx + 1
      active = active + 1
      worker(items[idx], function()
        active = active - 1
        finished = finished + 1
        if finished == n then
          on_complete()
        else
          pump()
        end
      end)
    end
  end
  pump()
end

return M
