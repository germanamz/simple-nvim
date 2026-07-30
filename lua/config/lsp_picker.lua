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
-- Restart fills a second gap: `<leader>lr` stops the clients attached to the
-- CURRENT buffer and `:edit`s, so a client rooted at another directory cannot be
-- restarted at all.
--
-- Rows are ordered idle-first because a client with no attached buffers is the
-- kill candidate; telescope's generic_sorter preserves that order while the
-- prompt is empty (the same property config.ai_models relies on).
local Overlay = require("util.overlay")
local palette = require("config.palette")
local picker_legend = require("util.picker_legend")

local M = {}

-- Bound the wait for a stopping client to exit. Stop is asynchronous, and
-- starting a new client before the old one exits risks the reuse path selecting
-- the dying one. Same budget as lsp_fs_sync's synchronous rename round-trip.
local STOP_TIMEOUT_MS = 2000

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
  local bufs = {}
  for b in pairs(client.attached_buffers or {}) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      bufs[#bufs + 1] = b
    end
  end

  client:stop()
  -- Let it actually exit before re-triggering attach.
  vim.wait(STOP_TIMEOUT_MS, function()
    return client:is_stopped()
  end, 50)

  -- vim.lsp.enable() installs a FileType autocmd that starts/attaches the
  -- server, so re-firing FileType is what brings the client back — the buffers
  -- are not current, so the `:edit` trick <leader>lr uses does not apply here.
  for _, b in ipairs(bufs) do
    vim.api.nvim_exec_autocmds("FileType", { buffer = b })
  end
  return #bufs
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
