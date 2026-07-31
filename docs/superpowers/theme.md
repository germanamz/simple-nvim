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
asserts a hex value or `vim.o.background`.** The only hex literals under `tests/`
are in `hl_spec.lua`, and only for the pure `hl.blend` function. The four specs
that call `nvim_get_hl` (`lsp_refs`, `hl`, `nvim_tree_decorators`,
`block_guides`) assert group names, definedness and the `LspReferenceText`
underline attribute — never a color.

So the table above is verified by eye, not by `make test`. After retuning any of
it, look at a real `nvim` on the high-contrast white background and check: code
tokens across several languages; a git diff (signs, line backgrounds, inline
word-diff, the deletion underdash); the smart picker's legend and status letters;
the block-guide dim/chain/active hierarchy; the treesitter-context separator.

## Out of scope

- Dark mode or dual-background support.
- Per-language token tweaks beyond the theme's defaults.
- Italic or bold token styling.
