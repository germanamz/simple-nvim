-- Buffer deletion behavior backing the <leader>bd keymap (registered in
-- config.options). Lives in its own module so the ~50-line decision logic is
-- unit-testable (see tests/spec/unit/buffers_spec.lua) instead of buried in an
-- inline keymap closure.
local M = {}

-- A "real" buffer: one worth keeping a window on. Excludes throwaway [No Name]
-- scratch buffers (the empty startup buffer left listed when you open a file
-- from the tree). Counting those made closing your last file land on the
-- scratch buffer, needing a second <leader>bd to reach the tree; here they
-- don't keep you out of the explorer. An unnamed buffer that's *modified* is
-- still real -- it holds unsaved work.
function M._is_real(b)
  return vim.bo[b].buflisted and (vim.api.nvim_buf_get_name(b) ~= "" or vim.bo[b].modified)
end

-- Which real sibling to land on before deleting the current buffer: prefer the
-- window's alternate buffer (`#`) when it's one of the real `others`, else fall
-- back to the last real other. `alt` is vim.fn.bufnr("#") (-1 when there is no
-- alternate). Pure so the target choice can be unit-tested without windows.
function M._pick_target(others, alt)
  if alt ~= -1 and vim.tbl_contains(others, alt) then
    return alt
  end
  return others[#others]
end

-- Delete the current buffer without closing its window. When other *real*
-- buffers remain, switch to one first so the window stays on a file instead of
-- collapsing (which would quit nvim if it's the last window). When the last real
-- buffer is closed, fall back to the nvim-tree explorer -- the same default view
-- `nvim .` opens -- instead of leaving a stuck empty buffer.
function M.delete_current()
  local cur = vim.api.nvim_get_current_buf()

  local others = vim.tbl_filter(function(b)
    return b ~= cur and M._is_real(b)
  end, vim.api.nvim_list_bufs())

  if #others > 0 then
    -- Move to a real sibling (prefer the alternate buffer) before deleting, so
    -- the window stays on a file. Don't move off a modified `cur`: skipping the
    -- pre-move keeps `bdelete`'s E89 loud without the view jumping away from a
    -- buffer that wasn't deleted.
    if not vim.bo[cur].modified then
      vim.api.nvim_set_current_buf(M._pick_target(others, vim.fn.bufnr("#")))
    end
    vim.cmd("bdelete " .. cur)
    return
  end

  -- No real buffers left: delete cur first so unsaved-changes errors still abort
  -- loudly (nvim leaves a throwaway empty [No Name] in the window), then open
  -- nvim-tree and drop every other window so we land on just the tree.
  vim.cmd("bdelete " .. cur)
  require("lazy").load({ plugins = { "nvim-tree.lua" } })
  require("nvim-tree.api").tree.open()
  local tree_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= tree_win then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  -- Sweep up the throwaway [No Name] buffers (the startup one, plus the empty
  -- buffer nvim spawns when the last file is deleted) now that they're hidden
  -- behind the tree, so they don't pile up across a session.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and not vim.bo[b].modified
      and vim.api.nvim_buf_get_name(b) == ""
    then
      pcall(vim.api.nvim_buf_delete, b, { force = false })
    end
  end
end

return M
