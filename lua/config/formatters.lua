-- Single source of truth for per-filetype formatter configuration. conform.nvim
-- (lua/plugins/conform.lua) reads `by_ft` to wire up on-demand formatting
-- (`<leader>F`), format-on-save, and `gq` via formatexpr on real buffers.

local M = {}

-- Use black in projects that configure it ([tool.black] in pyproject.toml).
-- ruff_format ignores [tool.black] and falls back to its own defaults
-- (88 cols, double quotes), silently rewriting such projects on save.
--
-- Memoized by the buffer's directory: the pyproject location (and its
-- [tool.black] decision) is invariant per dir for a session, and conform calls
-- this twice per format() — so without a cache every save re-walks the tree and
-- re-reads pyproject. Mirrors util.git's root_cache; clear with _clear_python_cache.
local python_cache = {}

local function python_formatters(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  local dir = (fname ~= "" and vim.fs.dirname(fname)) or vim.fn.getcwd()
  local cached = python_cache[dir]
  if cached then
    return cached
  end

  local choice = { "ruff_format" }
  local pyproject = vim.fs.find("pyproject.toml", { upward = true, path = dir })[1]
  if pyproject then
    -- io.open (not io.lines): io.lines raises a Lua error if the file vanished
    -- between find and open, or is unreadable. This runs inside conform's
    -- BufWritePre callback, where an unhandled error would poison the save's
    -- autocmd chain — so degrade to ruff_format on any read failure instead.
    local f = io.open(pyproject, "r")
    if f then
      for line in f:lines() do
        if line:match("^%[tool%.black%]") then
          choice = { "black" }
          break
        end
      end
      f:close()
    end
  end

  python_cache[dir] = choice
  return choice
end

-- Drop the memoized python decisions (for tests, or after editing pyproject
-- mid-session).
function M._clear_python_cache()
  python_cache = {}
end

-- Vim filetype -> ordered list of conform formatter names (or a function
-- of bufnr returning one — conform supports both).
M.by_ft = {
  python = python_formatters,
  lua = { "stylua" },
  go = { "gofmt" },
  rust = { "rustfmt" },
  sh = { "shfmt" },
  bash = { "shfmt" },
  zsh = { "shfmt" },
  c = { "clang_format" },
  cpp = { "clang_format" },
  objc = { "clang_format" },
  objcpp = { "clang_format" },
  toml = { "taplo" },
  javascript = { "prettier" },
  javascriptreact = { "prettier" },
  typescript = { "prettier" },
  typescriptreact = { "prettier" },
  json = { "prettier" },
  jsonc = { "prettier" },
  css = { "prettier" },
  scss = { "prettier" },
  html = { "prettier" },
  yaml = { "prettier" },
  markdown = { "prettier" },
  mdx = { "prettier" },
}

return M
