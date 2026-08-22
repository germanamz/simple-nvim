-- Buffer-freshness guard for minuet's FIM completions.
--
-- THE BUG. minuet's virtualtext frontend paints a completion without ever
-- checking that the buffer still matches the one the request was built from.
-- `trigger()` stamps `internal.current_completion_timestamp` and its callback
-- (virtualtext.lua:252) compares only that stamp — i.e. "was I superseded by a
-- NEWER request?", never "did the buffer change under me?". `update_preview`
-- then anchors the extmark at the LIVE cursor (virtualtext.lua:166-167, written
-- at :189). So a completion computed for `    retu` is drawn at column 10 of a
-- line that now reads `    return`, and the screen shows `    returnrn a - b`.
--
-- minuet's own newer frontend does the check we are adding here — see
-- duet/init.lua:73, which compares `utils.get_changedtick(bufnr)` against the
-- request's context and discards on mismatch. virtualtext.lua has no equivalent.
--
-- WHY THE STAMP GUARD NEVER SAVES US. `current_completion_timestamp` is written
-- in exactly one place (virtualtext.lua:249, inside `trigger()`), and `schedule()`
-- cannot fire a second trigger sooner than `throttle + debounce`. So the stamp
-- guard can only reject a response whose round trip EXCEEDS that sum. Measured
-- against this config's local Ollama the round trip is bimodal — median 433ms,
-- p90 1058ms, max 1572ms — so against stock 1000+400 the guard is unreachable for
-- ~96% of requests. Not unlucky: structurally unreachable. lua/plugins/minuet.lua
-- drops `throttle` to 0 for the second half of the fix; see the note there.
--
-- ESC MID-FLIGHT. minuet's `cleanup()` (virtualtext.lua:199-204) never resets
-- `current_completion_timestamp`, so a request still in flight when you leave
-- insert mode passes the stamp guard and writes into `ctx`. Comparing mode
-- families closes that from the config side.
--
-- COUPLING. This wraps `minuet.backends.openai_fim_compatible.complete`, for
-- which upstream offers no stability contract: a rename upstream silently
-- disables the guard rather than erroring. `install()` returns false in that case
-- and lua/plugins/minuet.lua surfaces it as a warning; tests/spec/unit/
-- minuet_guard_spec.lua pins the behaviour. Unreported upstream as of 2026-08-22
-- (`git log -S'is_on_throttle' --all` finds one commit, 223b639 of 2024-12-14, and
-- `schedule()` is byte-identical from there through tip), so upgrading the pin
-- does not remove the need for this.

local M = {}

-- Insert/replace collapse to one family: leaving insert at all invalidates a
-- completion, and headless specs (which can never genuinely enter insert) still
-- get a comparable value out of this.
local function mode_family()
  return vim.fn.mode():match("^[iR]") and "i" or "n"
end

-- State a completion request was built against. Cheap enough to take per request.
function M.snapshot()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  return {
    win = win,
    buf = buf,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    row = ok and cursor[1] or nil,
    col = ok and cursor[2] or nil,
    mode = mode_family(),
  }
end

-- True only when every axis the render depends on is still exactly as it was.
-- Deliberately strict: a dropped suggestion costs one keystroke's wait, while a
-- painted stale one corrupts what the user is reading.
function M.is_fresh(snap)
  if type(snap) ~= "table" then
    return false
  end
  if not (snap.buf and vim.api.nvim_buf_is_valid(snap.buf)) then
    return false
  end
  if snap.buf ~= vim.api.nvim_get_current_buf() then
    return false
  end
  if not (snap.win and vim.api.nvim_win_is_valid(snap.win)) then
    return false
  end
  if snap.win ~= vim.api.nvim_get_current_win() then
    return false
  end
  if vim.api.nvim_buf_get_changedtick(snap.buf) ~= snap.tick then
    return false
  end
  if snap.mode ~= mode_family() then
    return false
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, snap.win)
  if not ok then
    return false
  end
  return cursor[1] == snap.row and cursor[2] == snap.col
end

-- Wrap the FIM backend so stale and empty responses never reach minuet's
-- update_preview. Idempotent: `:Lazy reload minuet-ai.nvim` re-runs the plugin's
-- config(), and double-wrapping would stack a second snapshot per request.
-- Returns true when it wrapped, false when there was nothing to wrap.
function M.install()
  local ok, fim = pcall(require, "minuet.backends.openai_fim_compatible")
  if not ok or type(fim) ~= "table" or type(fim.complete) ~= "function" then
    return false
  end
  if fim.__stale_guard then
    return false
  end

  local inner = fim.complete

  fim.complete = function(context, callback)
    local snap = M.snapshot()
    return inner(context, function(data)
      -- Empty payload: minuet's `if next(data)` at virtualtext.lua:263 covers
      -- only the assignment, while update_preview at :271 runs unconditionally —
      -- so forwarding this would repaint the PREVIOUS request's suggestion, which
      -- is the "an older response replaced the newer one" report. Dismiss instead.
      -- Empty is routine here, not exotic: utils.lua:564 rejects a stop-token hit
      -- that produced no text, utils.lua:372 drops whitespace-only items, and the
      -- FIM_STOP list includes <|endoftext|>, which a base model emits the moment
      -- a statement is complete.
      if not (data and next(data)) then
        pcall(function()
          require("minuet.virtualtext").action.dismiss()
        end)
        return
      end
      -- Stale: drop by RETURNING, never by calling back with {} — that would land
      -- on the same :271 path and manufacture the bug above. Nothing leaks; by
      -- this point the job is already out of `current_jobs` and
      -- MinuetRequestFinished has fired.
      if not M.is_fresh(snap) then
        return
      end
      callback(data)
    end)
  end

  fim.__stale_guard = true
  return true
end

return M
