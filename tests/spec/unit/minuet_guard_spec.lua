-- config.minuet_guard drops FIM completions that came back after the buffer moved
-- on under them. minuet's virtualtext frontend guards only on request identity
-- (virtualtext.lua:252 compares its own timestamp) and never on buffer freshness,
-- while update_preview anchors the extmark at the LIVE cursor — so a completion
-- computed for `    retu` gets painted at col 10 of `    return`. Its own newer
-- frontend does check (duet/init.lua:73); virtualtext has no equivalent.
--
-- These specs pin the predicate and the wrapper. Unit init loads no plugins, so
-- the backend module is stubbed via package.loaded.
local guard = require("config.minuet_guard")

describe("config.minuet_guard.is_fresh", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1", "local y = 2" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("is fresh when nothing moved", function()
    assert.is_true(guard.is_fresh(guard.snapshot()))
  end)

  it("is stale once the buffer text changed (the returnrn a - b case)", function()
    local snap = guard.snapshot()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local x = 12" })
    assert.is_false(guard.is_fresh(snap))
  end)

  it("is stale once the cursor moved, even with identical text", function()
    local snap = guard.snapshot()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_false(guard.is_fresh(snap))
  end)

  it("is stale once another buffer is current", function()
    local snap = guard.snapshot()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    assert.is_false(guard.is_fresh(snap))
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("is stale once the snapshot's buffer is gone", function()
    local snap = guard.snapshot()
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(guard.is_fresh(snap))
  end)

  -- The Esc-mid-flight path. minuet's cleanup() never resets
  -- current_completion_timestamp, so a request in flight when you leave insert
  -- still passes its guard and writes into ctx; comparing mode families closes
  -- that from the config side.
  it("is stale once insert mode was left", function()
    local snap = guard.snapshot()
    snap.mode = "i" -- forged: headless specs cannot genuinely enter insert
    assert.is_false(guard.is_fresh(snap))
  end)

  it("tolerates a snapshot taken for a window that has since closed", function()
    local snap = guard.snapshot()
    snap.win = 99999
    assert.is_false(guard.is_fresh(snap))
  end)
end)

-- The guard only stops a stale suggestion being PAINTED. Without the pacing
-- below, minuet still drops the keystrokes that would have corrected it
-- (virtualtext.lua:288-292), so the user gets silence instead. Both halves ship
-- together or the fix is worse than the bug; this pins the half that lives in the
-- plugin spec.
describe("plugins.minuet pacing", function()
  local captured, real_minuet

  before_each(function()
    captured = nil
    real_minuet = package.loaded["minuet"]
    package.loaded["minuet"] = {
      setup = function(opts)
        captured = opts
      end,
      config = {},
    }
    package.loaded["minuet.backends.openai_fim_compatible"] = {
      complete = function() end,
    }
    package.loaded["plugins.minuet"] = nil
  end)

  after_each(function()
    package.loaded["minuet"] = real_minuet
    package.loaded["minuet.backends.openai_fim_compatible"] = nil
    package.loaded["plugins.minuet"] = nil
    pcall(vim.api.nvim_del_user_command, "AIModel")
  end)

  local function opts()
    require("plugins.minuet").config()
    assert.is_truthy(captured, "config() did not call minuet.setup")
    return captured
  end

  it("leaves no throttle window for keystrokes to fall into", function()
    assert.are.equal(0, opts().throttle)
  end)

  it("keeps the debounce well under the measured round-trip median (433ms)", function()
    local debounce = opts().debounce
    assert.are.equal("number", type(debounce))
    assert.is_true(debounce > 0, "0 would fire a request per keystroke")
    assert.is_true(debounce < 400, "at/above the round trip the stale window reopens")
  end)
end)

describe("config.minuet_guard.install", function()
  local real_backend, real_vt
  local seen, dismissed, ctx_seen

  before_each(function()
    seen, dismissed, ctx_seen = nil, 0, nil
    real_backend = package.loaded["minuet.backends.openai_fim_compatible"]
    real_vt = package.loaded["minuet.virtualtext"]
    package.loaded["minuet.backends.openai_fim_compatible"] = {
      complete = function(context, cb)
        ctx_seen = context
        seen = cb
      end,
    }
    package.loaded["minuet.virtualtext"] = {
      action = {
        dismiss = function()
          dismissed = dismissed + 1
        end,
      },
    }
  end)

  after_each(function()
    package.loaded["minuet.backends.openai_fim_compatible"] = real_backend
    package.loaded["minuet.virtualtext"] = real_vt
  end)

  local function backend()
    return package.loaded["minuet.backends.openai_fim_compatible"]
  end

  it("marks the backend so a reload cannot double-wrap it", function()
    assert.is_true(guard.install())
    assert.is_true(backend().__stale_guard)
    local wrapped = backend().complete
    assert.is_false(guard.install(), "second install must be a no-op")
    assert.are.equal(wrapped, backend().complete)
  end)

  it("reports failure rather than erroring when the backend module is absent", function()
    package.loaded["minuet.backends.openai_fim_compatible"] = nil
    assert.is_false(guard.install())
  end)

  it("forwards a fresh, non-empty completion", function()
    guard.install()
    local got
    backend().complete({}, function(data)
      got = data
    end)
    seen({ "rn a - b" })
    assert.are.same({ "rn a - b" }, got)
    assert.are.equal(0, dismissed)
  end)

  -- Defect A: the response must not be painted against a buffer it no longer fits.
  it("drops a completion whose buffer changed in flight", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "    retu" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })

    guard.install()
    local got = "untouched"
    backend().complete({}, function(data)
      got = data
    end)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "    return" })
    seen({ "rn a - b" })

    assert.are.equal("untouched", got, "stale completion must never reach the callback")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Defect C: an empty payload must not fall through to minuet's update_preview,
  -- which sits outside the `if next(data)` guard (virtualtext.lua:271) and would
  -- repaint the PREVIOUS request's text.
  it("dismisses instead of forwarding an empty completion", function()
    guard.install()
    local called = false
    backend().complete({}, function()
      called = true
    end)
    seen({})
    assert.is_false(called, "empty data must not reach minuet's update_preview")
    assert.are.equal(1, dismissed)
  end)

  it("never forwards an empty completion even when the buffer is stale", function()
    guard.install()
    local called = false
    backend().complete({}, function()
      called = true
    end)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    seen(nil)
    assert.is_false(called)
  end)

  it("passes the caller's context through untouched", function()
    guard.install()
    backend().complete({ prefix = "abc" }, function() end)
    assert.are.same({ prefix = "abc" }, ctx_seen)
  end)
end)
