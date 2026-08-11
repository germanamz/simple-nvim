-- Token emphasis: comments recede, declaration names step forward.
--
-- github_light_high_contrast paints every comment #4b535d — 7.8:1 on the white
-- background, against 20.5:1 for a plain identifier and 10.2:1 for a function
-- name. In a language whose convention is a doc comment above every exported
-- declaration (Go, most of all) that makes prose as loud as code: the file reads
-- as a wall of grey sentences and the `func` lines stop announcing themselves.
-- Two moves, applied together:
--
--   1. Comments drop to palette.muted (4.5:1 — GitHub's own comment grey on its
--      non-high-contrast light theme), and DOC comments one step further still,
--      so the block above a declaration reads as a caption rather than a
--      paragraph. Inline `// why` notes inside a body — the ones actually worth
--      reading mid-scan — stay in the louder tier.
--   2. Declaration NAMES go bold while call sites keep exactly the weight they
--      have, so `func New` and `func (s *Server) ListenAndServe` anchor the eye
--      without introducing a second colour.
--
-- Both moves have to be made twice, because two highlighters paint these tokens
-- and the louder one wins:
--
--   • treesitter, priority 100. Its queries already separate declarations
--     (@function, @function.method, @type.definition) from uses
--     (@function.call, @function.method.call, @type), and doc comments
--     (@comment.documentation) from ordinary ones (@comment).
--   • LSP semantic tokens, priority 125 — and gopls sends them. It paints
--     @lsp.type.function on a declaration AND on every call site (both resolve
--     up the @-hierarchy to @function), and @lsp.type.comment across a whole doc
--     comment (resolves to @comment). Left alone that would bold the call sites
--     and flatten the two comment tiers back into one.
--
-- So the LSP layer is taught the same distinction: @lsp.type.<t> is pinned to
-- the *use* highlight, only the occurrences carrying LSP's `definition` /
-- `declaration` modifier are re-bolded, and @lsp.type.comment is cleared
-- outright so treesitter's comment tiers survive.
--
-- Beyond palette.muted nothing here hardcodes a colour: the bold groups are
-- re-derived from whatever the live colorscheme resolved, on every ColorScheme.
local M = {}

local hl = require("util.hl")
local palette = require("config.palette")

-- Weight of palette.muted kept in the DOC-comment tier; the rest washes toward
-- the background. 0.82 lands ~3.2:1 — a visible step below an ordinary
-- comment's 4.5:1, without dropping to chrome level.
M.DOC_ALPHA = 0.82

-- --- Token hues -------------------------------------------------------------
--
-- Four roles were retuned because the variant crowded them together. Measured
-- with CIEDE2000 against a real Go buffer with gopls attached; the numbers in
-- brackets are before -> after, and anything under ~15 is uncomfortable for
-- tokens that sit side by side.
--
--   • FIELDS moved off blue to magenta [32.7 -> 46.5 vs functions]. `a.db.Exec`
--     put a blue field and a teal method either side of one dot, which is the
--     hardest place to ask a reader to separate two cool colours.
--   • MODULES were painted the EXACT red of `func` / `if` / `return` [0.0 ->
--     35.8]. They are now neutral, like the variables they behave like: a
--     qualifier is scaffolding, and `errors.Is` should read as one quiet
--     namespace and one loud verb.
--   • CONSTANTS lightened so they part from strings [9.0 -> 15.7]. The two
--     shared hue 292.1 deg exactly and differed only in lightness, which is why
--     no contrast tweak could have separated them.
--   • TYPE DEFINITIONS take the type colour instead of a near-black of their own
--     [4.0 vs plain variables -> same hue as @type, separated by bold]. The
--     bold from EMPHASIS is what marks a definition; the colour should say
--     "type", and it now does.
--
-- Deliberately NOT introduced: green. Functions are teal, and every green that
-- clears the other roles lands within ~21 of it — swapping one hard pair for
-- another. Seven hue families is what this palette holds.
M.TOKENS = {
  -- Namespace qualifiers, neutral like an ordinary identifier.
  ["@module"] = 0x010409,
  ["@lsp.type.namespace"] = 0x010409,
  -- Struct fields and properties.
  ["@variable.member"] = 0x971368,
  ["@property"] = 0x971368,
  ["@lsp.type.property"] = 0x971368,
  -- nil / true / false / numbers.
  ["@constant"] = 0x0550ae,
  ["@constant.builtin"] = 0x0550ae,
  ["@number"] = 0x0550ae,
  ["@boolean"] = 0x0550ae,
  ["@lsp.type.number"] = 0x0550ae,
  -- gopls sends `nil` as a defaultLibrary-modified variable, at priority 125 —
  -- without this the treesitter constant colour never survives to the screen.
  ["@lsp.typemod.variable.defaultLibrary"] = 0x0550ae,
  -- A definition is a type; bold is what makes it a definition.
  ["@type.definition"] = 0x702c00,
}

-- decl — the treesitter capture on a DECLARATION's name; this is what goes bold.
-- use  — the capture on a USE of the same thing. Left at its current weight, and
--        the LSP type token is pinned here so call sites don't inherit the bold.
-- lsp  — the LSP semantic-token type whose `definition` / `declaration` modifier
--        marks the declaring occurrence.
M.EMPHASIS = {
  { decl = "@function", use = "@function.call", lsp = "function" },
  { decl = "@function.method", use = "@function.method.call", lsp = "method" },
  { decl = "@type.definition", use = "@type", lsp = "type" },
  -- Same treesitter pair, second LSP token type. Servers split "a named type"
  -- across `type` and `class` (gopls sends type, ts_ls sends class), and
  -- treesitter captures a TS class name as plain @type either way — so without
  -- this the LSP layer paints class declarations and references identically.
  { decl = "@type.definition", use = "@type", lsp = "class" },
}

-- The rest of each bolded capture's FAMILY, which must stay plain.
--
-- This exists because the groups we bold are also family roots. An undefined
-- `@a.b` resolves up the @-hierarchy to `@a`, so bolding `@function` bolds every
-- `@function.*` the colorscheme happens to leave undefined — and github-theme
-- leaves `@function.macro` undefined, which nvim-treesitter puts on macro USE
-- sites. Every `println!` / `vec!` / `format!` in a Rust buffer would render at
-- declaration weight. Listed rather than discovered because an undefined group
-- does not exist to be scanned for; this is the complete standard capture set
-- for these two families, which is a treesitter convention, not a theme detail.
M.FAMILY = {
  ["@function"] = { "@function.call", "@function.builtin", "@function.macro" },
  ["@function.method"] = { "@function.method.call" },
  ["@type.definition"] = {},
}

-- LSP modifier names meaning "this occurrence is where the thing is declared".
-- gopls sends `definition`; rust-analyzer and lua_ls send `declaration`. Wiring
-- both costs nothing — a group no server ever emits simply never matches.
M.DEFINING_MODIFIERS = { "definition", "declaration" }

-- The colorscheme's EFFECTIVE definition of `group` (link = false resolves
-- through links), as a table ready to hand back to nvim_set_hl. A group the
-- theme defines only as a link would otherwise collapse to bold-on-default-
-- foreground when we re-assert it.
local function resolved(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

function M.apply()
  -- --- Token hues ---------------------------------------------------------
  -- First, so the declaration pass below snapshots the RETUNED weights: it reads
  -- @type.definition's colour in order to re-assert it with bold, and reading
  -- the old one would undo this.
  for group, fg in pairs(M.TOKENS) do
    vim.api.nvim_set_hl(0, group, { fg = fg })
  end

  -- --- Comments -----------------------------------------------------------
  -- @comment links to Comment, and @lsp.type.comment is about to be cleared, so
  -- Comment alone covers ordinary comments in every highlighter. Setting the
  -- base group (rather than only @comment) also covers buffers with no
  -- treesitter parser — notably the large files where the highlight guard
  -- deliberately falls back to vim syntax.
  vim.api.nvim_set_hl(0, "Comment", { fg = palette.muted })
  -- The theme defines @comment.documentation outright rather than as a link, so
  -- it needs its own value to land in the dimmer tier. The fallback is Comment,
  -- not define_dim's default of NonText: NonText is the dimmest builtin group on
  -- a dark background, but this theme paints it #20252c — near-black. Failing to
  -- blend should drop doc comments back to the ordinary tier, not make them the
  -- loudest text on screen.
  hl.define_dim("@comment.documentation", {
    color = palette.muted,
    alpha = M.DOC_ALPHA,
    fallback = "Comment",
  })
  -- Cleared, not dimmed: a defined-but-empty group contributes no attributes, so
  -- gopls' comment token stops overpainting treesitter's two tiers.
  vim.api.nvim_set_hl(0, "@lsp.type.comment", {})

  -- --- Declarations -------------------------------------------------------
  -- Bolding a capture is not local to that capture: other groups reach it, by an
  -- explicit link or by the @-hierarchy, and inherit the bold on EVERY
  -- occurrence rather than only on declarations. So the whole pass is ordered
  -- around one rule — work out every plain weight FIRST, bold second, re-pin
  -- third. Reading a plain weight after the bold lands would read the bold back.

  -- Every group the colorscheme currently defines. Membership is what separates
  -- "defined empty on purpose" (e.g. github-theme's @function.builtin, which
  -- blocks the hierarchy deliberately) from "absent, and therefore resolves up
  -- to the group we are about to bold".
  local defined = vim.api.nvim_get_hl(0, {})

  local is_decl = {}
  for _, e in ipairs(M.EMPHASIS) do
    is_decl[e.decl] = true
  end
  -- Groups we are about to create ourselves. They link INTO a bolded group on
  -- purpose, so the leak scan below must not "fix" them on the second apply().
  local ours = {}
  for _, e in ipairs(M.EMPHASIS) do
    for _, mod in ipairs(M.DEFINING_MODIFIERS) do
      ours["@lsp.typemod." .. e.lsp .. "." .. mod] = true
    end
  end

  -- pin[group] = the weight to re-assert after boldening.
  local pin = {}
  for _, e in ipairs(M.EMPHASIS) do
    local decl_plain = resolved(e.decl)
    decl_plain.bold = false
    -- The use capture, plus the rest of the family. A member the theme leaves
    -- undefined has no weight of its own and would fall through to the bolded
    -- root, so it inherits the declaration's plain weight instead.
    local family = { e.use }
    for _, sibling in ipairs(M.FAMILY[e.decl] or {}) do
      family[#family + 1] = sibling
    end
    for _, group in ipairs(family) do
      if defined[group] then
        local own = resolved(group)
        own.bold = false
        pin[group] = own
      else
        pin[group] = decl_plain
      end
    end
    -- The LSP layer paints declarations and uses alike, so its type token takes
    -- the USE weight — not the declaration's. They differ where the theme colours
    -- a definition apart from a reference (@type.definition is #14161b against
    -- @type's #702c00), and taking the declaration's would repaint every type
    -- reference in the buffer.
    pin["@lsp.type." .. e.lsp] = pin[e.use]
  end

  -- Groups that LINK into something we are about to bold. github-theme points
  -- @lsp.type.class at @function; Neovim's own defaults point
  -- @lsp.type.typeParameter at @type.definition. Left alone, every TypeScript
  -- class reference and every generic `T` would render bold — the exact
  -- declaration/use collapse this module exists to prevent. Discovered rather
  -- than listed, so a theme update cannot quietly reintroduce the leak.
  for name, def in pairs(defined) do
    if def.link and is_decl[def.link] and not ours[name] and not pin[name] then
      local target = resolved(def.link)
      target.bold = false
      pin[name] = target
    end
  end

  for _, e in ipairs(M.EMPHASIS) do
    local bold = resolved(e.decl)
    bold.bold = true
    vim.api.nvim_set_hl(0, e.decl, bold)
  end

  for group, weight in pairs(pin) do
    vim.api.nvim_set_hl(0, group, weight)
  end

  -- Only the modifier meaning "declared here" re-bolds, on top of the plain
  -- @lsp.type.<t> pinned above.
  for _, e in ipairs(M.EMPHASIS) do
    for _, mod in ipairs(M.DEFINING_MODIFIERS) do
      vim.api.nvim_set_hl(0, "@lsp.typemod." .. e.lsp .. "." .. mod, { link = e.decl })
    end
  end
end

function M.setup()
  -- Idempotent: a second call (:Lazy reload, a re-requiring test) would
  -- otherwise stack a second ColorScheme handler.
  if M._did_setup then
    return
  end
  M._did_setup = true
  local group = vim.api.nvim_create_augroup("syntax_emphasis", { clear = true })
  M.apply()
  -- Load-bearing, and the reason apply() re-derives instead of caching: this
  -- module is required from init.lua BEFORE the theme plugin loads, so the first
  -- apply() runs against the default colorscheme and this re-runs it against
  -- GitHub's (see docs/superpowers/theme.md, "Load order").
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply })
end

return M
