# GitHub Light theme migration — design

Date: 2026-06-29

## Goal

Improve readability by replacing Neovim's built-in `default` colorscheme with the
`projekt0n/github-nvim-theme` plugin, locked to **`github_light_high_contrast`**.
The theme's rich, per-language token highlighting (treesitter + LSP semantic
tokens) is the "language color scheme" the user asked for — adopted as-is. The
config becomes **light-only** (no dark mode).

## Background: what exists today

The config currently ships **no theme plugin**. It rides the built-in `default`
colorscheme and layers custom highlight overrides on top, every one written to
work on **both** backgrounds (colors chosen from `vim.o.background` at paint
time, re-applied on `ColorScheme` / `OptionSet background` autocmds). A
highlight-surface audit produced the complete inventory below.

Key facts established by the audit:
- `background` is **never** explicitly set anywhere in `lua/`.
- Eager config modules load at `init.lua:38-45`, **before** `lazy.setup("plugins")`
  (`init.lua:126`). So at module-require time the theme is not yet loaded.
- Tests split: `tests/minimal_init.lua` (unit) runs **themeless** against the
  default scheme; `tests/full_init.lua` (smoke/e2e) `dofile`s the real `init.lua`
  and registers all plugin specs but **does not install missing plugins**
  (`install.missing = false`) — the theme must already be in the warm lazy cache.
- No test asserts on a hex color or on `vim.o.background`. Tests assert highlight
  **group names**, definedness, the `LspReferenceText` underline attribute, and
  extmark presence — all theme-agnostic except where noted.

## Decisions (locked with the user)

1. **Scope:** GitHub **Light only**. Lock `background = "light"`; no dark mode.
2. **Variant:** `github_light_high_contrast` (maximum token contrast).
3. **Token colors:** adopt the theme's per-language highlighting as-is.
4. **Custom accents:** let the theme win — remove the magenta constants override;
   keep functional overrides but retune to GitHub colors.
5. **Token styles:** plain theme defaults (no italic comments / bold keywords).
6. **Dead dark code:** delete it (the config is light-only).
7. **Palette values:** the hex table below is the **starting** point; tune live
   against the real high-contrast white background after implementation.

## Changes

### 1. Add the theme plugin

New `lua/plugins/github-theme.lua`:

```lua
return {
  "projekt0n/github-nvim-theme",
  name = "github-theme",
  lazy = false,
  priority = 1000, -- load before other plugins; ColorScheme fires once, early
  config = function()
    require("github-theme").setup({}) -- plain defaults, no style overrides
    vim.cmd.colorscheme("github_light_high_contrast")
  end,
}
```

- Add `vim.opt.background = "light"` in `lua/config/options.lua` (near
  `termguicolors`). Explicit because config modules read `vim.o.background` at
  require-time, before the theme loads.
- Install the plugin and **pin it in `lazy-lock.json`** (the config warns on lock
  drift; `full_init` does not install missing plugins, so the smoke/e2e tests
  need it in the warm cache).

### 2. Removals (let the theme win)

- **Delete `lua/config/syntax_constants.lua`** (the 9-group magenta constants
  override: `@boolean`, `@number`, `@number.float`, `@constant`,
  `@constant.builtin`, `@constant.macro`, `@character`, plus the two Go LSP
  groups `@lsp.typemod.variable.readonly.go` / `.defaultLibrary.go`). GitHub
  colors all of these natively.
- **Remove `require("config.syntax_constants").setup()` from `init.lua:40`.**
  (`boot_spec` asserts init loads clean; the require must go with the module.)

### 3. `lsp_refs.lua` — keep the underline, make it compose

`ensure_highlight()` currently sets `LspReferenceText = { underline = true,
default = true }`. GitHub defines `LspReferenceText` as a subtle background, and
`default = true` would lose to it (underline never shows). Retune: set
`{ underline = true }` **without** `default = true`, so the underline composes on
top of the theme and stays distinct from a Visual selection. The unit test
(`tests/spec/unit/lsp_refs_spec.lua:42-49`, asserting `link == nil` and
`underline == true`) still passes (it runs themeless, and the new set keeps both
properties).

### 4. Retune functional overrides → GitHub light palette

Group **names** are unchanged; only the hardcoded hex moves. Starting values
(Primer-aligned, legible on the white high-contrast background):

| Group / palette key | File | Now | → GitHub light |
|---|---|---|---|
| `GitSignsAddLn` bg (`palette.git.add_ln_light`) | palette.lua | `#b8e0c4` | `#d2fbd9` |
| `GitSignsAddLnInline` / `ChangeLnInline` bg (`add_inline_light`) | palette.lua | `#8fd4a3` | `#abf2bc` |
| `GitSignsChangeLn` bg (`change_ln_light`) | palette.lua | `#ead090` | `#fdf2c0` |
| `GitSignsAddNr` | gitsigns.lua | `#fff` on `#4ea862` | fg `#0f5323` / bg `#abf2bc` |
| `GitSignsChangeNr` | gitsigns.lua | `#fff` on `#7a5d1a` | fg `#6f4e00` / bg `#f5d98a` |
| `GitSignsDeleteNr` | gitsigns.lua | `#fff` on `#c85050` | fg `#a0111f` / bg `#ffc9c2` |
| `GitSignsDeleteLn` / `DelPrev` sp (`palette.git.delete`) | palette.lua | `#c85050` | `#cf222e` |
| `SmartFilesAdded` | git_status_codes.lua | `#6cc070` | `#1a7f37` |
| `SmartFilesModified` | git_status_codes.lua | `#5a8ed4` | `#0969da` |
| `SmartFilesDeleted` | git_status_codes.lua | `#9a9a9a` | `#57606a` |
| `SmartFilesRenamed` | git_status_codes.lua | `#4cb0a0` | `#1b7c83` |
| `SmartFilesUntracked` | git_status_codes.lua | `#c08850` | `#bc4c00` |
| `SmartFilesBase` + `ReviewBaseActive` | git_status_codes.lua / review_base.lua | `#d896ff` | `#8250df` (lockstep) |
| `SmartFilesConflict` | git_status_codes.lua | `#d05a5a` | `#cf222e` |
| `palette.muted` (`SmartFilesUnstaged` / `*Legend`) | palette.lua | `#888888` | `#6e7781` |
| `SmartFilesLegendCount` | telescope_smart.lua | `#cccccc` | `#768390` |

The git-sign-number "chip" (white fg on a saturated bg) flips to **dark fg on a
light tint** so it reads on white. `SmartFilesBase` and `ReviewBaseActive` must
stay the same hue (the "base" concept is one purple across legend/picker/tree).

### 5. Light-only simplifications (delete dead code)

- In `gitsigns.lua` `paint()`: drop `local dark = vim.o.background == "dark"` and
  collapse the three `dark and X_dark or X_light` ternaries to the light values.
- In `palette.lua`: delete the now-unused `add_ln_dark`, `change_ln_dark`,
  `add_inline_dark` fields.
- Remove the dead `OptionSet background` autocmds in `gitsigns.lua` and
  `markdown_preview.lua` (background never flips). **Keep** the sibling
  `ColorScheme` autocmds — those re-assert our overrides after the theme paints.
- `markdown_preview.lua` `glow_style()` collapses to a constant `"light"`.

### 6. Keep as-is (theme-agnostic — visual verify only)

`block_guides` (links → `Whitespace`/`Comment`/`Function`), `MarkdownSectionAnchor`
(→ `Function`), `netrwTreeBar` (auto-derives fg from the live `Normal` bg on
`ColorScheme`), `statusline` (no colors), and all delegated plugin UI (telescope,
which-key, blink ghost-text, treesitter-context, nvim-tree icons/git decorator,
diagnostic signs — glyphs only, colors from theme). These inherit GitHub's
palette automatically; no code change.

## Affected files

- **New:** `lua/plugins/github-theme.lua`
- **Delete:** `lua/config/syntax_constants.lua`
- **Edit:** `init.lua` (drop require), `lua/config/options.lua` (set background),
  `lua/config/palette.lua` (retune git tints + muted, delete `*_dark`),
  `lua/plugins/gitsigns.lua` (retune + collapse dark branch + drop OptionSet),
  `lua/config/git_status_codes.lua` (retune SmartFiles*),
  `lua/config/review_base.lua` (retune ReviewBaseActive),
  `lua/config/telescope_smart.lua` (retune SmartFilesLegendCount),
  `lua/config/lsp_refs.lua` (drop `default=true`),
  `lua/config/markdown_preview.lua` (drop OptionSet autocmd, simplify glow_style),
  `lazy-lock.json` (pin the new plugin).

## Testing & verification

1. Remove the `syntax_constants` require (else `boot_spec` fails with a missing
   module). No other test references the module.
2. Install the theme and add it to `lazy-lock.json` so `full_init` (smoke/e2e)
   finds it in the warm cache.
3. Run `make test-unit test-smoke test-e2e` and `make lint`. **Sandbox must be
   off** (swap/parser/git writes fail under it — known constraint).
4. Live visual check in a real `nvim`: code tokens across languages, a git diff
   (signs, line backgrounds, inline word-diff, deletion underdash), the smart
   picker legend + status letters, block-guide dim/chain/active hierarchy,
   treesitter-context separator. Tune any hex from the table that doesn't read
   well on the white background.

## Out of scope

- Dark mode / dual-background support (removed).
- Per-language bespoke token tweaks beyond the theme's defaults.
- Italic/bold token styling (plain defaults chosen).
