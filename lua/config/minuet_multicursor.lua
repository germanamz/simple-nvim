-- Makes an accepted AI suggestion reach every multicursor cursor.
--
-- THE BUG. With several cursors alive, accepting a minuet suggestion put the
-- text at the main cursor only, and pressing `<Esc>` never brought the other
-- cursors into line.
--
-- WHY. multicursor replicates an insert to the other cursors by REPLAYING it,
-- and for every cursor this config's keymaps produce (`<C-n>`, `<S-Down>`,
-- `<leader>ca…` — all added from normal mode) the replay is dot-repeat:
-- `input-manager.lua:188` does `feedkeys(".", "nx")` for each cursor whose
-- `cursor:mode()` is `"n"`, which after `cursor-manager.lua:2295-2303` normalises
-- every enabled cursor's mode is all of them. minuet's `action.accept`
-- (`virtualtext.lua:392-401`) writes the suggestion with
-- `nvim_buf_set_text` inside a `vim.schedule`. An API buffer edit never enters
-- Vim's insert recording, so it reaches neither the redo record nor the `.`
-- register — there is simply nothing for the other cursors to replay.
--
-- (`input-manager.lua:177` does read `getreg(".")`, but only for the `else`
-- branch at :191-193, which needs a cursor still holding a selection at insert
-- exit. Populating the `.` register alone would therefore NOT fix this.)
--
-- THE FIX. Let minuet do its whole accept exactly as upstream wrote it, then —
-- only while cursors are alive — re-express that one insertion as
-- `nvim_paste`, which is the one insertion primitive that writes the redo
-- record. The buffer and the cursor end up byte-identical; what changes is
-- that `.` can now reproduce the suggestion, so multicursor's existing
-- machinery carries it to every cursor with no multicursor internals touched.
--
-- INSERT MODE ONLY, AND STRICTLY. `nvim_paste` is equivalent to
-- `nvim_buf_set_text` in insert mode and in NO other mode, because `vim.paste`
-- dispatches on mode. Measured on the same buffer/cursor: Replace mode
-- OVERWRITES (`HELLOWORLD` + `ZZZ` at col 5 → `HELLOZZZLD`, where set_text
-- gives `HELLOZZZWORLD`) and normal mode lands one column right
-- (`HELLOWZZORLD`). minuet's own gate is `^[iR]` (`virtualtext.lua:129`), so
-- Replace mode is genuinely reachable — press `<Insert>` mid-suggestion and the
-- ghost text survives, since that fires no CursorMovedI. Hence `mode() == "i"`
-- exactly, never a `^[iR]` family match.
--
-- WHY NOT INTERCEPT EARLIER. There is no instant at which the suggestion text
-- can be read from minuet: `accept` resets `ctx` at `virtualtext.lua:375-377`
-- and clears the ghost-text extmark at :379, both synchronously, BEFORE its own
-- deferred edit. So the text is recovered from the buffer delta instead —
-- which has the side benefit of covering `accept_line`/`accept_n_lines` for
-- free (both dispatch through `action.accept`, :419 and :425-427) and of keying
-- on an observable rather than on minuet's choice of API call.
--
-- COUPLING. `install()` wraps `minuet.virtualtext.action.accept`, an internal
-- upstream offers no stability contract for — the same posture, and the same
-- debt, as `lua/config/minuet_guard.lua`. A rename disables the fix, so
-- `install()` returns false and `lua/plugins/minuet.lua` surfaces a warning.
-- `virtualtext.keymap.accept` must stay nil (it is, `lua/plugins/minuet.lua`):
-- `set_keymaps` captures `action.accept` BY VALUE at :558, so a key bound there
-- would bypass this wrapper. `<Tab>` and `<C-l>` both resolve it at press time
-- and are covered.
--
-- Two behaviours here are observed, not documented: that `vim.schedule`
-- callbacks run FIFO (so ours sees minuet's completed edit), and that the
-- rewrite is invisible to anything watching the buffer. Both are policed by the
-- changedtick arithmetic in `measure()` — anything unexpected returns nil and
-- the accept simply stays as upstream left it.

local M = {}

-- multicursor is lazy on keys, so `package.loaded` is the right question:
-- "never loaded" already means "one cursor", and a `require` here would drag
-- the plugin in on the first AI accept of every session. `numEnabledCursors` is
-- public (`multicursor-nvim/init.lua:39`) and always >= 1, the main cursor
-- included, so the interesting threshold is 2.
--
-- Enabled, not merely present: `forEachCursor` defaults to enabled cursors only
-- (`cursor-manager.lua:914-938`), so a session whose extra cursors are all
-- disabled gets no replay and should take the untouched upstream path.
local function enabled_cursors()
  local mc = package.loaded["multicursor-nvim"]
  if type(mc) ~= "table" or type(mc.numEnabledCursors) ~= "function" then
    return 1
  end
  local ok, n = pcall(mc.numEnabledCursors)
  return (ok and type(n) == "number") and n or 1
end

-- Everything the rewrite needs to know about the buffer before minuet touches
-- it. `tail` — the rest of the cursor's line — is what pins the end column of
-- the inserted text without trusting minuet's own post-edit cursor.
function M.snapshot()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    return nil
  end
  local row, col = cursor[1], cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  return {
    win = win,
    buf = buf,
    row = row,
    col = col,
    tail = line:sub(col + 1),
    lines = vim.api.nvim_buf_line_count(buf),
    tick = vim.api.nvim_buf_get_changedtick(buf),
  }
end

-- What minuet actually inserted, read back out of the buffer, or nil when the
-- delta is not the single clean insertion this module knows how to re-express.
--
-- Deliberately strict. Exactly one changedtick step: a second edit landing in
-- the same window (a TextChangedI handler, another plugin) would otherwise be
-- silently folded into the recovered text and then pasted a second time.
function M.measure(pre)
  if type(pre) ~= "table" then
    return nil
  end
  if not (pre.buf and vim.api.nvim_buf_is_valid(pre.buf)) then
    return nil
  end
  if pre.buf ~= vim.api.nvim_get_current_buf() then
    return nil
  end
  if not (pre.win and vim.api.nvim_win_is_valid(pre.win)) then
    return nil
  end
  if pre.win ~= vim.api.nvim_get_current_win() then
    return nil
  end
  if vim.api.nvim_buf_get_changedtick(pre.buf) ~= pre.tick + 1 then
    return nil
  end

  local added = vim.api.nvim_buf_line_count(pre.buf) - pre.lines
  if added < 0 then
    return nil
  end
  local end_row = pre.row + added
  local last = vim.api.nvim_buf_get_lines(pre.buf, end_row - 1, end_row, false)[1]
  if not last then
    return nil
  end
  -- The insertion pushed `pre.tail` to the right; where it now starts is where
  -- the inserted text ends. Anything else means this was not a plain insert at
  -- the cursor, and the module declines rather than guesses.
  local end_col = #last - #pre.tail
  if end_col < 0 or last:sub(end_col + 1) ~= pre.tail then
    return nil
  end
  if added == 0 and end_col < pre.col then
    return nil
  end

  local ok, chunks =
    pcall(vim.api.nvim_buf_get_text, pre.buf, pre.row - 1, pre.col, end_row - 1, end_col, {})
  if not ok then
    return nil
  end
  return table.concat(chunks, "\n"), end_row, end_col
end

-- Set by `rewrite` so specs (and a curious user) can see whether the last
-- accept was converted or left alone. Never read by the module itself.
M.last_rewrite_text = ""

-- Replace minuet's API insert with the identical `nvim_paste`.
--
-- Delete first, then paste. The other order — paste, then delete minuet's copy
-- — fails by leaving the suggestion in the buffer TWICE if the delete throws,
-- which is silent corruption. This order fails by leaving it missing, which the
-- restore below repairs from `text`, still held in a local.
local function rewrite(pre)
  if vim.fn.mode() ~= "i" then
    return false
  end
  local text, end_row, end_col = M.measure(pre)
  if not text or text == "" then
    return false
  end

  local ok =
    pcall(vim.api.nvim_buf_set_text, pre.buf, pre.row - 1, pre.col, end_row - 1, end_col, { "" })
  if not ok then
    return false
  end
  pcall(vim.api.nvim_win_set_cursor, pre.win, { pre.row, pre.col })

  local before = vim.api.nvim_buf_get_changedtick(pre.buf)
  local pasted = pcall(vim.api.nvim_paste, text, false, -1)
  -- Decide by whether the buffer actually moved, not by the return value:
  -- `vim.paste` is a documented user-overridable hook, and an override that
  -- quietly inserts nothing would otherwise cost the user their suggestion.
  if not pasted or vim.api.nvim_buf_get_changedtick(pre.buf) == before then
    pcall(
      vim.api.nvim_buf_set_text,
      pre.buf,
      pre.row - 1,
      pre.col,
      pre.row - 1,
      pre.col,
      vim.split(text, "\n")
    )
    pcall(vim.api.nvim_win_set_cursor, pre.win, { end_row, end_col })
    return false
  end

  M.last_rewrite_text = text
  return true
end

-- Wrap minuet's accept. Idempotent: `:Lazy reload minuet-ai.nvim` re-runs the
-- plugin's config(), and a second wrapper would measure a delta its inner call
-- already rewrote. Returns true when the wrapper is in place — including when
-- it was already there, because lua/plugins/minuet.lua warns on false and
-- "already installed" is a success, not a fault.
function M.install()
  local ok, vt = pcall(require, "minuet.virtualtext")
  if not ok or type(vt) ~= "table" or type(vt.action) ~= "table" then
    return false
  end
  if type(vt.action.accept) ~= "function" then
    return false
  end
  if vt.action.__multicursor_paste then
    return true
  end

  local inner = vt.action.accept

  local wrapped = function(n_lines)
    -- One integer read on the single-cursor path, which is every keystroke of
    -- ordinary editing: no snapshot, no schedule, nothing to go wrong.
    if enabled_cursors() < 2 then
      return inner(n_lines)
    end
    local pre = M.snapshot()
    local result = inner(n_lines)
    if pre then
      -- minuet defers its edit one tick (virtualtext.lua:392); schedule after
      -- it so the delta is there to measure.
      vim.schedule(function()
        rewrite(pre)
      end)
    end
    return result
  end

  vt.action.accept = wrapped
  vt.action.__multicursor_paste = true
  return true
end

return M
