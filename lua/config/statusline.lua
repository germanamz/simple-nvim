-- Global statusline. Eagerly loaded so it works in buffers that don't trigger
-- file-oriented events (e.g. netrw, which doesn't fire BufReadPre/BufNewFile
-- and therefore wouldn't lazy-load gitsigns or any statusline setup gated on
-- it). Branch and review base are cached per-buffer to avoid running git on
-- every redraw.
local M = {}

local function git_branch(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "branch", "--show-current" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]
end

local function refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local review_base = require("config.review_base")
  local fname = vim.api.nvim_buf_get_name(buf)
  local start
  if fname ~= "" and vim.fn.isdirectory(fname) == 1 then
    start = fname
  elseif fname ~= "" then
    start = vim.fn.fnamemodify(fname, ":p:h")
  end
  if not start or start == "" or vim.fn.isdirectory(start) == 0 then
    start = vim.fn.getcwd()
  end
  local root = start and start ~= "" and review_base.git_root(start) or nil
  vim.b[buf].nvim_review_base = (root and review_base.get(root)) or ""
  vim.b[buf].nvim_git_branch = (root and git_branch(root)) or ""
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
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          refresh(buf)
        end
      end
      vim.cmd("redrawstatus!")
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ReviewBaseChanged",
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          refresh(buf)
        end
      end
      vim.cmd("redrawstatus!")
    end,
  })
  refresh(vim.api.nvim_get_current_buf())

  vim.o.statusline =
    "%f %m%r   %{v:lua.git_branch_status()}%=%{v:lua.lsp_refs_status()}%{v:lua.gitsigns_hunks_status()} %y %l:%c %p%% "
end

return M
