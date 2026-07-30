-- Stop language servers that no longer serve any buffer.
--
-- Why this exists
-- ---------------
-- nvim 0.12.4 never reaps LSP clients. The only `client:stop()` sites in the
-- runtime are VimLeavePre, `vim.lsp.enable(name, false)`, deprecated
-- `stop_client`, and an explicit `Client:stop()`; `Client:_on_detach` only
-- detaches. So a client left at `attached_buffers = 0` keeps every one of its
-- processes alive until you quit — measured ~0.7 GiB and 3-4 node processes per
-- warm ts_ls client on a real repo. Browsing several monorepos in one session
-- accumulates one per root (and `<leader>bad` leaves ALL of them bufferless at
-- once), while `:lsp stop ts_ls` is the only built-in alternative and kills the
-- client you are actually using.
--
-- Why it is MANUAL
-- ----------------
-- A debounced autocmd reaper was prototyped and rejected: it silently destroys
-- config.lsp_fs_sync's rename import-rewrite. `on_will_rename` sends
-- `workspace/willRenameFiles` to every client whose `root_dir` covers the path
-- and never requires that client to have attached buffers — so a
-- bufferless-but-alive client still rewrites importers repo-wide today, and a
-- reaped one does nothing, with no message. Measured: the importer was rewritten
-- in the control run and untouched after a sweep.
--
-- It is also close to pointless automatically: `hidden` is never overridden in
-- lua/config/options.lua, so a session that browses ten monorepos keeps every
-- buffer loaded and every client "in use". The measured payoff is entirely at the
-- explicit cleanup gestures, which is where this is wired.
--
-- Returning to a swept root costs ~0.1 s to re-attach and ~1.0-1.4 s to first
-- diagnostics — the reason a manual sweep is a fair trade and an LRU cap (which
-- charges that while your buffers are still open) is not.
local M = {}

--- Clients that are alive but serve no buffer.
---
--- Not filtered by server name on purpose: gopls and lua_ls were measured
--- lingering bufferless exactly like ts_ls, and a ts_ls-only sweep would answer
--- "stopped 0" while another server held its memory.
---@param clients vim.lsp.Client[]
---@return vim.lsp.Client[]
function M.idle(clients)
  return vim.tbl_filter(function(c)
    return not c:is_stopped() and next(c.attached_buffers or {}) == nil
  end, clients)
end

--- Stop every idle client. Returns how many were stopped.
---@param clients vim.lsp.Client[]|nil defaults to every active client
---@return integer
function M.sweep(clients)
  local victims = M.idle(clients or vim.lsp.get_clients())
  for _, c in ipairs(victims) do
    c:stop()
  end
  return #victims
end

--- Sweep and report. The user asked, so say what happened either way.
function M.sweep_and_notify()
  local n = M.sweep()
  vim.notify(
    n > 0 and ("stopped %d idle LSP server%s"):format(n, n == 1 and "" or "s")
      or "no idle LSP servers",
    vim.log.levels.INFO
  )
end

return M
