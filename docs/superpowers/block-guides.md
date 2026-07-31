# Block scope guides

`lua/config/block_guides.lua` — vertical guides showing which block the cursor is
in and how that block nests inside its parents. Toggle with `<leader>ub`
(default on).

## The visual model

Dim guides are drawn on every foldable block. The cursor's ancestor chain —
its innermost block plus each parent — is the same geometry rendered brighter.
Siblings the cursor is not inside stay dim.

```
 11   const a = 1
 12   function foo() {
 13 │   const x = 1
 14 │   if (other) {           ← sibling block: its guide stays dim
 15 │ ┊   skip()
 16 │   }
 17 │   if (cond) {
 18 │ ┃   doThing()            ← cursor: 2 levels deep → 2 parallel lines
 19 │ ┃   more()
 20 │   }
 21   }
 22   const b = 2
```

Four rules carry the design:

1. **One line per level, at that block's own body indentation.** Position conveys
   depth, so no single bar has to change shade to mean two different things.
2. **Parents in, siblings out.** The chain is the cursor's innermost foldable
   block and every foldable ancestor. A block the cursor is not inside never
   enters it.
3. **Moving the cursor changes colors, not geometry.** Guides exist regardless of
   cursor position, so nothing appears or disappears and there is nothing to
   flicker.
4. **Overlay, never reflow.** Bars are painted onto existing indentation
   whitespace. The code never shifts horizontally and the gutter width never
   changes.

Three highlight groups, all `default = true` links so a colorscheme can override
them, re-applied on `ColorScheme`:

| Group | Meaning | Default link |
| --- | --- | --- |
| `BlockGuide` | any foldable block | `Whitespace` |
| `BlockGuideChain` | a parent in the cursor's chain | `Comment` |
| `BlockGuideActive` | the cursor's innermost block | `Function` |

## Block detection

A "block" is a node the language's `folds` query captures — so highlighted blocks
match foldable regions exactly, including large object/array/table literals.

`collect_foldable_blocks` mirrors core's treesitter foldexpr
(`runtime/lua/vim/treesitter/_fold.lua`) rather than querying the top-level tree,
which matters three ways:

- **Injected languages** (JS or CSS inside HTML, SQL inside Lua) are folded by
  their own language's query. `parser:for_each_tree` plus
  `vim.treesitter.query.get(ltree:lang(), "folds")` picks up each tree's own
  query, so embedded code gets guides too.
- **Quantified `+` fold groups** — a run of imports captured as one `@fold` —
  collapse into a single block. `iter_matches` groups the nodes; the span runs
  from the first to the last.
- **Range directives and the `end_col == 0` correction**, applied through
  `vim.treesitter.get_range` with the match metadata, keep extents identical to
  what `foldexpr()` actually folds.

There is no fallback for a language without a `folds.scm`. Every parser this
config installs ships one; a folds-less language simply shows no guides.

Sibling exclusion is free: only blocks whose extent contains the cursor row enter
the chain, and the innermost is the one with the smallest extent (deeper column
breaking a tie).

## Rendering

A decoration provider (`nvim_set_decoration_provider`), not stored extmarks.

- `on_win` runs once per window per redraw. It checks eligibility, refreshes the
  foldable-block cache, filters to blocks intersecting the visible viewport
  `[toprow, botrow]`, and computes the cursor's chain over that filtered list.
- `on_line` runs per visible line and emits **ephemeral** overlay extmarks
  (`ephemeral = true`, `virt_text_win_col = <col>`, `hl_mode = "combine"`).

Ephemeral marks live only for the current redraw: no buffer mutation, no extmark
accumulation, nothing to clear. Neovim calls `on_line` only for lines actually
being drawn, so cost is bounded to the viewport by construction.

### Where the implementation went past the design

- **Viewport pre-filter.** The design had `on_line` scan every block in the
  buffer. `on_win` now narrows to blocks intersecting the visible rows. An outer
  block starting above the viewport still intersects (`b.s <= botrow and
  b.e >= toprow`), so nesting survives; the cursor is always on screen, so its
  whole chain survives too. `chain_at` runs on the filtered list to keep indices
  aligned with what `on_line` iterates.
- **A chain-signature gate instead of a debounce.** The design debounced the
  cursor-chain recompute. What actually ships compares a stable signature of the
  chain (`s:e:col` per block, sorted) and forces no redraw at all when moving
  within the same block. The repaint that does happen is coalesced to once per
  event-loop tick, per window.

  **The repaint must be `valid = false`.** Both call sites pass it
  (`block_guides.lua:245` in `toggle()`, `:302` in the cursor handler). Ephemeral
  marks are re-emitted only for lines Neovim actually redraws, and a *valid*
  redraw skips lines it believes are unchanged — so a partial repaint would leave
  the old tier colors on every line it skipped. Nothing catches this: it is a
  screen-only defect, and the e2e spec asserts computed guides, not rendered
  state. Do not "optimize" the flag away.
- **The block cache is keyed on `(changedtick, filetype)`.** A `:set filetype=`
  swaps the treesitter parser *without* bumping the tick, so a tick-only key kept
  rendering the previous language's blocks until the next edit. Keyed in
  `blocks_for` rather than by a `FileType` autocmd, so callers that never run
  `setup()` — the unit specs — get the same invalidation.
- **`tabstop` is hoisted to `on_win`** and passed down; the `vim.bo` read was a
  metatable hop per visible row on a hot path. `guides_for_row` keeps a fallback
  read so direct callers still work.
- **`setup()` is idempotent** and per-window state is dropped on `WinClosed`.

## API

Pure functions first — they are what the unit tier tests, with no parser and no
UI.

| Function | Kind | Contract |
| --- | --- | --- |
| `_indent_width(line, tabstop)` | pure | Display width of leading whitespace, honoring tab stops |
| `chain_at(blocks, cursor_row)` | pure | `{ active = <index\|nil>, set = { [index] = true } }`; active is the innermost containing block |
| `guides_at(blocks, chain, row, row_indent)` | pure | `{ { col, tier } }` sorted by col; tier is `active` / `chain` / `dim` |
| `_chain_signature(blocks, chain)` | pure | Stable string identity of a chain, for the redraw gate |
| `collect_foldable_blocks(buf)` | treesitter | `{ s, e, col }` per foldable block, 0-indexed rows |
| `blocks_for(buf)` | cached | `collect_foldable_blocks` keyed on `(changedtick, filetype)` |
| `guides_for_row(blocks, chain, buf, row, tabstop)` | reads buffer | Guides for one row; blank lines use `math.huge` so every covering guide draws through the gap |
| `is_enabled()` / `toggle()` / `setup()` | effect | Wired from `init.lua` |

## Eligibility and limits

Active only where treesitter is running and the filetype is not excluded
(`""`, `markdown`, `mdx`, `help`, `text`). An ineligible buffer returns `false`
from `on_win`, so `on_line` never runs and per-line cost is zero.

Two accepted limitations:

- **Dedented structural lines** (`else`, `elseif`, `case`, `except:` at the header
  column) show a one-line gap in that block's *own* bar. The guide column is
  occupied by code there, so drawing would overlay and corrupt the keyword. Parent
  bars at shallower columns run through continuously.
- **Horizontal scroll.** `virt_text_win_col` pins bars to absolute window columns
  and does not track `leftcol`, so a horizontally scrolled window draws its guides
  at the wrong columns. The design dismissed this on the grounds that code buffers
  soft-wrap; they no longer do — `lua/config/options.lua` sets `wrap = false`
  globally. In practice guides are only wrong while scrolled right past the
  indentation, and correct again on the way back, so this has not been worth
  fixing. Tracking `leftcol` would mean subtracting it from each guide column in
  `on_line` and dropping guides that fall left of the window.
