# Block Scope Guides Design

**Date:** 2026-06-08
**Status:** Approved (pending implementation plan)
**Repo:** personal Neovim 0.11+ config (`~/.config/nvim`)

## Goal

When the cursor sits inside a nested block, show — at a glance — *which* block
it's in and how that block nests inside its parents. Concretely: with the cursor
inside an `if` that lives inside a function, draw one vertical guide line for the
`if` (the cursor's block) and one for the enclosing function, so the nesting
chain is visible. Sibling blocks the cursor is *not* inside are not part of the
chain.

The feature builds on the treesitter the config already runs (`nvim-treesitter`
`main` branch, native 0.11+ API) and the fold structure it already relies on.

## Non-goals

- Animation of the guide lines (no fade/slide; instant draw — fastest, no
  flicker). `mini.indentscope`-style animation is explicitly out.
- A new plugin dependency. This is a self-contained `lua/config/` module.
- Generic indentation guides decoupled from block structure. Guides represent
  treesitter *foldable blocks*, not raw indent levels.
- Highlighting inside non-code buffers (markdown prose, help, dashboards, etc.).

## Visual model (locked)

Legend: `┊` = dim baseline guide (any foldable block, always present), `│` = a
parent in the cursor's chain (brighter), `┃` = the cursor's innermost block
(brightest). Bars sit *in* the indentation of each block's body.

```
 11   const a = 1
 12   function foo() {
 13 │   const x = 1
 14 │   if (other) {           ← SIBLING block — its guide stays dim baseline
 15 │ ┊   skip()
 16 │   }
 17 │   if (cond) {
 18 │ ┃   doThing()            ← cursor (2 levels deep → 2 parallel lines)
 19 │ ┃   more()
 20 │   }
 21   }
 22   const b = 2
```

The function body (13–20) is a chain parent → `│`. The cursor's `if (cond)` body
(18–19) is innermost → `┃`. The sibling `if (other)` body (15) is a foldable
block too, so it still gets a guide — but a *dim baseline* `┊`, never the bright
chain treatment. Line 15 shows both: the function's chain `│` and the sibling's
dim `┊`, at their respective indent levels.

Rules:

1. **Parallel lines, one per level.** Each block in the cursor's ancestor chain
   gets its own vertical line, positioned at that block's body indentation. Two
   levels deep → two parallel lines. Position (not just color) conveys depth, so
   no single bar has to change shade to mean different things.
2. **Parents included, siblings excluded.** The chain is the cursor's innermost
   foldable block plus every foldable ancestor up to the top. A foldable block
   the cursor is not inside (e.g. the `if (other)` above) is *not* in the chain.
3. **Persistent dim guides.** Dim guides are drawn for foldable blocks
   regardless of cursor position; the active chain is the same guides rendered in
   a brighter highlight. Moving the cursor changes *colors*, not *geometry* —
   lines don't appear/disappear, so there's nothing to flicker.
4. **Overlay, never reflow.** Bars are painted onto existing indentation
   whitespace via overlay virtual text. The code never shifts horizontally; the
   gutter width never changes. Depth changes are a repaint, not a relayout.

### Tiers

Three highlight groups, linked to sensible colorscheme defaults so the feature
works on any theme and is overridable:

| Group | Meaning | Default link |
|---|---|---|
| `BlockGuide` | dim baseline guide (any foldable block) | `Whitespace` / `NonText` |
| `BlockGuideChain` | a parent block in the cursor's chain | `Comment` |
| `BlockGuideActive` | the cursor's innermost block | `Function` (or `Special`) |

The innermost block is rendered with `BlockGuideActive` (brightest); each
ancestor with `BlockGuideChain`; everything else with `BlockGuide`. Singling out
the innermost answers the core question ("which block am I *in*?") even when the
chain is deep. Exact colors are tuned during implementation; the links above are
the starting point.

## Block detection

"Block" = a treesitter node the language considers **foldable**. This is
language-agnostic and reuses the fold queries the config already depends on
(`foldexpr = vim.treesitter.foldexpr`), so highlighted blocks match foldable
regions exactly — including large data literals (objects/arrays/tables), which
the user chose to include ("everything foldable").

**Ancestor chain.** From the node at the cursor, walk up the treesitter tree to
the root, keeping each node that is foldable. That ordered list (innermost →
outermost) is the chain. Each chain node yields a `{start_row, end_row,
indent_col}` triple, where `indent_col` is the column of the block body's
indentation (where its guide line is drawn).

**Foldability test.** Collected by mirroring Neovim's own treesitter foldexpr
(`runtime/lua/vim/treesitter/_fold.lua`): `parser:parse(true)` then
`parser:for_each_tree`, and for each tree resolve **that tree's own language**
`folds` query (`vim.treesitter.query.get(ltree:lang(), "folds")`), iterating with
`iter_matches` and capturing `@fold`. This matters in three ways the naive
top-level-only approach gets wrong:

- **Injected languages** (JS/CSS in HTML, SQL-in-Lua, etc.) are folded by their
  own language's query, so embedded code gets guides too.
- **Quantified `+` fold groups** (a run of imports captured as one `@fold`)
  collapse into a single block — `iter_matches` groups the nodes; the span runs
  from the first node to the last.
- **Range directives + the `end_col == 0` correction** (`vim.treesitter.get_range`
  with the match metadata) keep extents identical to what `foldexpr()` folds.

Computed once per `(buf, changedtick)` and cached. No fallback for languages
without a `folds.scm`: every parser this config installs ships one, so the
heuristic-node fallback considered earlier is dropped as YAGNI — a folds-less
language simply shows no guides.

**Sibling exclusion** is automatic: only nodes on the cursor's root path are in
the chain, so a sibling block (not an ancestor) never enters it.

## Rendering architecture

**Mechanism: decoration provider** (`nvim_set_decoration_provider`), not stored
extmarks.

- `on_win(_, winid, bufnr, toprow, botrow)` — once per window redraw: confirm the
  buffer is eligible (treesitter active, code filetype), and ensure the
  per-buffer foldable-range cache is current for `changedtick`.
- `on_line(_, winid, bufnr, row)` — per visible line per redraw: decide which
  guide columns this row should have and at which tier, then emit **ephemeral**
  extmarks (`nvim_buf_set_extmark` with `ephemeral = true`,
  `virt_text_pos = "overlay"`, `virt_text_win_col = <col>`) for each guide.

Ephemeral marks live only for the current redraw — no buffer mutation, no
extmark accumulation, no explicit clearing. Neovim calls `on_line` only for lines
actually being drawn, so work is inherently bounded to the visible viewport.

**Cursor chain cache.** The active chain (which `(rows, cols)` are
`BlockGuideChain` vs `BlockGuideActive`) is recomputed on `CursorMoved` /
`CursorMovedI`, debounced, and stored per window. `on_line` reads this cache to
pick the tier — it does no treesitter work itself. A redraw is requested after
the chain changes so the viewport repaints in the new colors.

**Why this is the performance ceiling.** It uses the same mechanism
`snacks.indent` uses internally, but does strictly less: only our guides, no
general-purpose indent config. Per-redraw cost is O(visible lines × visible
depth); per-cursor-move cost is one bounded tree walk reusing the cached fold
ranges.

## Activation & integration

- New module `lua/config/block_guides.lua` exposing `setup(opts)`, wired from
  `init.lua` alongside `lsp_refs.setup()` / `statusline.setup()`.
- Active only in buffers where `vim.treesitter` is started and the filetype is a
  code filetype (reuse the treesitter `ft_pattern` set from
  `lua/plugins/treesitter.lua` as the gate; exclude `markdown`/`mdx`/`help`).
- **Toggle keymap** under the existing `<leader>u…` UI-toggle group:
  `<leader>ub` → "Toggle block guides" (mnemonic: **b**lock). Default on.
- Highlight groups defined with `default = true` links so a colorscheme can
  override them; re-applied on `ColorScheme`.

## Edge cases

- **Blank lines inside a block** — the guide still draws because
  `virt_text_win_col` places the bar at an absolute window column independent of
  the line's actual text length.
- **Tabs for indentation** — compute the guide column from the rendered
  (display) column, honoring `tabstop`, so bars land on the visual indent.
- **No enclosing block** (cursor at top level) — no active chain; only dim
  baseline guides show.
- **Very deep nesting** — no cap needed (lines sit at real indent columns; if
  they run past the window edge they're simply clipped like the code is).
- **Insert mode** — chain updates on `CursorMovedI` too, debounced.
- **Disabled / non-eligible buffer** — `on_win` returns `false` to skip
  `on_line` entirely; zero per-line cost.

## Known limitations (accepted)

- **Dedented structural lines** — a block whose guide sits at the header indent
  (`else` / `elseif` / `case` / `except:` at the same column as the keyword)
  shows a one-line gap in that block's *own* bar there. Drawing the bar on those
  lines would overlay (and visually corrupt) the keyword glyph, since the guide
  column is occupied by code rather than whitespace, so the gap is the safe
  behavior. Parent bars (at shallower columns) still run continuously through
  such lines.
- **Horizontal scroll** — `virt_text_win_col` pins bars to absolute window
  columns and does not track `leftcol`. This is moot here: code buffers use
  `wrap = true` (the only `nowrap` filetype is markdown, which is excluded), so
  there is no horizontal scrolling to desync against.

## Testing

Following the repo's existing harness (`plenary` busted, unit tier sandbox-safe
via scratch buffers — see `tests/`):

- **Unit (chain computation):** given a buffer of known source, assert the
  ancestor chain for a cursor position returns the expected `{rows, cols}` per
  tier, and that a sibling block is excluded. Pure-ish: drive
  `vim.treesitter` on a scratch buffer, no UI.
- **Unit (foldable cache):** assert the foldable-range set matches the fold
  query for a small sample (e.g. lua function + nested if).
- **Smoke:** open a real file, place the cursor, assert the decoration provider
  produces ephemeral marks at expected columns (where feasible) and that toggle
  off removes them.

Rendering pixels aren't asserted; the chain/column computation (the logic worth
breaking) is.

## Open tuning knobs (decided during implementation, not blocking)

- Exact default highlight links/colors per tier.
- Guide character (`│` vs `▏` vs `┃`).
- Debounce interval for the cursor-chain recompute.
