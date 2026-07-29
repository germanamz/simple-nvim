# Sticky ancestor folders in nvim-tree

Pin the cursor's ancestor folders to the top of the nvim-tree window once they
scroll out of view, the way `nvim-treesitter-context` pins enclosing functions
in a code buffer.

## Problem

In a large tree the sidebar shows ~40 rows out of hundreds. Scrolling through a
deep directory loses the answer to "which folder am I actually in" — the folder
rows that name the current location have scrolled off the top, and the
`renderer.full_name` float only helps with truncated names, not with location.

nvim-tree has no built-in for this. It does expose the pieces:
`Explorer:get_nodes_by_line()` returns an exact buffer-line → node map, and
every node carries a `.parent` chain.

## Behavior

Anchored on the **cursor** row, not the topline. An ancestor folder is pinned
only once it is no longer visible; ancestors still on screen stay unpinned. The
whole remaining chain is pinned — no depth cap.

The **root repo row** (`▾ my-app  main ✓`, from `renderer.root_folder_label`) is
never pinned. It falls out for free: `core.get_nodes_starting_line()` already
excludes the root header line from the node map, so the root node has no entry
in the inverted map and the ancestor walk terminates there without a special
case.

### Worked example

Tree width 35, root repo row at line 1.

At the top of the tree, nothing is pinned — the chain is already visible:

```
┌───────────────────────────────┐
│ ▾ my-app   main ✓             │
│ ▾ apps                        │
│   ▾ web/src                   │
│     ▾ components              │
│         Button.tsx            │
│         Input.tsx    ← cursor │
└───────────────────────────────┘
```

Scrolled down, with `apps` and `web/src` above the viewport:

```
┌───────────────────────────────┐
│ ▾ apps                        │ pinned
│   ▾ web/src                   │ pinned
│     ▾ components              │ pinned
├───────────────────────────────┤
│         Toolbar.tsx           │
│         Tooltip.tsx  ← cursor │
└───────────────────────────────┘
```

Note the cascade in the second case: `components` is pinned even though its real
row sits at the topline, because the two-row header covers that row. This is
the same trade `nvim-treesitter-context` makes — the float overlays the window,
so pinning row `n` hides whatever was at screen row `n`. It self-corrects in the
other direction: when the full chain is genuinely visible, the header height
settles at 0 and the float closes.

## Architecture

One new module, `lua/config/nvim_tree_context.lua`, wired from the existing
`config()` in `lua/plugins/nvim-tree.lua` alongside `lsp_fs_sync.register` and
the `TreeOpen` winbar hook. It owns four concerns, each independently testable:

| Concern | Entry point | Depends on |
| --- | --- | --- |
| Node/line lookup | `M._maps()` | nvim-tree explorer, changedtick cache |
| Ancestor walk | `M._ancestors(node, line_of)` | pure |
| Visibility filter | `M._pinned(lines, topline, cursor_line)` | pure (numbers only) |
| Render + mount | `M.update()` | `util.overlay`, nvim-tree namespaces |

The two pure functions carry the logic; they take plain values and return plain
values, so the unit tests need no running tree.

### Node and line lookup

```
by_line = explorer:get_nodes_by_line(core.get_nodes_starting_line())
line_of = invert(by_line)
```

Both built in one pass and cached against
`nvim_buf_get_changedtick(tree_buf)`. nvim-tree rewrites the whole buffer on
every draw, so the tick invalidates the cache exactly when the tree changes and
never in between — cursor movement across a warm tree costs a table lookup.

The map excludes grouped nodes (`get_nodes_by_line` skips `group_next` chains
itself), and `get_nodes_starting_line()` already accounts for both the root
header row and an active live filter.

### Ancestor walk

From `by_line[cursor_line]`, follow `.parent` while the parent has an entry in
`line_of`, collecting as we go, then reverse to root-most-first. A nil cursor
node (cursor parked on the root header row, or an empty tree) yields an empty
chain and closes the overlay.

### Visibility filter

Port of `nvim-treesitter-context`'s `mode = "cursor"` rule
(`context.lua:376` — "only process the parent if it is not in view", where "in
view" accounts for the rows the header will itself cover):

```
h   = 0
cap = cursor_line - topline
for each ancestor line L, root-most first:
    if h >= cap then break end          -- never cover the cursor row
    if L < topline + h then h = h + 1   -- hidden (or about to be) → pin
    else break end                      -- visible → stop; lines increase
```

Ancestor lines are strictly increasing, so the pinned set is always a prefix and
a single pass suffices. No `max_lines` cap: depth is self-limiting, and the
`cap` term already bounds the header below the cursor.

### Rendering

The pinned rows already exist in the tree buffer, so they are copied verbatim
rather than re-rendered. For each pinned buffer line `L`, in order:

- text — `nvim_buf_get_lines(tree_buf, L-1, L, false)`
- highlights — extmarks from `NvimTreeHighlights`, re-anchored to the header row
- virt_text — extmarks from `NvimTreeExtmarks`, re-anchored likewise

Both namespaces are needed. `NvimTreeHighlights` carries the inline colors:
devicons, the git decorator's `icon_placement = "before"` labels, and the
grey/blue/teal ignored/dot-folder/symlink trio. `NvimTreeExtmarks` carries the
`icon_placement = "after"` virt_text — which is where `config.nvim_tree_submodule`
puts each submodule's branch and status. `NvimTreeVirtualLines` is not copied.

Because the source rows are copied whole, every decorator works in the header
with no per-decorator support code, now or later.

The scratch buffer is mounted through the existing `util.overlay` handle, which
already owns the valid-guarded close/teardown. While the header is already up,
updates rewrite that buffer and window in place rather than remounting — a
cursor move must not destroy and recreate a float on every keystroke. The buffer
carries `filetype = "NvimTreeContext"`, which gives the header a styling hook and
lets the e2e spec tell it apart from nvim-tree's own `full_name` float.

```lua
{
  relative = "win", win = tree_win, row = 0, col = 0,
  width = vim.api.nvim_win_get_width(tree_win), height = h,
  style = "minimal", focusable = false, noautocmd = true,
  zindex = 20,
}
```

`row` is 0, with no winbar compensation. A `relative = "win"` float is composited
below the window's winbar, so `row = 0` is the first **text** row: the tree's
`g? — all mappings` hint survives untouched, and the filter's assumption that an
`h`-row header covers buffer lines `topline .. topline + h - 1` holds.

Do not add an offset for the winbar. Headless probing argues for one — both
`nvim_win_get_position` and `screenpos` report a float's position relative to the
window **frame**, so a headless comparison "proves" that `row = 0` lands on the
winbar. It does not. The renderer is the authority here: with `row = 1` the
header sits a row too low and one real tree row stays visible above the pinned
folders.

A `NvimTreeContextBottom` highlight group linked to `TreesitterContextBottom`
draws the same underline separator already seen in code buffers, so the two
features read as one idea. Defined once and re-applied on `ColorScheme`, via a
named augroup with `clear = true` — matching the pattern in
`config.nvim_tree_submodule` and `config.nvim_tree_git`.

### Triggers and teardown

`CursorMoved`, `WinScrolled`, `WinResized` and `WinEnter`, plus nvim-tree's
`Event.TreeOpen`. The overlay closes when the computed height is 0, on
`Event.TreeClose`, and when the tree window stops being valid.

These are filtered on `filetype == "NvimTree"` inside the callback rather than by
autocmd pattern. nvim-tree's own float autocmds can use the buffer-name pattern
`NvimTree_*`, but `WinScrolled` and `WinResized` match their pattern against the
window ID, so a buffer-name pattern would silently never fire for them.

Two loop guards: `noautocmd = true` on open keeps the float from firing the
events that created it, and `M.update()` returns early when the current window
is the header float.

### Toggle

`<Space>uT` toggles the header, mirroring `<Space>ut` for treesitter-context and
landing in the existing `<leader>u` = "toggle" which-key group
(`lua/plugins/which-key.lua:19`). No collision — current `<leader>u` bindings are
`ua`, `ub`, `uf`, `uh`, `ut`. State is a module-level boolean defaulting to on;
toggling off closes the overlay and short-circuits `M.update()`.

Documented by adding a row to section 20 of `docs/keybindings.md` and widening
that section's heading and intro to cover sticky context in both code buffers
and the tree.

## Error handling

| Case | Behavior |
| --- | --- |
| `core.get_explorer()` returns nil (tree closed, mid-teardown) | close overlay, return |
| Cursor on the root header row / empty tree | empty chain → close overlay |
| Tree window invalid | close overlay, return |
| Live filter active | handled — `get_nodes_starting_line()` adds its offset |
| Header float is the current window | return early (loop guard) |

## Testing

**Unit** — `tests/spec/unit/nvim_tree_context_spec.lua`, plenary-only, no
running tree. Covers the two pure functions:

- `_pinned`, table-driven: nothing scrolled off → 0; one ancestor above the
  topline → 1; the cascade where a pinned row covers the next ancestor and pulls
  it in; the `cursor_line - topline` cap; empty ancestor list.
- `_ancestors`: chain order is root-most-first; the walk stops at a parent
  missing from `line_of` (the root-exclusion case); a nil cursor node yields
  an empty chain.

The e2e suite additionally pins the winbar offset — that the header is placed
below the tree's `g?` hint rather than on top of it.

**E2E** — `tests/spec/e2e/nvim_tree_context_spec.lua`, modeled on the existing
`nvim_tree_full_name_spec.lua`. Opens the tree on a fixture with a deep
directory, positions the cursor and scrolls, then asserts the float's lines and
extmarks. Two harness constraints from prior work in this repo apply:
`CursorMoved` does not fire in a headless script context, so the spec sets the
cursor and calls `M.update()` directly instead of using `feedkeys`; and running
the spec alone needs `{ minimal_init = "tests/full_init.lua" }`.

Both suites run under `make test-unit` / `make test-e2e`, which need the Claude
sandbox disabled (swap, parser, and git writes).

## Out of scope

- A winbar breadcrumb of the cursor path — the sticky header answers the same
  question, and the tree's winbar is already spent on the `g?` hint.
- A `max_lines` / depth cap, or any user-facing config table.
- Reserving space instead of overlaying, so pinned rows never hide real rows.
  No mechanism short of scroll compensation does this, and treesitter-context's
  overlay behavior is the familiar baseline.
