-- Shared "is this buffer too large for synchronous per-line / whole-buffer
-- work" predicate. One home for the threshold so every hot path agrees:
--   • the treesitter highlight + foldexpr guard (a whole-buffer parse stalls)
--   • treesitter-context (reparses a range on every CursorMoved)
--   • gitsigns new-vs-base painting (one extmark per line, synchronous loop)
--   • format-on-save (a synchronous formatter pass on BufWritePre)
-- The bounds target the giant generated / vendored / minified files a polyglot
-- superproject is full of — bundled JS, *.pb.go, minified assets, sqlite3.c —
-- the ones you land in by accident via a grep hit or a definition jump. The
-- byte check catches single-line multi-MB files the line count alone misses.
local M = {}

-- Tunables. Bump if you routinely hand-edit large sources.
M.MAX_LINES = 5000
M.MAX_BYTES = 512 * 1024

-- True when `buf` (default: current) exceeds either bound.
function M.is_large(buf)
  buf = buf or 0
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  if lc > M.MAX_LINES then
    return true
  end
  local ok, bytes = pcall(vim.api.nvim_buf_get_offset, buf, lc)
  return (ok and bytes > M.MAX_BYTES) or false
end

return M
