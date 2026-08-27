# Going back after `gd`: the definition stack

`gd` into a definition, read around inside it, then `<C-o>` to get back — and
you walk out through every search, every `}`, every `G` you made while reading.
This document explains why, why the fix is a *second* key rather than a smarter
`<C-o>`, and what this config does to make that second key trustworthy.

**The punchline, if you read nothing else:** `<C-t>` pops straight back to the
call site in one press, skipping everything you did while reading. `3<C-t>`
unwinds three levels of `gd` at once, and `<leader>j` opens a picker over the
whole chain. `lua/config/tagstack.lua` exists to make that key trustworthy on
every path that navigates; this document explains what it does and why.

## Root cause: two back-histories, and `<C-o>` is the wrong one

Neovim keeps two independent per-window histories. They are not variations on a
theme — they answer different questions.

|                | jumplist (`<C-o>` / `<C-i>`)                                    | tagstack (`<C-t>`)                          |
| -------------- | --------------------------------------------------------------- | ------------------------------------------- |
| Records        | every far motion: `G`, `gg`, `/`, `n`, `{`, `}`, `%`, `H/M/L`, `:N`, `` ` ``, buffer switches | only tag / LSP definition jumps             |
| Shape          | linear list with a cursor, 100 entries                            | **true LIFO stack**, 20 entries             |
| Back           | steps one entry                                                   | **pops one whole hop**                      |
| Count          | `3<C-o>` = three entries back                                     | `3<C-t>` = three hops back                  |
| Survives `:bd` | entries pruned by `jumpoptions=clean`                             | entry survives; `<C-t>` reopens the file    |
| Survives `:bw` | dead entries skipped                                              | **whole stack emptied** → `E73`             |
| Persistence    | shada (`'` flag)                                                  | neither shada nor session — always empty on start |

So the reported symptom is not a defect. It is the jumplist doing exactly its
job. Reading inside a definition file deposits an entry per search and per
paragraph motion, and `<C-o>` faithfully replays them. The tagstack ignores all
of it, because none of it was a tag jump.

### Source-verified behaviour

Against the installed runtime, `/opt/homebrew/Cellar/neovim/0.12.5/share/nvim/runtime`:

- **`vim.lsp.buf.definition` already pushes a tagstack frame** —
  `lua/vim/lsp/buf.lua:267-271` does `normal! m'` then
  `settagstack(win_getid(win), { items = … }, 't')`.
- **…but only for a single result.** The push sits inside `if #all_items == 1`
  (`buf.lua:263`). Multiple results route to the quickfix list and push nothing.
- **…and only when `on_list` is absent.** `buf.lua:253-260` calls `on_list` and
  returns before reaching the push.
- **`vim.lsp.util.show_document` pushes too** when `focus = true` —
  `lua/vim/lsp/util.lua:1033-1041`.
- **`jumpoptions` defaults to `clean`** — `doc/options.txt`, verified at runtime.
  `stack` and `view` are the other two values; there is no fourth.
- **There is no `setjumplist()`.** `exists("*setjumplist")` → `0`,
  `nvim_win_set_jumplist` → `nil`. The jumplist can be read and walked, never
  rewritten. `settagstack()` does exist, which is why the tagstack is the one
  this config can repair.

## What every other editor did about this

The research behind this design covered IntelliJ, VS Code, Visual Studio,
Eclipse, Emacs, Xcode, Sublime, Helix and Zed. The finding was unanimous, and it
is the reason this config does *not* try to make `<C-o>` smarter:

> Nobody made Back smarter. Everybody added a second, coarser history next to it.

- **Visual Studio** shipped *Navigate Backward in Edit Locations* specifically
  because plain Navigate Backward was too noisy.
- **VS Code** added *Go Back in Edit Locations* (`Ctrl+K Ctrl+Q`) beside *Go
  Back*, plus a `workbench.editor.navigationScope` setting.
- **IntelliJ** keeps *Last Edit Location* (`Cmd+Shift+Backspace`) as a separate,
  much smaller history from *Back* (`Cmd+[`), backed by a distinct `changePlaces`
  deque in `IdeDocumentHistoryImpl`.
- **Eclipse** has *Back to Last Edit Location* beside `Alt+Left`.
- **Emacs** keeps the xref stack (`M-,`) rigorously separate from the mark rings.
  xref is a pure LIFO that only records definition and reference jumps. It is the
  tagstack, with different spelling.

Vim shipped that second coarse history in 1991. It is `<C-t>`. This config's job
is to make sure it is always armed.

The granularity tuning those editors do is a sideshow and is deliberately not
copied: IntelliJ merges history entries within **4 lines**
(`TextEditorState.MIN_CHANGE_DISTANCE = 4`), VS Code within roughly 10, and Zed
looked at both and chose **Vim's exact-line dedup instead**
(`MAX_NAVIGATION_HISTORY_LEN = 1024`, commented "Neovim-style deduplication").
There is no consensus to inherit, and it is the jumplist's problem regardless.

The picker has the same pedigree. **Helix ships one in core** — `Space j` is
`jumplist_picker`. Eclipse has a Back dropdown, Xcode press-and-hold, IntelliJ
*Recent Locations* (`Cmd+Shift+E`) with code snippets. It is the browser
long-press-back affordance, and it is the right answer for "go back three
levels" — but not for the 90% case of one level, which stays a keypress.

## Why a module is needed at all

Out of the box, `<C-t>` was dead or lying in four places. Each is the reason a
corresponding piece of `config.tagstack` exists.

1. **Multi-result `gd`.** Core returns before the push (`buf.lua:263`).
   Separately, **`grr` has never pushed a frame at all**: `M.references`
   (`buf.lua:868`) is its own implementation and does not route through
   `get_locations`, so unlike `gd`/`gri`/`grt` it has no single-result push to
   inherit — there is nothing to extend, only something to add.
2. **Wikilink follow.** `lua/config/wikilinks.lua:157` (`open_path`) and `:175`
   (`open_or_create`) navigate with `vim.cmd.edit`, and pushed *neither* stack —
   the only `gd` branch that was invisible to both back-keys. They now take a
   captured origin and push on success.
3. **ts_ls source-definition captured the origin at the wrong time.** It used to
   reach `show_document` from inside an async `client:request` callback, and
   `show_document` evaluates `vim.fn.bufnr('%')`,
   `vim.fn.line('.')` and `vim.fn.win_getid()` **when the response arrives**
   (`util.lua:1035-1041`), where core's own path captures them *before* the
   request (`buf.lua:227-229`). Move the cursor or change windows while tsserver
   is thinking and the recorded return point was wrong — and because
   `win_getid()` is called with no argument, the frame could be written into a
   different window than the one you jumped from. The fallback had the same
   defect for the same reason. `M.ts_source_definition` replaces both halves.
4. **Scroll position was not restored.** `jumpoptions` was unset, so a pop landed
   on the right line at whatever scroll offset happened to result. It is now
   `clean,view`.

Not a gap, but worth recording: **`:bwipeout` empties the entire tagstack** and
`<C-t>` then raises `E73` with no skip-to-next, where the jumplist would skip
dead entries and continue. This config never wipes — `lua/config/buffers.lua:74`,
`:81` and `:103` use `bdelete`, and `:49` uses
`nvim_buf_delete{ force = false }` — so frames survive every buffer-delete key
here. **This is the single fact that keeps the design small:** without it, the
tagstack would have to be shadowed by a path-based structure to be trustworthy,
and that shadow would drift from the real stack the moment any plugin called
`vim.lsp.buf.definition` directly.

## How it works

### The shape, and why it is this shape

- **Two-tier, not one smart key.** `<C-o>` keeps its native fine-grained
  behaviour; `<C-t>` is the coarse "unwind one hop". This is the shape every
  other editor converged on, and it is why nothing here remaps `<C-o>`.
- **Semantic jumps push; file pickers do not.** `gd` (all four branches),
  `grr`, `gri`, `grt`. Telescope file pickers, nvim-tree opens and quickfix
  jumps stay jumplist-only. The stack holds 20 frames; filling it with "I chose
  to open a file" turns `<C-t>` into the noisy thing it exists to avoid. This
  matches Emacs xref, where `xref-find-definitions` and `xref-find-references`
  both push and `M-,` pops both.
- **Telescope for the picker**, matching the `lsp_picker` / `ai_models` /
  `pyright_rules` convention already in the repo.

### One push contract, two rules

**Rule 1 — capture the origin before the request, never inside the callback.**
`M.capture()` runs synchronously at keypress and returns
`{ winid, bufnr, lnum, col, tagname }`. `M.push()` writes into `origin.winid`
explicitly rather than whatever window is focused when a response lands. This is
gap 3.

**Rule 2 — push on success, never on intent.** Helix shipped exactly this bug
and fixed it in [#2663 / #2670](https://github.com/helix-editor/helix/issues/2663):
`push_jump` at the top of `goto_impl` meant cancelling the picker with `Esc` left
a stale entry behind. Two paths here can fail the same way — `open_path`
notifies and returns `false` on an unreadable target, and `open_or_create`
returns `false` when the "Create?" prompt is declined. Both already return a
success boolean, so the push is gated on it.

Because this config supplies its own `on_list`, core skips its push entirely
(`buf.lua:253-260`) and there is no double-push to reconcile. The three outcomes:

```
zero results     → notify, push nothing
single result    → push, then jump
multiple results → push once, then open the quickfix list
```

**Rule 2 does not extend to the multi-result case, and the attempt to make it is
worth recording.** Deferring the push to the quickfix selection is the more
principled reading, and it was implemented first — a buffer-local `<CR>` on the
quickfix buffer that pushed and then fell through to the built-in jump. It fails
in both directions at once:

- **It over-fires.** The quickfix window stays open after a jump, so walking a
  reference list — the normal way to use one — pushed an identical frame per
  entry visited. Measured: browsing 25 references from one `grr` filled all 20
  tagstack slots with the same frame and evicted both genuine `gd` hops, so
  `<C-t>` could no longer reach the original call site at *any* count. That is
  precisely the failure this document's *Rejected* section says the design
  prevents, reintroduced by the mechanism meant to be careful.
- **It under-fires.** `]q` / `[q` are Neovim 0.11+ defaults for `:cnext` /
  `:cprev`, and along with `:cc`, `:cfirst` and `<C-w><CR>` they never touch a
  buffer-local mapping. Every one of them jumped with no frame at all, leaving
  coverage gap #1 open for the most common way to walk a reference list.

There is no single "the user chose an entry" event to hook, so **one frame per
invocation** is the honest unit: you asked a semantic question and a list of
answers opened. The residual cost is that closing the list without picking
anything leaves one frame pointing at where you already are, which `<C-t>`
resolves to a harmless no-op — far cheaper than either failure above.

One consequence: **references always take the list path, even for a single
result.** Core never single-jumps for them (`buf.lua:868-908` always opens the
list), and with `includeDeclaration = true` a symbol used nowhere else returns
exactly one location — the declaration under the cursor. Single-jumping that
would make `grr` open nothing, print nothing and not move.

### `M.push` and `M.jump`: one writer, one convenience

`M.push(origin, kind)` is the **only** function in this config that writes the
tagstack. Nothing else calls `settagstack`. On top of it sits one convenience for
the common case:

```
M.jump(origin, item, kind)
  -- navigate origin.winid to item; on success, M.push(origin, kind).
```

The split is by who owns the navigation:

- **LSP paths use `M.jump`** — `gd` (all four branches), `grr`, `gri`, `grt`.
  This config already supplies `on_list`, so it owns the navigation anyway. For
  ts_ls that means `vim.lsp.util.show_document` is dropped from `lsp.lua:185`
  (its only caller in the whole config), and the result is converted with
  `vim.lsp.util.locations_to_items({ result[1] }, client.offset_encoding)`
  (`util.lua:1884`) — the same conversion core uses, so offset encoding stays
  correct without reimplementing it.
- **wikilinks uses `M.push` directly** — `open_or_create` owns non-trivial
  navigation of its own (the create-on-confirm prompt, parent-directory
  creation), so it keeps it and calls `M.push(origin, "link")` once it has
  returned `true`.

Net effect: one function writes the tagstack, always into the originating
window, always with the pre-request cursor, never for a jump that didn't happen.

### `<C-t>`

Remapped globally in `options.lua` to `M.pop(vim.v.count1)` — a thin wrapper over
native `:{count}pop`. `E73: Tag stack empty` is `pcall`-catchable (verified), so
an empty stack notifies *"definition stack empty"* rather than throwing a raw
error code. Count support and native semantics are otherwise untouched.

### The picker: `<leader>j`

`<leader>j` and `<leader>o` are both free. `j` matches Helix's `Space j`.

```
╭─ Definition stack ─────────┬─ Preview ──────────╮
│   1  handler.go:42  gd     │ 40  func (s *Srv)  │
│ ● 2  router.go:110  grr    │ 41    mux := s.mux │
│   3  main.go:18     gd     │ 42    mux.Handle(p)│
├────────────────────────────┴────────────────────┤
│ <CR> pop here · <C-x> drop frame · <Esc> close   │
╰─────────────────────────────────────────────────╯
```

**Why not `telescope.builtin.tagstack`?** It exists, and it is the wrong shape.
`telescope/builtin/__internal.lua:1476-1512` builds the picker with the default
`<CR>` action, which **edits the file without touching `curidx`**. Pick level 3
and the stack still holds three frames, so the next `<C-t>` pops relative to a
position you are no longer at. It jumps; this needs to pop.

**Curidx handling** is the non-obvious part, and two facts about it were only
established by probing the running editor. Both contradict the obvious design.

**`:tag` cannot be used at all.** It is the natural forward counterpart to
`:pop`, and for an LSP-pushed frame it is always `E433: No tags file`. The reason
is structural: a tagstack entry stores the tagname and where you came *from*,
never where the jump *landed*. Going forward therefore means re-resolving the
tagname through a tags file, and there isn't one. Any design that offers a
forward direction via `:tag` is broken on arrival.

**`settagstack` discards a `curidx` passed alongside `items`.** The docs say
*"The current index is set to one after the length of the tag stack after the
modification"*, and that is exactly what happens — dropping one of three frames
while asking for `curidx = 2` yields `curidx = 3`. A **curidx-only** write does
work, and is the only way to position the stack.

Together those collapse the picker's two directions into one mechanism. Rows
render newest-first, so row `i` is `items[length - i + 1]`; call that `j`. To
reach any frame, in either direction:

```
settagstack(win, { curidx = j + 1 }, 'r')   -- position
:1pop                                        -- and step onto it
```

For `j < curidx` that is equivalent to `{curidx - j}pop`; for `j >= curidx` it
reaches frames `:tag` could not. `●` marks the current position, rendered only
when `curidx <= length` (after a fresh push `curidx == length + 1`, so no row is
current and every row is behind you). The step is still a native `:pop`, so the
stack stays internally consistent and `jop=view` still restores the view —
portal.nvim's trick of replaying real motions rather than teleporting.

`<C-x>` drops a frame with **two** writes for the same reason: `settagstack(win,
{ items = kept }, 'r')` to remove it, then `settagstack(win, { curidx = … },
'r')` to restore the position. Dropping frame `j` where `j < curidx` shifts
everything above it down one, so `curidx` is decremented to keep pointing at the
same logical frame; without the second write it snaps to the top of the stack.

The `gd` / `grr` kind column comes from a small side-table keyed on frame
identity, populated only by this config's own pushes. Frames pushed by core or a
plugin render blank — honest rather than guessed.

### Options

`opt.jumpoptions = "clean,view"` — adds `view` to the inherited default. It
restores the saved view on tagstack pops, jumplist steps, changelist steps,
alternate-file and mark motions, which fixes gap 4. `<C-o>`'s *semantics* are
unchanged; only its scroll restoration improves.

`stack` is deliberately not added: it permanently discards the forward branch
with no undo, and `jumpoptions` is global, so it could not be scoped to code
buffers while leaving markdown and the docs reader alone.

## Where it lives

| File                                | Responsibility                                                       |
| ----------------------------------- | -------------------------------------------------------------------- |
| `lua/config/tagstack.lua`           | The model, and the only code here that calls `settagstack`. `capture` / `push` / `jump` / `frames` / `pop` / `goto_frame` / `drop_frame`, plus the `gd`, `grr`, `gri`, `grt` and ts_ls wrappers |
| `lua/config/tagstack_picker.lua`    | The `<leader>j` Telescope view. `open`, with `rows` / `widths` / `format` as the pure test seam |
| `lua/config/options.lua`            | `jumpoptions`, the global `<C-t>` map, `<leader>j`                    |
| `lua/plugins/lsp.lua`               | `LspAttach` routes all four `gd` branches and buffer-local `grr` / `gri` / `grt` through the wrappers |
| `lua/config/wikilinks.lua`          | Threads one captured origin through both follow paths and the LSP fallback |
| `tests/spec/unit/tagstack_spec.lua` | 25 examples over the model                                            |

Two things deliberately absent. Nothing calls `vim.lsp.util.show_document` any
more — it was the ts_ls path's late-capture bug, and `M.jump` replaces it.
`lua/plugins/which-key.lua` is untouched: it registers prefix *groups*, and
`<leader>j` is a leaf that carries its own `desc`.

## What the specs cover

`tests/spec/unit/tagstack_spec.lua` — 25 examples, following the
`lsp_refs_spec.lua` idiom:

- `M.frames()` normalization and the curidx → pop/tag arithmetic, including the
  fresh-push case where `curidx == length + 1`
- `M.rows()` / `M.format()` rendering, including a frame with no known kind
- empty-stack `pop` notifies instead of raising `E73`
- **capture-before-request ordering**: with a stubbed client that responds late,
  assert the pushed frame's `from` matches the pre-request cursor even though the
  cursor moved before the response landed
- **no push on failure**: `M.jump` with no item and with an item carrying no
  filename both leave the stack unchanged
- **one frame per multi-result invocation**, including when the list is walked
  with `:cnext` rather than `<CR>` — the two halves of the failure described
  under Rule 2
- **references list even for a lone result**
- **the origin window can close between capture and jump**: `M.jump` re-aims the
  frame at the window it actually landed in, rather than silently recording
  nothing into a dead window id
- **an out-of-range destination line is clamped**, so a jump cannot report
  success while leaving the cursor at an arbitrary line of the right file
- **`drop_frame` on the frame you are standing at clears the marker** instead of
  moving `●` onto a frame that slid into the slot

Per the harness constraints in `docs/superpowers/testing.md`, e2e specs create
buffers through the API rather than `:edit`.

## Rejected, and why

- **A parallel history structure owned by this config.** The tagstack already is
  one, it is per-window, it survives `bdelete`, and core writes it on paths this
  config does not control. A shadow copy drifts the moment any plugin calls
  `vim.lsp.buf.definition` directly.
- **Making `<C-o>` smarter** (bufjump-style "skip until the buffer changes").
  It is the wrong filter for the stated problem: `gd` into a large file, read
  around, then want to return to a different function *in the same file* is
  precisely the case it refuses to serve. It also no-ops silently when nothing
  matches, which reads as a broken key.
- **`jumpoptions=stack`.** Discards the forward branch permanently, and cannot be
  scoped per-filetype.
- **Proximity / line-distance coalescing.** No cross-editor consensus (4 vs ~10
  vs exact-line), and it is the jumplist's concern, not the tagstack's.
- **Pushing on Telescope, nvim-tree and quickfix navigation.** Twenty slots fill
  in minutes and `<C-t>` becomes the noisy thing it exists to avoid.
- **An `incoming_calls`-backed "who calls this?" key.** Genuinely a fourth model
  — no history at all, correct after a restart and after `:bd` — but it answers a
  different question than "where was I", and is wrong exactly when the caller
  isn't a caller (a test fixture, a string reference, a config file). Worth
  naming; not worth building here.
