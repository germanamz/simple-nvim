-- Telescope picker over the active LSP clients: see what is running, stop or
-- restart one (<leader>ll / :LspList).
--
-- Why this exists
-- ---------------
-- Neovim never reaps LSP clients (nvim 0.12.4 has no zero-buffer autostop), so a
-- session that visits several roots in a superproject accumulates one client per
-- root — ~0.7 GiB and 3 node processes for a warm ts_ls. The existing tools are
-- both blunt: `<leader>lk` (config.lsp_reap) sweeps EVERY idle client at once,
-- and `:lsp stop <name>` kills by server name, taking the one you are using with
-- it. Neither shows you what is running.
--
-- Restart fills a second gap: `<leader>lr` only reaches the clients attached to
-- the CURRENT buffer (it drives `restart_clients` below), so a client rooted at
-- another directory cannot be restarted at all without this picker.
--
-- Rows are ordered idle-first because a client with no attached buffers is the
-- kill candidate; telescope's generic_sorter preserves that order while the
-- prompt is empty (the same property config.ai_models relies on).
local Overlay = require("util.overlay")
local palette = require("config.palette")
local picker_legend = require("util.picker_legend")

local M = {}

--- One row per client: name, how many buffers it serves, and its root.
--- Idle clients first (the kill candidates), then by name, then by root.
---@param clients vim.lsp.Client[]
---@return table[]
function M.rows(clients)
  local rows = {}
  for _, c in ipairs(clients) do
    rows[#rows + 1] = {
      client = c,
      name = c.name,
      nbufs = vim.tbl_count(c.attached_buffers or {}),
      root = c.config and c.config.root_dir or c.root_dir,
    }
  end
  table.sort(rows, function(a, b)
    if (a.nbufs == 0) ~= (b.nbufs == 0) then
      return a.nbufs == 0
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return (a.root or "") < (b.root or "")
  end)
  return rows
end

--- `ts_ls          2 bufs   ~/projects/lola-workspace/lola-web`
---@param row table
---@return string
function M.format(row)
  local bufs = ("%d %s"):format(row.nbufs, row.nbufs == 1 and "buf" or "bufs")
  local root = row.root and vim.fn.fnamemodify(row.root, ":~") or "(no root)"
  return ("%-14s %-8s %s"):format(row.name, bufs, root)
end

--- Stop one client. Returns whether it acted (false when already stopped/nil).
---@param client vim.lsp.Client|nil
---@return boolean
function M.kill(client)
  if not client or client:is_stopped() then
    return false
  end
  client:stop()
  return true
end

--- The clients worth acting on: `nil` entries and ones already on their way out
--- are dropped, so a double-fire cannot stop the same client twice.
---@param clients vim.lsp.Client[]
---@return vim.lsp.Client[]
local function live_only(clients)
  return vim.tbl_filter(function(c)
    return c ~= nil and not c:is_stopped()
  end, clients)
end

--- `bufs` with `last` moved to the end, when it is in there at all.
---
--- lspconfig's resolvers and both wrappers around them call back synchronously
--- while `vim.lsp.enable` defers the actual `lsp.start` to the next tick, so
--- every buffer resolves before any client is created and the LAST resolution is
--- the one config.lsp_tsdk's `before_init` reads. Ordering the buffer you are
--- standing in last is what keeps a restart meaning "run THIS package's
--- TypeScript" in a mixed-version monorepo; list order alone would pick a random
--- open package.
---@param bufs integer[]
---@param last integer|nil
---@return integer[]
local function order_last(bufs, last)
  if not last or not vim.tbl_contains(bufs, last) then
    return bufs
  end
  local out = vim.tbl_filter(function(b)
    return b ~= last
  end, bufs)
  out[#out + 1] = last
  return out
end

--- Re-read `bufs` from disk, stop `live`, then bring the servers back over the
--- same list. The one restart primitive: both entry points below differ only in
--- which clients and which buffers they hand it.
---
--- Re-read anything that moved on disk BEFORE the servers come back. didOpen
--- serializes buffer lines, never the file ($VIMRUNTIME/lua/vim/lsp.lua's
--- _buf_get_full_text), so without this a restart hands the fresh server the
--- same stale text and it republishes byte-identical diagnostics — which is
--- exactly what "<leader>lr doesn't clear them" looked like. `:checktime {buf}`
--- rather than the `:edit` this replaced: it reaches a buffer that is neither
--- current nor in a window, it is a no-op when the stat is unchanged, and on a
--- buffer with unsaved edits config.file_reload's FileChangedShell handler
--- warns instead of throwing E37 — so the mid-edit regression that motivated
--- dropping `:edit` does not come back.
---
--- Ahead of the stop loop, not between it and the re-attach: a reload drives
--- vim.lsp's on_reload, which sends didClose+didOpen to whatever clients are
--- still attached. get_clients filters on `initialized`, never on
--- `_is_stopping`, so re-reading after the stop would hand a dying client a
--- fresh didOpen and schedule a vim.diagnostic.show for its namespace — a
--- flash of the stale diagnostics on the next tick, until _on_detach resets it.
---
--- No wait between the stop and the re-attach. `Client:stop()` marks the client
--- `_is_stopping` synchronously and nvim's default `reuse_client` refuses a
--- stopped client, so the fresh `lsp.start` cannot land on the dying one (no
--- server in lua/plugins/lsp.lua overrides `reuse_client`). Blocking the UI
--- thread on a tsserver shutdown to re-prove that would only add latency to a
--- keypress.
---@param live vim.lsp.Client[]
---@param bufs integer[]
---@return integer stopped, integer reattached
local function cycle(live, bufs)
  for _, b in ipairs(bufs) do
    pcall(vim.cmd, "checktime " .. b)
  end

  for _, c in ipairs(live) do
    c:stop()
  end

  -- vim.lsp.enable() installs a FileType autocmd that starts/attaches the
  -- server, so re-firing FileType is what brings the clients back. It reaches a
  -- buffer that is not current, and it leaves the buffer's TEXT alone — the
  -- checktime above is what refreshes it (see the <leader>lr note in
  -- plugins/lsp.lua).
  --
  -- Inside nvim_buf_call, because nvim_exec_autocmds sets `<abuf>` and nothing
  -- else: ftplugins act on the CURRENT buffer ($VIMRUNTIME/ftplugin/lua.lua
  -- calls vim.treesitter.start() with no bufnr), so firing for a buffer you are
  -- not standing in would setlocal its filetype's options onto the buffer you
  -- are. vim.lsp.enable's own handler reads args.buf and never noticed.
  --
  -- Re-checked for validity rather than trusted: the list was built before the
  -- reloads, and either half of this cycle can wipe an entry (config.file_reload
  -- pcalls its own loop for the same reason). Counting the fires keeps the
  -- reported number honest when one drops out.
  local reattached = 0
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      reattached = reattached + 1
      vim.api.nvim_buf_call(b, function()
        vim.api.nvim_exec_autocmds("FileType", { buffer = b })
      end)
    end
  end
  return #live, reattached
end

--- Stop `clients` and bring them back for every buffer they were serving.
---
--- Returns how many clients were stopped and how many buffers were re-attached.
--- Clients already on their way out are skipped, so this is safe to double-fire.
---
--- Re-attaching EVERY buffer, not just the current one, is the point: `stop()`
--- detaches all of them at once, and nothing brings a non-current buffer back on
--- its own — sibling files under the same root would sit there with no server
--- until you reopened each one.
---@param clients vim.lsp.Client[]
---@param opts? { last_buf?: integer }
---@return integer stopped, integer reattached
function M.restart_clients(clients, opts)
  local live = live_only(clients)

  -- The union of their buffers, deduplicated: a tsx file is served by ts_ls,
  -- biome and oxlint at once, and one FileType fire per client would also run
  -- every OTHER FileType handler (treesitter, statusline, decl_rules) twice more
  -- for that buffer.
  --
  -- `last_buf` goes last on purpose; see order_last for why.
  local bufs, seen = {}, {}
  for _, c in ipairs(live) do
    for b in pairs(c.attached_buffers or {}) do
      if not seen[b] and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
        seen[b] = true
        bufs[#bufs + 1] = b
      end
    end
  end
  bufs = order_last(bufs, opts and opts.last_buf)

  return cycle(live, bufs)
end

--- Stop EVERY live client and re-attach every open file buffer: the full-reload
--- hatch behind `<leader>lR` / `:LspRestartAll`.
---
--- Two things separate this from restart_clients, and both are failure modes
--- `<leader>lr` cannot reach:
---
---   * It stops every client in the session, not the ones serving the current
---     buffer. In a superproject each root gets its own client, so a per-buffer
---     restart fixes the file you are standing in and leaves every sibling
---     package publishing against text it read before the branch switch.
---   * It takes the re-attach list from the open FILE buffers rather than from
---     `attached_buffers`. A buffer whose server crashed, or that opened before
---     the server was installed, has no client to walk back from — it is
---     invisible to restart_clients and to the picker alike, and reopening it by
---     hand was the only way back.
---
--- Stale diagnostics need no explicit clearing: the runtime resets a client's
--- namespace from its own LspDetach autocmd (vim/lsp/diagnostic.lua), which
--- `stop()` triggers. nvim-lint owns a separate namespace and re-runs off the
--- reload edge (lua/plugins/nvim-lint.lua).
---@param clients? vim.lsp.Client[] defaults to every active client
---@param opts? { last_buf?: integer }
---@return integer stopped, integer reattached
function M.restart_all(clients, opts)
  local live = live_only(clients or vim.lsp.get_clients())

  -- The set a disk sweep covers (config.file_reload owns that definition), minus
  -- buffers with no filetype. The re-attach runs through vim.lsp.enable's
  -- FileType autocmd, which matches on the buffer's filetype, so a buffer
  -- without one has nothing for any server to match and firing on it would only
  -- spend a pass through every other FileType handler.
  local bufs = vim.tbl_filter(function(b)
    return vim.bo[b].filetype ~= ""
  end, require("config.file_reload").buffers())

  return cycle(live, order_last(bufs, opts and opts.last_buf))
end

--- Restart everything and report. The user asked, so say what happened either
--- way: "nothing was running" is a real answer here rather than an error, since
--- a server that died on its own is one of the states this key recovers from.
---@param clients? vim.lsp.Client[] defaults to every active client
---@param opts? { last_buf?: integer }
function M.restart_all_and_notify(clients, opts)
  local stopped, reattached = M.restart_all(clients, opts)
  local bufs = ("%d buffer%s"):format(reattached, reattached == 1 and "" or "s")
  vim.notify(
    stopped > 0
        and ("restarted %d client%s across %s"):format(stopped, stopped == 1 and "" or "s", bufs)
      or ("no LSP servers were running; re-attached %s"):format(bufs),
    vim.log.levels.INFO
  )
end

--- Stop one client and bring it back for the buffers it was serving.
---
--- Returns the number of buffers re-attached, or nil when there was nothing to
--- do. Zero means the client had no buffers, so this degraded to a plain stop.
---@param client vim.lsp.Client|nil
---@return integer|nil
function M.restart(client)
  if not client or client:is_stopped() then
    return nil
  end
  local _, reattached = M.restart_clients({ client })
  return reattached
end

-- ===================== legend =====================

local function set_legend_highlights()
  vim.api.nvim_set_hl(0, "LspPickerLegend", { fg = palette.muted, default = true })
  vim.api.nvim_set_hl(0, "LspPickerLegendKey", { fg = "#768390", bold = true, default = true })
end

local legend = Overlay.new()

local function close_legend()
  legend:close()
end

local function open_legend(prompt_bufnr)
  close_legend()
  set_legend_highlights()
  local results_win = picker_legend.results_win(prompt_bufnr)
  if not results_win then
    return
  end
  local segs = {}
  for _, pair in ipairs({
    { "<CR>", "restart" },
    { "<C-k>", "stop" },
    { "<esc>", "close" },
  }) do
    segs[#segs + 1] = { icon = pair[1], icon_hl = "LspPickerLegendKey", label = pair[2] }
  end
  local text, ranges = picker_legend.render_segments(segs, {
    separator = "   ",
    default_hl = "LspPickerLegend",
  })
  local width = vim.api.nvim_win_get_width(results_win)
  text, ranges = picker_legend.fit_line(text, ranges, width)
  picker_legend.mount(legend, results_win, "lsp_picker_legend", { text }, { ranges })
end

-- ===================== picker =====================

local function make_finder()
  local finders = require("telescope.finders")
  return finders.new_table({
    results = M.rows(vim.lsp.get_clients()),
    entry_maker = function(row)
      local line = M.format(row)
      return { value = row, display = line, ordinal = line }
    end,
  })
end

--- Rebuild the list in place so it stays truthful after a stop/restart.
local function refresh(prompt_bufnr)
  local action_state = require("telescope.actions.state")
  local p = action_state.get_current_picker(prompt_bufnr)
  if p then
    p:refresh(make_finder(), { reset_prompt = false })
  end
end

function M.open()
  if #vim.lsp.get_clients() == 0 then
    vim.notify("no active LSP clients", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local action_state = require("telescope.actions.state")
  set_legend_highlights()

  pickers
    .new({}, {
      prompt_title = "LSP clients",
      finder = make_finder(),
      sorter = conf.generic_sorter({}),
      initial_mode = "normal",
      attach_mappings = function(prompt_bufnr, map)
        picker_legend.attach(prompt_bufnr, function()
          open_legend(prompt_bufnr)
        end, close_legend)

        --- Selected client, guarded against one that died while the picker was open.
        local function selected()
          local entry = action_state.get_selected_entry()
          local row = entry and entry.value
          if not row or not row.client or row.client:is_stopped() then
            refresh(prompt_bufnr)
            return nil
          end
          return row
        end

        -- <C-k>: stop the client under the cursor. Ctrl-prefixed, not bare `k`:
        -- this picker opens in normal mode where `k` moves the selection up, and
        -- taking navigation away from a list you must move around in before
        -- acting would be a bad trade. Confirmed, like ai_models' model delete.
        map({ "i", "n" }, "<C-k>", function()
          local row = selected()
          if not row then
            return
          end
          local label = ("%s (%s)"):format(row.name, row.root or "no root")
          if vim.fn.confirm("Stop " .. label .. "?", "&Yes\n&No", 2) ~= 1 then
            return
          end
          M.kill(row.client)
          vim.notify("stopped " .. label)
          refresh(prompt_bufnr)
        end)

        -- <CR>: restart the client under the cursor, re-attaching its buffers.
        map({ "i", "n" }, "<CR>", function()
          local row = selected()
          if not row then
            return
          end
          local n = M.restart(row.client)
          vim.notify(
            n == 0 and ("stopped %s (no buffers to re-attach)"):format(row.name)
              or ("restarted %s for %d buffer%s"):format(row.name, n, n == 1 and "" or "s")
          )
          refresh(prompt_bufnr)
        end)

        return true
      end,
    })
    :find()
end

return M
