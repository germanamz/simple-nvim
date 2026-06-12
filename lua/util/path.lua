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

-- Path of `abs` relative to directory `base`, or the absolute path unchanged
-- when it does not live under `base`. Both arguments are normalized first, so
-- either may be relative or carry a trailing slash.
function M.relative(abs, base)
  abs = vim.fn.fnamemodify(abs, ":p")
  base = vim.fn.fnamemodify(base, ":p")
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  if abs:sub(1, #base) == base then
    return abs:sub(#base + 1)
  end
  return abs
end

return M
