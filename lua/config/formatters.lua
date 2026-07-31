-- Single source of truth for per-filetype formatter configuration. conform.nvim
-- (lua/plugins/conform.lua) reads `by_ft` to wire up on-demand formatting
-- (`<leader>F`), format-on-save, and `gq` via formatexpr on real buffers.
--
-- Most web/markup filetypes use an unconditional { "prettierd", "prettier" }
-- fallback chain: the warm prettierd daemon formats on save without Node's
-- per-run cold start, and plain prettier remains the fallback when the daemon
-- isn't installed. The four JS/TS filetypes are the exception: instead of that
-- fixed chain, they dispatch to whatever formatter config.js_toolchain detects
-- the project actually configures (see js_formatters below) — prettier's own
-- defaults disagree with a project whose style rules live in ESLint.

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
-- mid-session). conform.lua wires this to a BufWritePost on pyproject.toml so
-- toggling [tool.black] takes effect without restarting the session.
function M._clear_python_cache()
  python_cache = {}
end

-- prettierd-first: prettierd is a resident daemon that keeps the prettier engine
-- warm, so on save it answers in single-digit ms instead of paying Node's cold
-- start every time. Plain `prettier` stays as the fallback for machines where the
-- daemon isn't installed.
--
-- stop_after_first is required, not decorative: conform runs EVERY formatter in a
-- list by default (conform/init.lua:424), so without it both prettierd and
-- prettier run on every save — two full formatter passes against the 1000ms
-- format-on-save budget. The nested-{} syntax that used to mean "first available"
-- was replaced by this option (conform/init.lua:260).
local prettier = { "prettierd", "prettier", stop_after_first = true }

-- The formatter a detected toolchain maps to. Kept separate from by_ft because
-- the slot names come from config.js_toolchain, not from vim filetypes.
-- prettier = prettier (not a fresh { "prettierd", "prettier" } literal): js_formatters
-- deepcopies whatever this maps to before returning it, so aliasing the shared
-- chain here costs nothing and keeps the two lists from drifting apart.
local slot_to_conform = {
  biome = { "biome" },
  dprint = { "dprint" },
  oxfmt = { "oxfmt" },
  prettier = prettier,
  eslint = { "eslint_d" },
}

-- JS/TS formatting follows the project, not our preference. An unconfigured
-- project gets an EMPTY chain plus lsp_format = "never", so the buffer is left
-- exactly as typed: prettier's own default is singleQuote:false, and imposing it
-- on a repo whose style lives in ESLint is the defect this whole module exists to
-- fix. lsp_format must be set per-filetype — the global "fallback" in
-- lua/plugins/conform.lua is load-bearing for lua, where an absent stylua is meant
-- to fall through to lua_ls.
--
-- Only these four filetypes are slot-driven. json/css/markdown/yaml and friends
-- keep unconditional prettier below: the defect is prettier's quote default,
-- which is JS/TS-specific, and gating them would strip formatting from repos with
-- no JS toolchain at all (a Go repo full of markdown, this config's own docs).
---@param bufnr integer
---@return string[]
local function js_formatters(bufnr)
  local slot = require("config.js_toolchain").resolve(bufnr).formatter
  -- Copied, not shared: conform receives this table and consumers elsewhere treat
  -- the literals above as read-only.
  local chain = vim.deepcopy(slot and slot_to_conform[slot] or {})
  chain.stop_after_first = true
  chain.lsp_format = "never"
  return chain
end

-- Vim filetype -> ordered list of conform formatter names (or a function
-- of bufnr returning one — conform supports both).
M.by_ft = {
  python = python_formatters,
  -- stylua is Homebrew-managed, not mason-pinned: `make lint`/`make fmt` need
  -- it on the shell PATH, where mason's bin dir isn't (and a mason install
  -- would shadow the Homebrew binary inside nvim). Absent it, lsp_format =
  -- "fallback" hands Lua formatting to lua_ls.
  lua = { "stylua" },
  go = { "gofmt" },
  rust = { "rustfmt" },
  -- terraform fmt is a toolchain formatter (like gofmt / rustfmt above), not a
  -- mason tool; it needs the `terraform` CLI on PATH. Absent it, conform skips
  -- the formatter and lsp_format = "fallback" hands off to terraform-ls (which
  -- also shells out to `terraform fmt`), so behaviour degrades gracefully.
  terraform = { "terraform_fmt" },
  ["terraform-vars"] = { "terraform_fmt" },
  sh = { "shfmt" },
  bash = { "shfmt" },
  -- shfmt has no zsh dialect and parses zsh as bash: fine for bash-compatible
  -- scripts, but zsh-only syntax (e.g. `for i (1 2 3)`) fails to parse and
  -- notify_on_error surfaces it on save. bashls likewise excludes zsh (see
  -- lsp.lua); kept because most local zsh scripts are bash-compatible.
  zsh = { "shfmt" },
  c = { "clang_format" },
  cpp = { "clang_format" },
  objc = { "clang_format" },
  objcpp = { "clang_format" },
  toml = { "taplo" },
  javascript = js_formatters,
  javascriptreact = js_formatters,
  typescript = js_formatters,
  typescriptreact = js_formatters,
  json = prettier,
  jsonc = prettier,
  css = prettier,
  scss = prettier,
  html = prettier,
  yaml = prettier,
  markdown = prettier,
  mdx = prettier,
  -- prettier has a built-in graphql parser (.graphql / .gql schemas & queries).
  graphql = prettier,
}

return M
