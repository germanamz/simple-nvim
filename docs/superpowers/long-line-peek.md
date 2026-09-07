# Long-line peek

`lua/config/long_line_peek.lua` — after the cursor has rested ~2.5s on a line too
wide for the window, the line unfolds in place: soft-wrapped across the rows
below it, folding back on the next cursor move, scroll, edit or mode change. No
keymap, no command; the whole point is that the text you are already staring at
eventually shows itself.

`'wrap'` stays off globally (`lua/config/options.lua`). This unwraps the one line
you are reading, not the viewport.

## The visual model

```
    9   const config = {                     9   const config = {
   10     retries: 3,         dwell 2.5s    10     retries: 3,
   11     endpoint: "https:/›  ─────────►   11     endpoint: "https://api.example.com/v2
   12   }                                          /resource?verbose=true&trace=on",
   13   run(config)                         12   }
                                            13   run(config)
```

The `›` truncation marker is replaced by the rest of the line. Line 11 keeps its
number; the continuation rows have a blank gutter, like any wrapped row. Nothing
below is covered — lines 12 and 13 are pushed down by exactly the number of rows
the peek added, and spring back when it closes.

Four rules carry the design:

1. **Reveal, never relocate.** The parent window's `winsaveview()` is byte-for-byte
   identical before, during and after. No horizontal scroll, no cursor move, no
   `topline` change.
2. **Nothing is hidden to show something.** The rows the peek occupies are rows it
   created. If it cannot create them, it does not take them.
3. **The peek is not a mode.** Any cursor move, scroll, edit or mode change folds
   it and restarts the clock. There is nothing to dismiss and nothing to get
   stuck in.
4. **Silence over noise.** It fires only when it has something to add — a line
   that fits, or a peek squeezed to a single row, produces nothing at all.

## How it renders

A borderless, non-focusable float over the cursor line showing **the same
buffer** with `'wrap'` on, plus a `virt_lines` extmark of `height - 1` blank rows
on that line so the real code below is pushed down by exactly what the float
covers.

Sharing the buffer is the load-bearing choice: treesitter, LSP semantic tokens,
inlay hints and diagnostic underlines all render in the float for free, because
they are extmarks on a buffer the float happens to be displaying. Nothing is
copied and nothing is re-parsed.

| Piece | Value | Why |
| --- | --- | --- |
| `relative` / `row` | `"win"` / `winline() - 1` | row 0 is the first *text* row, below any winbar |
| `col` | `getwininfo().textoff` | puts the float's text in the parent's exact text column |
| `width` | `width - textoff` | the parent's text area, so wrap points match |
| `height` | `nvim_win_text_height` | measured, never computed — see below |
| `zindex` | 45 | above ordinary windows, below the docs viewer (250) |
| `focusable` | `false` | the cursor must never land in it |

Highlight: one group, `LongLinePeek`, mapped onto the float's `Normal` via
`winhighlight`. It is **derived, not linked** — `CursorLine`'s background over
`Normal`'s foreground, recomputed on `ColorScheme`. A plain link would leave the
float's text with no foreground of its own, since most themes give `CursorLine`
only a `bg`. Taking the cursor-line background across every row makes the block
read as one line.

## The dwell trigger

A `vim.uv` timer, **not** `CursorHold`: `'updatetime'` is 250 here and load-bearing
for gitsigns blame and LSP document highlight, so it cannot be stretched to 2.5s.

`CursorMoved`, `CursorMovedI`, `WinScrolled`, `WinResized`, `ModeChanged`,
`TextChanged`, `TextChangedI`, `InsertEnter`, `BufEnter`, `WinEnter`, `BufLeave`
and `WinLeave` all route to one `rearm()`: fold whatever is open, restart the
clock. The peek therefore never outlives the state it described.

When the timer fires, `eligible()` decides. It is pure over a context table so
the whole matrix is unit-testable without driving a real session into each mode:

| Guard | Rejects |
| --- | --- |
| `mode == "n"` | insert, visual, and operator-pending (`mode(1)` returns `"no"`, so a prefix test would leak) |
| `state("mo") == ""` | a half-typed mapping, a pending operator — "no keybinding started" |
| `not pumvisible` | the completion menu is up |
| `buftype == ""` | the tree (`nofile`), telescope (`prompt`), help, quickfix, terminals |
| `relative == ""` | the cursor is already inside a float |
| `not large` | over the shared `util.largefile` bound |

Then `is_clipped(line_width, text_width)` — deliberately independent of
`leftcol`. The question is "can this line ever be fully visible", not "is some of
it off-screen right now": a line wider than the text area is clipped at every
horizontal scroll position, and one that fits is always reachable by scrolling
back.

`open()` then applies three guards that are about the *screen*, not the editor's
mode, and each of which would otherwise produce a visibly wrong render:

| Guard | Why the peek would be wrong without it |
| --- | --- |
| `not vim.wo[win].wrap` | A wrapped window clips nothing, so there is nothing to reveal — and `winline()` there is the cursor's *continuation* row, so the float would anchor mid-line and repaint the line a second time, with the spacer's blank rows left over below. |
| `foldclosed(lnum) == -1` | A closed fold renders as one foldtext row that is not this line, and `virt_lines` on a folded line are **silently not drawn** — so the spacer never materialises and the float paints straight over the real code below it. |
| `winsaveview().leftcol == 0` | A scrolled window draws the cursor at `virtcol - leftcol` while the float renders from column 0, so the cursor block would sit on an unrelated character; a truncated peek could also hide the very segment being read. |

All three were found by review after the feature already worked, and all three
are cheap. The fold one is the nastiest: nothing errors, the extmark is accepted,
and the only symptom is code disappearing under the float.

## Staying folded when the screen moves

`rearm()`'s twelve events all describe *cursor, buffer or mode* changes. Several
ordinary commands change what an open peek was drawn against while firing none of
them: `zc`/`zM` collapsing a fold **above** the line shifts its screen row;
`<C-w>o` or `:fclose!` takes the float itself, leaving the spacer's blank rows
behind and `active` naming a dead window so no future peek can open; `:set wrap`
invalidates the whole geometry.

A `SafeState` autocmd closes the peek whenever the screen no longer matches what
`active` recorded (`win`, `lnum`, `winline`, plus a re-check of the fold, wrap and
`leftcol` guards). `SafeState` fires when Neovim is about to wait for input —
after every completed command — and this handler only ever **validates**, never
rearms, so the dwell is untouched. With no peek on screen it costs one nil check.

Two smaller lifecycle traps, both real:

- **`timer:stop()` cannot recall a queued callback.** If the dwell expires in the
  same loop iteration as the keypress that ends it, `vim.schedule_wrap`'s body has
  already been queued and still runs — popping a peek the instant you press a key,
  the exact malfunction the dwell exists to avoid. A `generation` token, bumped in
  `rearm()` and again on `VimLeavePre`, makes the stale body retire itself.
- **`M._did_setup` cannot survive a module reload.** `package.loaded[...] = nil;
  require(...)` — what `:Lazy reload` and a re-requiring spec do — hands out a
  fresh table whose flag is `nil` while the *previous* instance's timer is still
  armed. That timer would later open a peek onto the old instance's `active`,
  which no live handler can reach: an uncloseable float for the rest of the
  session. The guard is therefore the **augroup**, which is global state that a
  reload does not duplicate.

## Three things that are not obvious

**Height is measured, not computed.** `ceil(strdisplaywidth / textw)` is wrong
whenever `'breakindent'` is on, because continuation rows carry an indent the
arithmetic knows nothing about. `nvim_win_text_height` on the float — after
`'wrap'` is set and its view parked on the line — is the only correct source.
`start_vcol = 0` excludes any `virt_lines` sitting above the row (diagnostics,
codelens) from the measurement.

**The peek is bounded by its own window, not the screen.** A float may legally
overflow its parent, and an earlier version let it, measuring against
`lines - cmdheight`. That is wrong: the spacer can only push rows *inside* this
window, so any row the float covered past the bottom edge would belong to a
neighbouring split and would be genuinely hidden — the one thing rule 2 forbids.
`rows_available = height - winline() + 1`.

**The spacer must be scoped to one window.** It is a *buffer* extmark, so
unscoped it renders in every window showing that buffer: open a split on the same
file and the other window gets the blank rows with no float over them — a hole
punched in someone else's view. `nvim__ns_set(ns, { wins = { win } })` scopes the
namespace. That is an experimental double-underscore API, so its absence is
treated as normal: with the buffer on screen once the spacer is safe unscoped,
and with it on screen twice the spacer is dropped and the float covers the lines
below instead. Worse than unfolding, strictly better than corrupting the other
window.

The sharing count has to be taken **before the float is opened**. `win_findbuf`
includes floating windows, so asking after the float has mounted the buffer always
answers "at least two" — which made the whole fallback dead code, silently, in the
one configuration it existed to serve.

## Rejected alternatives

- **`virt_lines` text instead of a float.** Rendering the tail as virtual lines
  needs no window and covers nothing — but virtual lines carry no highlighting of
  their own, so every decoration has to be re-derived by hand. Slicing treesitter
  captures per row costs 0.29–1.4 ms/row on injection-heavy buffers, silently
  misses injected languages, and cannot see treesitter highlights or gitsigns
  word-diff **at all** (both are ephemeral extmarks, invisible to
  `nvim_buf_get_extmarks`). It also renders nothing near the window bottom:
  Neovim clips virtual lines at the edge and will not scroll to reveal them.
- **Toggling window-local `'wrap'`.** Reflows the entire viewport rather than one
  line, and breaks `block_guides` — its `virt_text_win_col` bars paint only on
  each buffer line's first screen row, so they vanish from continuation rows.
- **Ephemeral extmarks from a decoration provider.** `virt_lines` set with
  `ephemeral = true` render nothing and raise no error. The `kDecorKindVirtLines`
  branch is write-only dead state: all virtual-line work goes through
  `decor_virt_lines()`, which scans the marktree and short-circuits on a counter
  ephemeral marks never increment.
- **`benlubas/wrapping-paper.nvim`**, the only published plugin with this
  architecture. Manual-trigger, *enters* the float, and drops your column
  permanently on close — its teardown restores nothing. Also pulls in `nui.nvim`.
- **`util.overlay`**, which every other float in this config goes through. Its
  `:close()` deletes the buffer it mounted, and this float mounts the user's real
  buffer. Reusing it would wipe the file you are editing.

## Interactions

- **`markdown_paragraphs`.** `'statuscolumn'` is evaluated once per *screen* row
  while `v:lnum` stays on the buffer line, so the paragraph marker re-rendered
  itself on every spacer row. Fixed at the source: `M.marker()` now returns the
  blank pad when `v:virtnum ~= 0`, matching what core already does for its own
  `%l`. This was latent — nothing in the config produced virtual lines until now.
- **`block_guides`.** Its bars do not paint on the spacer's virtual rows. The rows
  are blank and fully covered by the float, so this is invisible.
- **gitsigns blame.** `current_line_blame` draws at end-of-line on the cursor
  line, which is off-screen on a clipped line anyway; the float covers that row
  while open.

## Accepted limits

- **Truncation is silent.** If the line needs more rows than remain below the
  cursor, the peek shows what fits with no marker. `'scrolloff'` is 8, so the
  cursor is only ever that close to the bottom at end-of-file, and the peek still
  shows strictly more than the unpeeked line did — it always starts at column 0,
  which the `leftcol` guard guarantees is where the visible segment starts too. A
  one-row result — which would show exactly the screenful already on screen — is
  refused outright.
- **It never fires in a horizontally scrolled window.** Once you have scrolled
  right, reading the tail by hand is already underway and re-anchoring the float
  to the cursor's wrapped row would mean covering rows *above* the line as well.
  Landing on a long line from above keeps `leftcol` at 0, which is the case this
  feature is for.
- **Signs and number-column highlights do not reach the float.** Extmark
  decoration *in the text* renders for free; anything living in the gutter does
  not, since the float has `signcolumn = "no"` and `number = false`.
- **The rendered result cannot be asserted headlessly.** Neovim composites a
  `relative = "win"` float at the screen origin in `--headless`, so
  `screenstring()` "shows" the peek covering the top of the window while
  `nvim_win_get_config` reports the correct position. The e2e spec pins geometry,
  the spacer and the untouched view through the APIs; the visual result was
  verified in a real PTY. Do not add `screenstring` assertions to that spec —
  they would pin the artifact, not the feature.
- **`state()` lies without a UI.** With no UI attached, `state()` reports `"oS"`
  even at idle, so `eligible()` refuses in the headless test lanes; a real session
  reports `""` (measured in a PTY, where the peek does open unprompted). The dwell
  specs therefore stub `eligible()` to isolate the timer wiring, and pin the field
  *spellings* separately — `ctx.state` must contain no letter outside `"mo"`,
  which is what catches a `state("mo")` → `state()` regression.

## API

| Function | Kind | Contract |
| --- | --- | --- |
| `text_width(wininfo)` | pure | `width - textoff`, floored at 0 |
| `is_clipped(line_width, text_width)` | pure | can this line ever be fully visible |
| `geometry({wrapped_height, rows_available})` | pure | `{ height, spacer, truncated }`; height floored at 1 |
| `reveals_more(geo)` | pure | false for a one-row peek, which would show nothing new |
| `spacer_lines(n)` | pure | the `virt_lines` payload: n blank rows |
| `eligible(ctx)` | pure | is an unprompted float welcome right now |
| `_ctx()` | reads state | the live editor state `eligible` judges; exported because an exhaustively tested pure predicate proves nothing about whether the fields feeding it are spelled right |
| `setup()` | effect | idempotent (guarded on the augroup); wired from `init.lua` |

`DELAY_MS` (2500) is the dwell. The specs shorten it to 20ms rather than waiting.
