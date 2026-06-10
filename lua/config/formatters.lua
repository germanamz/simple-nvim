-- Single source of truth for per-filetype formatter configuration. conform.nvim
-- (lua/plugins/conform.lua) reads `by_ft` to wire up on-demand formatting
-- (`<leader>F`), format-on-save, and `gq` via formatexpr on real buffers.

local M = {}

-- Use black in projects that configure it ([tool.black] in pyproject.toml).
-- ruff_format ignores [tool.black] and falls back to its own defaults
-- (88 cols, double quotes), silently rewriting such projects on save.
local function python_formatters(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  local pyproject = vim.fs.find("pyproject.toml", {
    upward = true,
    path = vim.fs.dirname(fname),
  })[1]
  if pyproject then
    for line in io.lines(pyproject) do
      if line:match("^%[tool%.black%]") then
        return { "black" }
      end
    end
  end
  return { "ruff_format" }
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
