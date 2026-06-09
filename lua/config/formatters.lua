-- Single source of truth for per-filetype formatter configuration. conform.nvim
-- (lua/plugins/conform.lua) reads `by_ft` to wire up on-demand formatting
-- (`<leader>F`), format-on-save, and `gq` via formatexpr on real buffers.

local M = {}

-- Vim filetype -> ordered list of conform formatter names.
M.by_ft = {
  python = { "ruff_format" },
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
