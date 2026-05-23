-- Single source of truth for project-wide formatter configuration. Used in two
-- places:
--
--   1. conform.nvim (lua/plugins/conform.lua) reads `by_ft` to wire up
--      per-filetype formatting on real buffers (`gq`, `<leader>F`, etc.).
--   2. The markdown <leader>w pass (lua/config/options.lua) reads `fence_argv`
--      + `fence_aliases` to dispatch fenced code blocks through the matching
--      formatter via vim.system stdin/stdout.
--
-- Both maps are kept hand-aligned: when adding a language, add it to *both*
-- `by_ft` (so file editing picks it up) and `fence_argv` (so markdown blocks
-- pick it up). They diverge by necessity — conform uses its built-in named
-- formatters whose argv is owned by conform; the fence dispatch shells out
-- directly, so it needs explicit argv.

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

-- Markdown fence-tag -> argv for vim.system. Must read stdin / write stdout.
M.fence_argv = {
  python = { "ruff", "format", "--stdin-filename", "block.py", "-" },
  lua = { "stylua", "-" },
  go = { "gofmt" },
  rust = { "rustfmt", "--emit=stdout", "--quiet" },
  sh = { "shfmt", "-i", "2" },
  bash = { "shfmt", "-i", "2", "-ln", "bash" },
  zsh = { "shfmt", "-i", "2", "-ln", "bash" },
  c = { "clang-format", "--assume-filename=block.c" },
  cpp = { "clang-format", "--assume-filename=block.cpp" },
  objc = { "clang-format", "--assume-filename=block.m" },
  toml = { "taplo", "format", "-" },
  javascript = { "prettier", "--parser", "babel" },
  typescript = { "prettier", "--parser", "typescript" },
  json = { "prettier", "--parser", "json" },
  jsonc = { "prettier", "--parser", "json" },
  css = { "prettier", "--parser", "css" },
  scss = { "prettier", "--parser", "scss" },
  html = { "prettier", "--parser", "html" },
  yaml = { "prettier", "--parser", "yaml" },
  markdown = { "prettier", "--parser", "markdown" },
}

-- Common fence-tag aliases that aren't valid keys in `fence_argv` directly.
M.fence_aliases = {
  py = "python",
  js = "javascript",
  jsx = "javascript",
  javascriptreact = "javascript",
  ts = "typescript",
  tsx = "typescript",
  typescriptreact = "typescript",
  yml = "yaml",
  md = "markdown",
  rs = "rust",
  golang = "go",
  ["c++"] = "cpp",
  cc = "cpp",
  cxx = "cpp",
  hpp = "cpp",
  h = "c",
  ["objective-c"] = "objc",
  m = "objc",
  tml = "toml",
}

-- Resolve a fence tag to its argv, or nil if no formatter is configured or
-- the binary isn't on PATH (mason prepends its bin dir, so most installs are
-- discoverable automatically).
function M.resolve_fence_argv(tag)
  if not tag or tag == "" then
    return nil
  end
  local key = tag:lower()
  key = M.fence_aliases[key] or key
  local argv = M.fence_argv[key]
  if not argv or vim.fn.executable(argv[1]) ~= 1 then
    return nil
  end
  return argv
end

return M
