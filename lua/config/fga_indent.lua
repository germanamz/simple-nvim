-- 'indentexpr' for OpenFGA buffers: nvim-treesitter's indent, minus one
-- tree-sitter artefact.
--
-- A `#` comment written after the LAST define of a relations block (or after
-- the last line of any block) is a trailing extra, and tree-sitter hangs
-- trailing extras off the outermost node that ends there — source_file — not
-- off the relations block it visually belongs to. queries/fga/indents.scm can
-- do nothing about that: the comment's ancestors carry no @indent.begin, so
-- nvim-treesitter computes 0 for the comment line (the default `0#` indentkey
-- re-indents it to column 0 the moment `#` is typed) and 0 again for the line
-- opened under it — exactly the "comment, then the next define" flow.
--
-- So comment lines, and a blank line whose previous non-blank line is a
-- comment, return -1: keep the current indent (autoindent, i.e. the previous
-- line's). Everything else is nvim-treesitter's answer. Wired from the
-- treesitter FileType autocmd (lua/plugins/treesitter.lua) as the fga override
-- of the usual `nvim-treesitter.indentexpr()`.
local M = {}

---@return integer
function M.indentexpr()
  local lnum = vim.v.lnum
  local line = vim.fn.getline(lnum)
  if line:match("^%s*$") then
    line = vim.fn.getline(vim.fn.prevnonblank(lnum))
  end
  if line:match("^%s*#") then
    return -1
  end
  return require("nvim-treesitter").indentexpr()
end

return M
