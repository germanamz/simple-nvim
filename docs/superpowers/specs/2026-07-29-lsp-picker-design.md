# LSP client picker — design

**Date:** 2026-07-29
**Status:** approved, implementing

## Problem

Neovim never reaps LSP clients (nvim 0.12.4 has no zero-buffer autostop). A
session that visits several repos in a superproject accumulates one client per
root, each holding its processes — ~0.7 GiB and 3 node processes for a warm
`ts_ls`. `<leader>lk` (`config.lsp_reap`) sweeps every *idle* client at once and
`:lsp stop <name>` kills by server name, but neither lets you see what is running
and stop one specific client. `<leader>lr` restarts only the clients attached to
the **current** buffer, so a client for another root cannot be restarted at all.

## Solution

A telescope picker listing every active client, with per-row stop and restart.

### Module: `lua/config/lsp_picker.lua`

Sibling of `lsp_reap` / `lsp_refs` / `lsp_fs_sync`. Split so the logic is unit
testable over fake client tables, the way `lsp_reap.idle` is:

| Function | Kind | Contract |
| --- | --- | --- |
| `M.rows(clients)` | pure | `{ client, name, nbufs, root }` per client, ordered **idle-first** (0 buffers), then by name, then root |
| `M.format(row)` | pure | `ts_ls          2 bufs   ~/projects/…/lola-web` — aligned columns, root via `fnamemodify(root, ":~")`, `(no root)` when absent |
| `M.kill(client)` | effect | stop unless already stopped; returns whether it acted |
| `M.restart(client)` | effect | stop, wait for exit, re-attach its buffers; returns the count re-attached |
| `M.open()` | effect | build and open the picker |

Idle-first ordering puts the kill candidates at the top. `generic_sorter`
preserves that order while the prompt is empty (the same property `ai_models`
relies on).

### Actions

Mapped `map({ "i", "n" }, …)` — the config's idiom for custom picker actions
(`ai_models.lua` uses `<C-o>` / `<C-d>` / `<C-u>` / `<C-p>` / `<C-f>`).

| Key | Action |
| --- | --- |
| `j` / `k` | move between clients (deliberately untouched) |
| `<C-k>` | stop the client under the cursor, after `vim.fn.confirm` |
| `<CR>` | restart the client under the cursor |
| `<esc>` | close (normal mode); `<C-c>` from insert |

**Why `<C-k>` and not bare `k`:** this config opens pickers with
`initial_mode = "normal"` (`telescope.lua:152`), where `k` is *move selection
up*. Binding bare `k` to a destructive action would remove navigation from the
one picker where you most need to move between rows before acting. `<C-k>` keeps
the "kill" mnemonic, works from both modes, and matches the existing idiom. It
shadows telescope's global insert-mode `<C-k>` (`move_selection_previous`) inside
this picker only.

Destructive action is confirmed with `vim.fn.confirm`, following `ai_models`'
model-delete action.

### Restart semantics

The fiddly part. `<leader>lr` works by stopping the current buffer's clients and
`:edit`-ing, which only reaches the focused buffer. Here the target client's
buffers are not current, so:

1. Record `client.attached_buffers` (valid buffers only).
2. `client:stop()`.
3. Wait, bounded, for `client:is_stopped()` — stop is asynchronous, and starting a
   new client before the old exits risks the reuse path selecting the dying one.
   Bound is 2000 ms, matching `lsp_fs_sync`'s `RENAME_TIMEOUT_MS` precedent.
4. Re-fire `FileType` per recorded buffer so `vim.lsp.enable`'s attach autocmd
   runs again.

A client with **zero** attached buffers has nothing to re-attach, so restart
degrades to a plain stop and reports that.

### Legend

A strip under the results via `util.picker_legend` + `util.overlay`, matching
`telescope_smart` and the buffers picker. Without it `<C-k>` is undiscoverable.
Own highlight groups defined with `default = true` so a colorscheme can override.

### Entry points

`<leader>ll` ("List LSP servers") in the existing `<leader>l` = `lsp` which-key
group, alongside `<leader>lr` and `<leader>lk`; plus `:LspList` for symmetry with
`:LspReapIdle`. Both live in `lua/config/options.lua` next to `<leader>lk`.

### Error handling

- No active clients → `vim.notify` and do not open an empty picker.
- A client that dies between opening the picker and acting on it → guarded by
  `is_stopped()`, then refresh rather than error.
- After a kill, refresh the finder in place (`picker:refresh`, the `refetch`
  pattern from `ai_models`) so the list stays truthful.

### Testing

`tests/spec/unit/lsp_picker_spec.lua`, fake client tables:

- `rows`: idle-first ordering, name/root tiebreak, buffer counting, nil root.
- `format`: column alignment, singular `buf` vs plural, `:~` shortening,
  `(no root)`.
- `kill`: acts once, no-op on an already-stopped client.
- `restart`: re-attaches recorded buffers, degrades to stop at zero buffers,
  no-op on an already-stopped client.

Picker wiring follows the existing pickers, which the smoke specs already cover
(`which_key_spec` pins the `<leader>` desc and group requirements).

## Rejected

- **`vim.ui.select`** — one callback, so it cannot carry two distinct actions;
  kill-vs-restart would need a second prompt.
- **A bespoke float** (`util.overlay`) — reimplements filtering, scrolling and
  highlighting telescope already provides, for a list of five rows.
- **Memory / process columns per row** — actionable for the ~1 GiB-per-client
  problem, but needs a `ps` walk per open and the numbers are noisy under node GC.
  Left out; `docs/lsp-typescript-version.md` records the measured per-client cost.
- **`<CR>` jumping to the client's root in nvim-tree** — makes a server-management
  tool do file-tree work and couples the picker to nvim-tree.
