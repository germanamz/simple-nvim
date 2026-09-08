-- Keep open buffers following the file on disk, and give every indicator that
-- is computed FROM a buffer one edge to re-run on.
--
-- 'autoread' is on by Neovim default, but it is only a policy: it decides what
-- happens once a timestamp CHECK has noticed a change, and Neovim runs a check
-- on its own in exactly three situations -- a real terminal focus-gain, entering
-- a buffer that is in a window, and the sweep after a `:!cmd`. This config
-- shells out only through vim.system / vim.fn.systemlist, so the third never
-- fires; and when an agent rewrites files in a neighbouring pane the first two
-- may not fire either. The buffer then keeps the pre-fix text, and because
-- gitsigns diffs buffer lines (gitsigns/manager.lua) and vim.lsp serializes
-- buffer lines into didOpen/didChange ($VIMRUNTIME/lua/vim/lsp.lua's
-- _buf_get_full_text), every hunk sign and every diagnostic stays arithmetically
-- correct about text that no longer exists on disk. `<leader>lr` cannot rescue
-- it either: restarting a server re-sends the same stale buffer.
--
-- Two details are load-bearing:
--
--   * A BARE `:checktime` visits only buffers that are in a window, despite
--     doc/editing.txt promising "each loaded buffer is checked". The stale
--     buffers are precisely the HIDDEN ones -- the other seven files the agent
--     touched while you were reading the eighth -- so the sweep uses the
--     per-bufnr form, which does reach them.
--
--   * Owning FileChangedShell is what makes an automatic sweep safe. Neovim's
--     built-in answer to "the file changed but the buffer has unsaved edits" is
--     a MODAL W12 prompt; an unattended CursorHold must never be able to stop
--     the editor dead, so this module answers instead and notifies. The happy
--     path is untouched: for an unmodified buffer 'autoread' reloads silently
--     and FileChangedShell never fires at all (verified on 0.12.5).
--
-- Cost: one fs_stat per open file buffer, no spawn. A forced sweep over 201 real
-- file buffers measured 3.68 ms (~18 us each), so it scales with how many files
-- you have open and not with repo size. That is why it can ride CursorHold in a
-- config that disabled workspace/didChangeWatchedFiles for cost
-- (lua/plugins/lsp.lua): a stat per open buffer is not a recursive FSEvents walk
-- per workspace root. What the throttle does NOT bound is the fan-out -- each
-- buffer that actually reloads costs its consumers a re-lint and a git
-- re-resolve -- so a branch switch across many open buffers is real work.
--
-- Consumers hook one of two User events instead of guessing at reload edges:
--   * FileReloaded      { buf }  -- this buffer's text just changed under you
--   * FileRefreshForced          -- the <leader>r hatch; re-resolve everything
local M = {}

local GROUP = "file_reload"

-- Unforced sweeps collapse into at most one per second. BufEnter fires on every
-- window and buffer hop, so without this a `:bnext` walk would restat every open
-- buffer per keystroke for no new information.
local THROTTLE_NS = 1000 * 1000 * 1000

local last_sweep = 0

-- Buffers with an on-disk truth to re-read. Everything the plugins put on
-- screen -- nvim-tree, telescope prompts, terminals, quickfix, the docs reader
-- -- carries a non-empty 'buftype' and is skipped, as is a scratch `[No Name]`.
local function reloadable(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

-- Never pull text out from under an active edit. CursorHold cannot fire in
-- insert mode, but FocusGained and BufEnter both can -- alt-tabbing back into a
-- half-typed line is the ordinary case -- and reloading there would move the
-- cursor and cut the insert-session undo block in half. Visual mode is excluded
-- for the same reason: the selection is anchored to line numbers a reload moves.
--
-- EXACT equality, not a "starts with n" test. mode() also answers "no"/"nov" for
-- operator-pending, "niI"/"niR" for i_CTRL-O and "nt" in a terminal buffer; all
-- of those are mid-command states where a reload is just as unwelcome, and
-- BufEnter in particular still fires during macro replay, where shifting line
-- numbers under the macro would be silently destructive.
local function settled()
  if vim.fn.getcmdwintype() ~= "" then
    return false
  end
  return vim.api.nvim_get_mode().mode == "n"
end

local function filename(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

-- Warn on exactly ONE screen row. vim.notify here is core's nvim_echo -- this
-- config installs no notify replacement -- so a message that wraps past
-- 'columns' becomes a hit-enter prompt, which is the very thing the conflict
-- handler exists to avoid, just moved one step along. The advice is the fixed
-- part and always survives; a pathological filename is elided from the front,
-- because the tail of a name is what distinguishes it.
local function warn(name, advice)
  local room = math.max(8, vim.o.columns - vim.fn.strdisplaywidth(advice) - 2)
  if vim.fn.strdisplaywidth(name) > room then
    name = "…" .. vim.fn.strcharpart(name, vim.fn.strchars(name) - room + 1)
  end
  vim.notify(name .. " " .. advice, vim.log.levels.WARN)
end

--- Every buffer with an on-disk truth to re-read, in bufnr order.
---
--- Exported because a sweep is not the only thing that has to act on this exact
--- set: config.lsp_picker's full LSP restart re-attaches the buffers a sweep can
--- refresh, and one definition of "a file buffer" beats two that drift.
---@return integer[]
function M.buffers()
  return vim.tbl_filter(reloadable, vim.api.nvim_list_bufs())
end

--- Re-stat every open file buffer and let 'autoread' reload the ones that moved.
---
--- Returns how many buffers were checked; 0 when the sweep was skipped (mid-edit
--- or inside the throttle window), which is what the specs assert on.
---@param opts? { force?: boolean }
---@return integer
function M.sweep(opts)
  opts = opts or {}
  if not settled() then
    return 0
  end
  local now = vim.uv.hrtime()
  if not opts.force and now - last_sweep < THROTTLE_NS then
    return 0
  end
  last_sweep = now

  local bufs = M.buffers()
  for _, buf in ipairs(bufs) do
    if opts._record then
      opts._record[#opts._record + 1] = buf
    end
    -- Per-bufnr: the bare form would skip every buffer that is not currently
    -- displayed. pcall because a buffer can be wiped by an autocmd that an
    -- earlier reload in this same loop triggered.
    pcall(vim.cmd, "checktime " .. buf)
  end
  return #bufs
end

--- The `<leader>r` hatch: sweep unconditionally, then tell everything that
--- caches git or filesystem facts to re-resolve. Needed because a sweep alone
--- only fixes state derived from buffers -- a file created or deleted on disk
--- changes `git status` without touching any open buffer.
function M.refresh()
  M.sweep({ force = true })

  -- gitsigns is the one consumer with no config module of its own to hook the
  -- event, so it is refreshed here. It re-diffs against the now-current buffer.
  if package.loaded["gitsigns"] then
    pcall(function()
      require("gitsigns").refresh()
    end)
  end

  vim.api.nvim_exec_autocmds("User", { pattern = "FileRefreshForced", modeline = false })
end

function M.setup()
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  -- FocusGained: coming back from the pane the agent was writing in.
  -- BufEnter: switching to a file someone else changed while it sat hidden.
  -- CursorHold: the case neither of the others covers -- nvim keeps focus and
  -- you keep staring at the same buffer while it is rewritten underneath you.
  -- CursorHold fires once per idle period, so it costs one sweep per pause.
  --
  -- Scheduled off the autocmd stack. Inside an autocmd Neovim is `autocmd_busy`
  -- and suppresses the decision half of the timestamp check: a plain content
  -- change still reloads, but the conflict and deleted branches below never fire,
  -- so an unsaved-edit clash would pass in total silence and only surface if you
  -- happened to press <leader>r. Deferring one tick makes the automatic edges
  -- behave exactly like the manual hatch. (Headless does not reproduce the
  -- suppression -- it fires FileChangedShell on every sweep -- so this is only
  -- observable in a real TUI, and the unit spec cannot pin it.)
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = group,
    desc = "Re-read buffers whose file changed on disk",
    callback = function()
      vim.schedule(function()
        M.sweep()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    desc = "Answer external-change conflicts without a modal prompt",
    callback = function(args)
      local reason = vim.v.fcs_reason
      if reason == "conflict" then
        -- Keep the unsaved buffer. Losing an edit to a background sweep would
        -- be far worse than a stale sign, and the notification says how to
        -- resolve it either way. Fires once per external change, not once per
        -- sweep: the check resets the stored timestamp.
        vim.v.fcs_choice = ""
        warn(filename(args.buf), "changed on disk — unsaved edits kept (:e! to reload)")
      elseif reason == "deleted" then
        vim.v.fcs_choice = ""
        warn(filename(args.buf), "deleted on disk — buffer kept (:w to restore)")
      elseif reason == "changed" then
        -- Not reached in practice: an unmodified buffer is reloaded silently by
        -- 'autoread' and this event never fires for it. Kept explicit because
        -- the docs state 'autoread' is not consulted once this autocommand
        -- runs, so any path that does route a plain change here has to ask.
        vim.v.fcs_choice = "reload"
      else
        -- "mode" / "time": nothing was rewritten, so there is nothing to re-read.
        vim.v.fcs_choice = ""
      end
    end,
  })

  -- FileChangedShellPost fires only after a reload actually happened (a
  -- conflict or a deletion stops at FileChangedShell), so this is the precise
  -- "this buffer's text just changed under you" edge -- the one nvim-lint,
  -- the submodule caches and the ignore filter re-run on.
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    desc = "Republish a reload as User FileReloaded",
    callback = function(args)
      -- Scheduled, not fired inline. `:checktime {buf}` runs the reload as an Ex
      -- command, i.e. inside a try context, so a consumer that throws becomes an
      -- exception that unwinds the whole User chain -- every consumer registered
      -- after it is skipped, and the sweep's own pcall (which is there for wiped
      -- buffers) then swallows the error, leaving no message anywhere. Off the
      -- Ex stack the ordinary autocmd rules apply again: the error is reported
      -- and the remaining consumers still run. The buffer already holds the new
      -- text by the time FileChangedShellPost fires, so nothing races.
      local buf = args.buf
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        vim.api.nvim_exec_autocmds("User", {
          pattern = "FileReloaded",
          data = { buf = buf },
          modeline = false,
        })
      end)
    end,
  })

  vim.keymap.set("n", "<leader>r", function()
    M.refresh()
  end, { desc = "Refresh buffers and git from disk" })
end

-- Test seam: drop the throttle so consecutive specs are not silently skipped.
function M._reset()
  last_sweep = 0
end

return M
