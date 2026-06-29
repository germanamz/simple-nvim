-- Give constants a deliberate color. Neovim's built-in default colorscheme (this
-- config ships no theme plugin) paints code with only teal/blue/green and leaves
-- Constant, Boolean, Number and Character at the Normal fg (UNCOLORED) — so `nil`,
-- `true`, `42`, `iota` and named consts read as plain text, indistinguishable from
-- ordinary identifiers. We override the relevant groups to a warm magenta accent:
-- the one Nvim* palette slot the scheme reserves for neither code (teal/blue/green)
-- nor diagnostics (amber-warn/red-err), so a constant can't be confused with a
-- warning or an error. AAA contrast on both backgrounds.
--
-- TWO LAYERS are required, because two different highlighters paint these tokens:
--
--   1. TREESITTER (language-agnostic, priority 100). Covers everything a server's
--      semantic tokens DON'T claim: TS/JS true/42/null, Python None/True/numbers,
--      Lua nil/true/numbers, Rust true/numbers/'a'/const, and Go's own literals in
--      a no-LSP buffer. These groups otherwise link down to Constant/Number ->
--      Normal (uncolored), so the override is what actually colors them.
--
--   2. LSP SEMANTIC TOKENS (Go only, priority 125-127). gopls sends semantic
--      tokens BY DEFAULT and for `nil` emits type=variable with modifiers
--      {readonly, defaultLibrary}. Neovim builds the extmark hl groups WITH the
--      filetype suffix always present (vim/lsp/semantic_tokens.lua): in a `go`
--      buffer `nil` is painted by @lsp.typemod.variable.readonly.go and
--      @lsp.typemod.variable.defaultLibrary.go at priority 127, which OVERRIDES
--      treesitter (100). @lsp.type.variable -> @variable is uncolored, so without
--      this layer the semantic token FLATTENS nil back to plain and hides
--      treesitter's color. A treesitter-only override therefore cannot fix nil in
--      Go; we must also set the .go-suffixed LSP groups to the same color.
--
-- Why BOTH .go typemod groups, to the SAME color: for nil gopls sends modifiers
-- {readonly, defaultLibrary}; Neovim emits BOTH typemod marks at priority 127, and
-- equal-priority extmarks resolve by application order, which follows pairs() over
-- the modifier set and is nondeterministic. Setting only one would let nil render
-- plain on the runs where the other mark wins. Setting both identically makes the
-- result deterministic regardless of which fires last.
--
-- Why the .go SUFFIX (not the unsuffixed @lsp.typemod.variable.defaultLibrary):
-- ts_ls tags console/Math/JSON with type=variable modifier defaultLibrary (but NOT
-- readonly). An unsuffixed override would recolor those TS globals too. The `.go`
-- suffix confines the LSP layer to Go — matching this config's surgical,
-- per-language philosophy — and TS still gets its constants from the treesitter
-- layer (true/42/null carry no semantic token there). Go's readonly typemod fires
-- only on tokens that are BOTH type=variable AND readonly, which in Go is exactly
-- constants/nil/iota/true/false (Go has no readonly locals/params/fields), so the
-- LSP layer has no false positives. Predeclared builtin FUNCTIONS (len/make/append)
-- are type=function, never type=variable, so they keep their teal.

local M = {}

-- Treesitter captures that mean "a constant" — literals (booleans, numbers,
-- characters) and named-constant identifiers (@constant family). Fire only on
-- those, never on plain variables. Language-agnostic, painted at priority 100.
local TS_GROUPS = {
  "@boolean",
  "@number",
  "@number.float",
  "@constant",
  "@constant.builtin",
  "@constant.macro",
  "@character",
}

-- Go-scoped LSP semantic-token groups for nil/true/false/iota/named-consts. Both
-- are the priority-127 marks gopls produces for nil (see header); set identically.
local LSP_GROUPS = {
  "@lsp.typemod.variable.readonly.go",
  "@lsp.typemod.variable.defaultLibrary.go",
}

-- Warm magenta, the scheme's one unused accent slot. fg differs per background, so
-- we pick from vim.o.background at apply time (like gitsigns paint()): a dark fg on
-- the light theme, a bright fg on the dark theme. Change just these two to retune.
local LIGHT = "#470045"
local DARK = "#ffcaff"

-- Apply the constant color to every group on both layers. nvim_set_hl WITHOUT
-- default: @boolean/@constant.builtin/@number and the @lsp.*.go groups all already
-- carry default links, so a default=true set is a no-op against them and the
-- override would silently fail. We deliberately OVERRIDE, gitsigns-style.
local function paint()
  local fg = vim.o.background == "dark" and DARK or LIGHT
  for _, g in ipairs(TS_GROUPS) do
    vim.api.nvim_set_hl(0, g, { fg = fg })
  end
  for _, g in ipairs(LSP_GROUPS) do
    vim.api.nvim_set_hl(0, g, { fg = fg })
  end
end

function M.setup()
  -- Named group with clear=true so re-requiring this module (a test, :Lazy
  -- reload) replaces the handlers instead of stacking duplicates.
  local group = vim.api.nvim_create_augroup("syntax_constants", { clear = true })

  paint()
  -- ColorScheme resets highlight groups, wiping the overrides — re-apply (every
  -- sibling override module does this). OptionSet catches a bare
  -- `:set background=dark`, which changes the chosen hex but fires no ColorScheme
  -- (mirrors gitsigns paint()).
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = paint })
  vim.api.nvim_create_autocmd(
    "OptionSet",
    { group = group, pattern = "background", callback = paint }
  )
end

return M
