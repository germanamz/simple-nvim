local M = {}

-- Derive a directory suitable for git operations from a buffer's name: the
-- buffer's own path when it is itself a directory, otherwise its parent
-- directory, falling back to the cwd when the buffer is unnamed or the resolved
-- path is not a real directory. Single source for the ladder that statusline
-- and gitsigns both need before resolving a repo root.
function M.buf_start_dir(buf)
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
  return start
end

return M
