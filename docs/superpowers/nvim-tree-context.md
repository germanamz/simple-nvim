# Sticky ancestor folders in nvim-tree

`lua/config/nvim_tree_context.lua` — pins the cursor's ancestor folders to the
top of the tree window once they scroll out of view, the way
`nvim-treesitter-context` pins enclosing functions in a code buffer. Toggle with
`<leader>uT` (default on).

In a large tree the sidebar shows around 40 rows out of hundreds, and scrolling
through a deep directory loses the answer to "which folder am I in". nvim-tree's
`renderer.full_name` float only helps with truncated names, not with location.

## Behavior

Anchored on the **cursor** row, not the topline. An ancestor is pinned only once
it is no longer visible; ancestors still on screen stay unpinned. The whole
remaining chain is pinned — no depth cap.

At the top of the tree nothing is pinned, because the chain is already visible:

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

Note the cascade: `components` is pinned even though its real row sits at the
topline, because the two-row header covers that row. Same trade
`nvim-treesitter-context` makes — the float overlays the window, so pinning row
*n* hides whatever was at screen row *n*. It self-corrects in the other
direction: when the full chain is genuinely visible the height settles at 0 and
the float closes.

The **root repo row** (`▾ my-app  main ✓`) is never pinned. That falls out for
free rather than being special-cased: `core.get_nodes_starting_line()` already
excludes the root header from the node map, so the root node has no entry and the
ancestor walk terminates there.

## Architecture

Four concerns, each independently testable.

| Concern | Entry point | Depends on |
| --- | --- | --- |
| Node/line lookup | `M._maps(tree_buf)` | nvim-tree explorer, changedtick cache |
| Ancestor walk | `M._ancestors(node, line_of)` | pure |
| Visibility filter | `M._pinned(lines, topline, cursor_line)` | pure — numbers only |
| Render and mount | `M.update()` | `util.overlay`, nvim-tree namespaces |

The two pure functions carry the logic and take plain values, so the unit tests
need no running tree. `M.register(api.events)` wires the feature from
`lua/plugins/nvim-tree.lua`'s `config()`; `M.close()`, `M.toggle()` and
`M._reset()` complete the surface.

### Lookup

```
by_line = explorer:get_nodes_by_line(core.get_nodes_starting_line())
line_of = invert(by_line)
```

Both are built in one pass and cached against
`nvim_buf_get_changedtick(tree_buf)`. nvim-tree rewrites the whole buffer on
every draw, so the tick invalidates the cache exactly when the tree changes and
never in between — cursor movement across a warm tree costs a table lookup.
`get_nodes_by_line` skips `group_next` chains itself, and
`get_nodes_starting_line()` already accounts for both the root header row and an
active live filter.

### The visibility filter

A port of `nvim-treesitter-context`'s `mode = "cursor"` rule — "only process the
parent if it is not in view", where "in view" accounts for the rows the header
will itself cover:

```
h   = 0
cap = cursor_line - topline
for each ancestor line L, root-most first:
    if h >= cap then break end          -- never cover the cursor row
    if L < topline + h then h = h + 1   -- hidden, or about to be → pin
    else break end                      -- visible → stop; lines increase
```

Ancestor lines are strictly increasing, so the pinned set is always a prefix and
one pass suffices. No `max_lines` cap: depth is self-limiting and `cap` already
bounds the header below the cursor.

### Rendering

The pinned rows already exist in the tree buffer, so they are copied verbatim
rather than re-rendered. For each pinned line, in order: the text from
`nvim_buf_get_lines`, the inline highlights from the `NvimTreeHighlights`
namespace, and the virtual text from `NvimTreeExtmarks` — both re-anchored to the
header row. `NvimTreeVirtualLines` is not copied.

Both namespaces are needed. `NvimTreeHighlights` carries devicons, the git
decorator's `icon_placement = "before"` labels and the grey/blue/teal
ignored/dot-folder/symlink trio; `NvimTreeExtmarks` carries the
`icon_placement = "after"` virtual text, which is where `config.nvim_tree_submodule`
puts each submodule's branch and status. Because rows are copied whole, every
decorator works in the header with no per-decorator support code, now or later.

The scratch buffer is mounted through `util.overlay`, which owns the
valid-guarded teardown. While the header is already up, updates rewrite that
buffer and window in place instead of remounting — a cursor move must not destroy
and recreate a float on every keystroke. The buffer carries
`filetype = "NvimTreeContext"`, which gives it a styling hook and lets the e2e
spec tell it apart from nvim-tree's own `full_name` float.

```lua
{
  relative = "win", win = tree_win, row = 0, col = 0,
  width = vim.api.nvim_win_get_width(tree_win), height = h,
  style = "minimal", focusable = false, noautocmd = true,
  zindex = 20,
}
```

> **`row` is 0, with no winbar compensation. Do not add an offset.** Headless
> probing argues for one — both `nvim_win_get_position` and `screenpos` report a
> float's position relative to the window *frame*, so a headless comparison
> "proves" that `row = 0` lands on the winbar. It does not. A `relative = "win"`
> float is composited *below* the window's winbar, so `row = 0` is the first
> **text** row. The renderer is the authority: with `row = 1` the header sits a
> row too low and one real tree row stays visible above the pinned folders. The
> e2e spec pins this.

Two highlight groups, both `default = true` and re-applied on `ColorScheme` via a
named augroup with `clear = true`: `NvimTreeContext` (linked to
`NvimTreeNormal`, applied through the float's `winhighlight`) and
`NvimTreeContextBottom` (linked to `TreesitterContextBottom`), which draws the
same underline separator seen in code buffers so the two features read as one
idea.

### Triggers and teardown

`CursorMoved`, `WinScrolled`, `WinResized`, `WinEnter`, plus nvim-tree's
`Event.TreeOpen`. The overlay closes when the computed height is 0, on
`Event.TreeClose`, and when the tree window stops being valid.

These are filtered on `filetype == "NvimTree"` **inside the callback**, not by
autocmd pattern. nvim-tree's own float autocmds can use the buffer-name pattern
`NvimTree_*`, but `WinScrolled` and `WinResized` match their pattern against the
*window ID*, so a buffer-name pattern would silently never fire for them.

Two loop guards: `noautocmd = true` on open keeps the float from firing the events
that created it, and `M.update()` returns early when the current window is the
header float.

| Case | Behavior |
| --- | --- |
| `core.get_explorer()` returns nil (tree closed, mid-teardown) | close overlay, return |
| Cursor on the root header row, or an empty tree | empty chain → close overlay |
| Tree window invalid | close overlay, return |
| Live filter active | handled — `get_nodes_starting_line()` adds its offset |
| Header float is the current window | return early |

## Out of scope

- A winbar breadcrumb of the cursor path. The sticky header answers the same
  question, and the tree's winbar is already spent on the `g?` hint.
- A depth cap or any user-facing config table.
- Reserving space instead of overlaying, so pinned rows never hide real rows.
  Nothing short of scroll compensation does this, and treesitter-context's
  overlay behavior is the familiar baseline.
