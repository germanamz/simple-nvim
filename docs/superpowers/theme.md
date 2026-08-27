# Theme

The config runs `projekt0n/github-nvim-theme` locked to
**`github_light_high_contrast`**, and is **light-only**. No dark mode.

The variant's per-language token highlighting — treesitter plus LSP semantic
tokens — is adopted as-is. That richness is the whole readability goal; the
config's own overrides are limited to functional colors the theme has no opinion
about.

## Before

The config shipped no theme plugin. It rode Neovim's built-in `default`
colorscheme with custom highlight overrides layered on top, every one written to
work on **both** backgrounds — colors chosen from `vim.o.background` at paint
time, re-applied on `ColorScheme` and `OptionSet background` autocmds. `background`
was never explicitly set anywhere.

## Locked decisions

1. GitHub **Light** only; `background` locked to `light`.
2. Variant `github_light_high_contrast`, for maximum token contrast.
3. The theme's per-language token colors are adopted unchanged.
4. Where the config had accent overrides, the theme wins. Functional overrides
   stay, retuned to GitHub's palette.
5. Plain theme token styles — no italic comments, no bold keywords.
6. Dead dark-mode code is deleted rather than left in place.

**Decisions 3 and 5 were since amended**, deliberately and in one place. Maximum
token contrast turned out to have a cost the variant choice could not see: it
applies to *comments* too, and a language that puts a doc comment above every
exported declaration ends up with prose as loud as code. `config.syntax_emphasis`
now dims comments (in two tiers) and bolds declaration names while leaving call
sites alone. Comments are still not italic and keywords are still not bold — the
emphasis is confined to the comment/declaration axis, which is the one that was
actually failing. See [token-emphasis.md](token-emphasis.md).

## Load order

This is the one non-obvious constraint. The eager `config.*` modules are required
at the top of `init.lua`, **before** `lazy.setup("plugins")` — so at module-require
time the theme is not loaded yet.

Two consequences:

- `lua/config/options.lua` sets `opt.background = "light"` explicitly, so
  background-sensitive defaults are correct from the first frame.
- `lua/plugins/github-theme.lua` uses `lazy = false` with `priority = 1000`, so
  the theme paints before any other plugin and its single `ColorScheme` event
  lands *after* the eager modules registered their `ColorScheme` autocmds. Those
  autocmds then re-assert the config's overrides on top of the theme's.

The `ColorScheme` autocmds are load-bearing and must stay. The sibling
`OptionSet background` autocmds were removed — the background never flips.

## What was deleted

- **`lua/config/syntax_constants.lua`** — the nine-group magenta constants
  override (`@boolean`, `@number`, `@number.float`, `@constant`,
  `@constant.builtin`, `@constant.macro`, `@character`, and two Go LSP groups).
  GitHub colors all of these natively. Its `require` had to go from `init.lua` in
  the same change, since `boot_spec` asserts init loads clean.
- **The dark branches** in `gitsigns.lua`'s `paint()` — `local dark = vim.o.background
  == "dark"` and the three `dark and X or Y` ternaries collapsed to the light
  values.
- **The `*_dark` palette fields** and the `OptionSet background` autocmds in
  `gitsigns.lua` and `markdown_preview.lua`.
- **`markdown_preview`'s `glow_style()`** collapsed to the constant `"light"`.

The last two entries are now history twice over: `markdown_preview.lua` has since
been rewritten to hand the file to a cmux markdown panel, so it no longer renders
anything itself and neither the autocmd nor `glow_style()` has a subject in the
current code. The light-only decision they record still stands everywhere else.

No `_dark` identifier or `background == "dark"` test remains in `lua/`.

## What the config still overrides

`lua/config/palette.lua` holds only values genuinely reused across modules;
role-specific colors that merely happen to look similar stay local to their own
highlight group.

The distinction that matters:

- **`M.muted` (`#6e7781`)** and the `SmartFiles*` / `ReviewBase*` groups are set
  with `default = true`, so a colorscheme can override them.
- **`M.git`** intentionally does **not** use `default = true`. The bespoke diff
  visualization — numbered line-number chips, full-line backgrounds, inline
  word-diff — is meant to win over the theme's plainer `GitSigns*` groups.
- **The `syntax_emphasis` / `decl_rules` groups** likewise skip `default = true`,
  and for a stronger reason: they are *re-derived from the live theme* on every
  `ColorScheme`, and a `default` set refuses to update a group that already
  exists — the emphasis would freeze at whatever the first colorscheme resolved.
  Same trap `lsp_refs`' `LspReferenceText` documents below.

| Role | Value | Set in |
| --- | --- | --- |
| `GitSignsAddNr` | `#0f5323` on `#abf2bc` | `palette.git`, painted by `plugins/gitsigns.lua` |
| `GitSignsChangeNr` | `#6f4e00` on `#f5d98a` | ditto |
| `GitSignsDeleteNr` | `#a0111f` on `#ffc9c2` | ditto |
| `GitSignsAddLn` | bg `#d2fbd9` | ditto |
| `GitSignsChangeLn` | bg `#fdf2c0` | ditto |
| `GitSignsAddLnInline` / `ChangeLnInline` | bg `#abf2bc` | ditto |
| `GitSignsDeleteLn` / `DelPrev` | `sp #cf222e`, underdashed | ditto |
| `SmartFilesAdded` | `#1a7f37` | `config/git_status_codes.lua` |
| `SmartFilesModified` | `#0969da` | ditto |
| `SmartFilesDeleted` | `#57606a` | ditto |
| `SmartFilesRenamed` | `#1b7c83` | ditto |
| `SmartFilesUntracked` | `#bc4c00` | ditto |
| `SmartFilesConflict` | `#cf222e` | ditto |
| `SmartFilesBase` | `#8250df` | ditto |
| `ReviewBaseActive` | `#8250df` | `config/review_base.lua` |
| `SmartFilesUnstaged`, `SmartFilesLegend`, `ReviewBaseLegend`, `BuffersLegend`, `LspPickerLegend` | `palette.muted` | various |
| `SmartFilesLegendCount`, `BuffersLegendFlag`, `LspPickerLegendKey` | `#768390`, bold | various |
| `Comment` | `palette.muted` | `config/syntax_emphasis.lua` |
| `@comment.documentation` | `palette.muted` blended `0.82` toward the background | ditto |
| `@lsp.type.comment` | cleared, so treesitter's comment tiers survive | ditto |
| `@function`, `@function.method`, `@type.definition` | the theme's own colour **+ bold** | ditto |
| `@function.call`, `@function.method.call`, `@type` | the theme's own colour, pinned non-bold | ditto |
| `@lsp.type.function` / `.method` / `.type` | pinned to the plain "use" weight | ditto |
| `@lsp.typemod.<t>.definition` / `.declaration` | linked to the bold declaration group | ditto |
| `@module`, `@lsp.type.namespace` | `#010409` — neutral; they were the *exact* keyword red | ditto |
| `@variable.member`, `@property`, `@lsp.type.property` | `#971368` magenta; they were the same blue as constants | ditto |
| `@constant*`, `@number`, `@boolean`, `@lsp.typemod.variable.defaultLibrary` | `#0550ae`; lightened away from strings | ditto |
| `@type.definition` | `#702c00` — the type colour, with bold doing the "definition" work | ditto |
| `DeclRule` | `sp` = `Comment` blended `0.45`, underlined | `config/decl_rules.lua` |
| `GitSignsCurrentLineBlame` | `palette.muted` blended `0.82`; gitsigns links it to `NonText`, which this theme paints near-black | `plugins/gitsigns.lua` |

The git line-number "chip" is dark foreground on a light tint. The old
white-on-saturated chip washed out on a white background.

`SmartFilesBase` and `ReviewBaseActive` must stay the same hue — "the base" is one
purple across the picker legend, the picker rows and the tree. Retune them in
lockstep.

## Theme-agnostic by design

These need no color code and inherit GitHub's palette automatically:
`block_guides` (links to `Whitespace` / `Comment` / `Function`),
`nvim_tree_context` (links to `NvimTreeNormal` / `TreesitterContextBottom`),
`MarkdownSectionAnchor` (links to `Function`), `netrwTreeBar` (derives its
foreground from the live `Normal` background on `ColorScheme`), the statusline
(no colors at all), and all delegated plugin UI — telescope, which-key, blink
ghost-text, treesitter-context, nvim-tree icons and git decorator, diagnostic
signs.

One retune was needed for composition rather than color: `lsp_refs`'
`ensure_highlight()` sets `LspReferenceText = { underline = true }` **without**
`default = true`. GitHub defines `LspReferenceText` as a subtle background, and a
`default` set would lose to it — the underline would never show. Dropping
`default` composes the underline on top of the theme's background and keeps
references distinct from a Visual selection.

## Nothing in the suite guards a color

The tests are theme-agnostic on purpose, and that cuts both ways: **no spec
asserts that a group is a particular colour.** Six specs call `nvim_get_hl` —
`lsp_refs`, `hl`, `nvim_tree_decorators`, `block_guides`, `syntax_emphasis` and
the `decl_rules` e2e — and what they assert is group names, definedness, and
*attributes*: the `LspReferenceText` underline, the `DeclRule` underline, `bold`
on each declaration capture and its absence on each call-site capture.

Two of them touch colour without pinning one, and the distinction is worth
keeping if you add more:

- `hl_spec.lua` has hex literals, but only as inputs to the pure `hl.blend`
  function — arithmetic, not theme.
- `syntax_emphasis_spec.lua` stands up a miniature fixture theme (hex literals
  it supplies itself, never read from the real colorscheme) and then asserts
  *relationships*: that `Comment` ends up at `palette.muted` — the shared
  constant, not a literal — and that `@comment.documentation` has a **higher
  relative luminance** than `Comment`, i.e. is dimmer on a light background.
  Retune `palette.muted` or `DOC_ALPHA` and the spec still passes; break the
  wiring and it fails.

So the table above is verified by eye, not by `make test`. After retuning any of
it, look at a real `nvim` on the high-contrast white background and check: code
tokens across several languages; a git diff (signs, line backgrounds, inline
word-diff, the deletion underdash); the smart picker's legend and status letters;
the block-guide dim/chain/active hierarchy; the treesitter-context separator; and
a comment-dense Go file for the two comment tiers, the bold `func` names and the
declaration hairlines.

## Out of scope

- Dark mode or dual-background support.
- Per-*filetype* token rules. The config does now retune token colours — see
  [token-emphasis.md](token-emphasis.md) for the comment tiers, the declaration
  bolding and the four rebalanced hues — but every one of them overrides a
  capture or semantic-token group, so it applies to whatever language uses that
  group. Nothing branches on `filetype`. The two files under `after/queries/`
  (`go/highlights.scm`, `gotmpl/injections.scm`) patch missing upstream
  *captures* and *injections*, never a colour.
- Italic token styling.
