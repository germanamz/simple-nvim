-- Global statusline. Eagerly loaded so it works in buffers that don't trigger
-- file-oriented events (e.g. netrw, which doesn't fire BufReadPre/BufNewFile
-- and therefore wouldn't lazy-load gitsigns or any statusline setup gated on
-- it). Branch and review base are cached per-buffer to avoid running git on
-- every redraw, and refreshed asynchronously so BufEnter never blocks on a
-- process spawn.
local M = {}

local path = require("util.path")

-- Resolve repo toplevel and branch in one git spawn, off the main thread.
-- `--show-toplevel` prints even when `--abbrev-ref HEAD` fails (e.g. a repo
-- with no commits yet), so the toplevel is parsed regardless of exit code and
-- the branch only on success. Detached HEAD prints "HEAD" → treated as none.
local function refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cmd =
    { "git", "-C", path.buf_start_dir(buf), "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD" }
  local spawned = pcall(vim.system, cmd, { text = true }, function(out)
    local lines = vim.split(out.stdout or "", "\n", { trimempty = true })
    local root = lines[1]
    local branch = (out.code == 0 and lines[2]) or ""
    if branch == "HEAD" then
      branch = ""
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local review_base = require("config.review_base")
      vim.b[buf].nvim_review_base = (root and review_base.get(root)) or ""
      vim.b[buf].nvim_git_branch = (root and branch) or ""
      vim.cmd("redrawstatus!")
    end)
  end)
  if not spawned then
    vim.b[buf].nvim_review_base = ""
    vim.b[buf].nvim_git_branch = ""
  end
end

-- Refresh every loaded buffer's cached branch/base and repaint the statusline.
-- Used by the initial VimEnter pass and on review-base changes.
local function refresh_all_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      refresh(buf)
    end
  end
  vim.cmd("redrawstatus!")
end

function _G.git_branch_status()
  local head = vim.b.nvim_git_branch
  if not head or head == "" then
    head = vim.b.gitsigns_head
  end
  local base = vim.b.nvim_review_base
  local has_head = head and head ~= ""
  local has_base = base and base ~= ""
  if not has_head and not has_base then
    return ""
  end
  if has_head and has_base then
    return string.format(" %s ↗ %s ", head, base)
  end
  if has_head then
    return string.format(" %s ", head)
  end
  return string.format(" ↗ %s ", base)
end

-- Stubs overridden by their owning plugins once loaded. Keeps the statusline
-- format string safe to evaluate before those plugins attach.
if not _G.lsp_refs_status then
  _G.lsp_refs_status = function()
    return ""
  end
end
if not _G.gitsigns_hunks_status then
  _G.gitsigns_hunks_status = function()
    return ""
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim_statusline", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "DirChanged" }, {
    group = group,
    callback = function(args)
      refresh(args.buf)
    end,
  })
  -- Netrw sets a window-local statusline (after FileType fires) that overrides
  -- the global one even with laststatus=3. Defer the clear so it runs after
  -- netrw's own setup, and re-clear on every BufWinEnter since netrw also
  -- reapplies its statusline when re-rendering the listing.
  local function clear_netrw_statusline(buf)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.bo[buf].filetype ~= "netrw" then
        return
      end
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_set_option_value("statusline", "", { win = win })
      end
    end)
  end
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "netrw" then
        refresh(args.buf)
        clear_netrw_statusline(args.buf)
      end
    end,
  })

  -- When nvim starts directly into netrw (e.g. `nvim .`), BufEnter for the
  -- netrw buffer can fire before this augroup is registered. Refresh once
  -- after startup completes so the initial buffer has branch/base populated.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = refresh_all_buffers,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ReviewBaseChanged",
    callback = refresh_all_buffers,
  })
  refresh(vim.api.nvim_get_current_buf())

  vim.o.statusline =
    "%f %m%r   %{v:lua.git_branch_status()}%=%{v:lua.lsp_refs_status()}%{v:lua.gitsigns_hunks_status()} %y %l:%c %p%% "
end

return M
