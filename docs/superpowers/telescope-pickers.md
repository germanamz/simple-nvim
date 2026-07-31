# Telescope pickers

Three custom pickers and the machinery they share. All of them open in normal
mode (`initial_mode = "normal"`); press `i`/`a` to type.

## The shared legend strip

`lua/util/picker_legend.lua` — a non-focusable float anchored under a picker's
results window, opening with the picker and closing with it.

It started as local code inside `telescope_smart.lua` for the git-status legend.
When the buffers picker grew its own flags legend the plumbing would have been
byte-identical, which is exactly the bar the
[extraction rule](refactoring.md#the-extraction-rule) sets. Following the
`util.overlay` precedent, the *shared* part is the plumbing and each caller keeps
its own content.

| Function | Responsibility |
| --- | --- |
| `results_win(prompt_bufnr)` | Resolve the results window from a prompt buffer, `nil` if telescope is not loaded or the window is gone |
| `render_segments(segs, opts)` | Segments (icon, count, label) → one line plus `{hl, start_col, end_col}` byte ranges |
| `fit_line(text, ranges, width)` | Center in `width`, shifting ranges along, and right-pad. Text at or above the width is returned unchanged |
| `mount(overlay, results_win, ns_name, lines, ranges_by_line)` | Window math and placement: below the results window, falling back to overlaying its bottom rows when there is no room. No-op when the legend would be taller than the results |
| `attach(prompt_bufnr, open, close)` | Lifecycle: deferred open (so the picker's windows exist), close on `BufLeave`/`BufWipeout` of the prompt buffer, re-render on `VimResized` |

The resize case is the subtle one. Telescope repositions its own windows in place
on the same `prompt_bufnr`, so an editor-anchored legend would be left stranded;
re-rendering re-anchors it.

Callers: `config.telescope_smart` (git-status counts), `config.buffers_legend`,
`config.lsp_picker`. `config.review_base`'s base overlay uses `util.overlay`
directly — it is editor-centered rather than results-anchored.

## Buffers flags legend — `<leader>fb`

`lua/config/buffers_legend.lua`. The indicator column telescope's buffers picker
renders (`%a +`, `#h`, …) is cryptic. `M.open()` launches
`telescope.builtin.buffers()` with an `attach_mappings` that wires a static
two-row legend:

```
+ modified   % current   # alternate <C-^>
a active     h hidden    = read-only
```

Only the six flags `make_entry.gen_from_buffer` can actually render are listed.
It builds the column as exactly `%`/`#`, then `a`/`h`, then `=`, then `+` — the
rest of `:ls`'s alphabet (`-`, `u`, `x`, `R`, `F`) can never appear here, so
listing it would be noise. Both rows fit the ~43-cell results window of a
120-column horizontal layout, and the float sets `wrap = false` so an overlong
row clips instead of pushing the second row out of sight.

`M._build_lines(width)` is the pure line builder, exposed for the unit spec.

## Folder-scoped live grep — `<leader>fG`

`lua/config/telescope_grep.lua`. `<leader>fg` always greps the repo toplevel; on
a superproject that buries the twenty matches you want under hundreds you do not.
`<leader>fG` is the same `live_grep` picker narrowed to a directory you choose.

One module owns "what directory does a grep picker search", for both scopes:

| Function | Responsibility |
| --- | --- |
| `root()` | Repo toplevel, cwd outside a repo. The project-wide scope `<leader>fg` and `<leader>fs` use. `lua/plugins/telescope.lua` delegates here, so the two scopes are not defined in different files |
| `seed()` | The directory the prompt opens on |
| `grep(dir)` | Normalize `dir`, then open `live_grep` scoped to it. Returns the directory searched, or `nil` when the path does not exist |
| `prompt()` | `vim.ui.input` seeded per `seed()`, then `grep()` |

Note that `root()` resolves the *cwd's* repo, not the focused buffer's. A grep is
a project-wide verb, so it deliberately does not narrow to whichever submodule a
buffer happens to live in — unlike the review-base keys, which do.

### One keymap, seeded

Two mechanisms were wanted: the node under the cursor in nvim-tree, and typing a
path. A seeded prompt serves both, so they collapse into one key rather than two.
`<leader>fG` always asks through `vim.ui.input`, pre-filled with

- the nvim-tree node under the cursor when the tree is focused (a file node seeds
  its parent folder), or
- the focused buffer's own folder anywhere else (the cwd for an unnamed buffer,
  via `util.path.buf_start_dir`).

The common case is one `<CR>`; the path stays editable, so you can backspace a
component to widen, `<Tab>`-complete deeper, or replace it entirely. The
alternative — fire immediately in the tree, prompt elsewhere — saves one keypress
but makes the same key mean two different things depending on where the cursor
is, and gives up widening from the tree.

`seed()` probes directory-ness with `isdirectory()` rather than reading
`node.type`, because nvim-tree hands out field-only clones of its nodes whose
shape is not guaranteed (the trap recorded in `config.nvim_tree_hl_decorator`).
The filesystem is the authority anyway.

The keymap is registered **once**, in the telescope spec's `keys`. nvim-tree maps
no leader keys buffer-locally, so the global mapping is not shadowed inside the
tree and `seed()` detects the tree itself. The e2e spec presses the key from
inside the tree, so the day that assumption breaks, a test fails.

### Normalization

`grep()` accepts what a human types or yanks. `~` and `$VAR` expand; a relative
path resolves against the cwd, matching the vocabulary the prompt's
`completion = "dir"` speaks. A path pointing at a **file** collapses to its
parent — the same rule `seed()` applies to a file node, so one behavior covers
both entry points. A path that is neither notifies at `WARN` and opens no picker,
with the trailing slash `:p` adds trimmed off so the message does not read as if
you had typed it. Empty, `nil`, whitespace, and a cancelled prompt are silent
no-ops.

The seed is displayed through `:.` — cwd-relative when it lives under the cwd,
absolute otherwise — because that is what `completion = "dir"` completes against,
with a trailing slash so `<Tab>` continues *inside* the seeded directory rather
than completing its siblings. `:.` has no relative form for the cwd itself and
hands back the absolute path, which made the most ordinary seed there is (any
buffer at the project root, or an unnamed one) a 60-character prompt line. That
case is special-cased to `./` — found while testing, not while designing.

The title is `Live Grep (<path relative to root>)`, or the basename when the
scope is the root. Without it a scoped picker is indistinguishable from
`<leader>fg`'s, and a scoped search with no matches looks like a broken
project-wide grep. Passing `cwd` only sets ripgrep's search directory: the
`pickers.live_grep` `additional_args` from telescope's `setup()` still apply, so
the result set matches `<leader>fg`'s (hidden files searched, `.git` pruned)
rather than quietly differing.

## LSP client picker — `<leader>ll` / `:LspList`

`lua/config/lsp_picker.lua`. Neovim never reaps LSP clients — there is no
zero-buffer autostop — so a session that visits several repos in a superproject
accumulates one client per root, each holding its processes (roughly 0.7 GiB and
three node processes for a warm `ts_ls`). `<leader>lk` sweeps every *idle* client
at once and `:lsp stop <name>` kills by server name, but neither lets you see
what is running and stop one specific client. `<leader>lr` restarts only the
clients attached to the **current** buffer, so a client for another root could not
be restarted at all.

Split so the logic is unit-testable over fake client tables, the way
`lsp_reap.idle` is:

| Function | Kind | Contract |
| --- | --- | --- |
| `M.rows(clients)` | pure | `{ client, name, nbufs, root }` per client, **idle-first** (0 buffers), then by name, then root |
| `M.format(row)` | pure | `ts_ls          2 bufs   ~/projects/lola-web` — aligned columns, root through `fnamemodify(root, ":~")`, `(no root)` when absent |
| `M.kill(client)` | effect | Stop unless already stopped; returns whether it acted |
| `M.restart(client)` | effect | Stop, wait for exit, re-attach its buffers; returns the count re-attached |
| `M.open()` | effect | Build and open the picker |

Idle-first ordering puts the kill candidates at the top, and `generic_sorter`
preserves that order while the prompt is empty.

| Key | Action |
| --- | --- |
| `j` / `k` | move between clients (deliberately untouched) |
| `<C-k>` | stop the client under the cursor, after `vim.fn.confirm` |
| `<CR>` | restart the client under the cursor |
| `<esc>` | close (normal mode); `<C-c>` from insert |

**Why `<C-k>` and not bare `k`.** This config opens pickers in normal mode, where
`k` moves the selection up. Binding a destructive action to bare `k` would remove
navigation from the one picker where you most need to move between rows before
acting. `<C-k>` keeps the mnemonic, works from both modes, matches the
`map({ "i", "n" }, …)` idiom the other custom pickers use, and shadows telescope's
global insert-mode `<C-k>` inside this picker only.

**Restart is the fiddly part.** The target client's buffers are not current, so
`<leader>lr`'s stop-and-`:edit` trick does not apply:

1. Record `client.attached_buffers`, valid and loaded only.
2. `client:stop()`.
3. Wait, bounded at `STOP_TIMEOUT_MS = 2000`, for `client:is_stopped()`. Stop is
   asynchronous, and starting a new client before the old one exits risks the
   reuse path selecting the dying one.
4. Re-fire `FileType` per recorded buffer, because that is the autocmd
   `vim.lsp.enable()` installs to start and attach the server.

A client with zero attached buffers has nothing to re-attach, so restart degrades
to a plain stop and reports that.

A legend strip carries `<CR> restart   <C-k> stop   <esc> close`; without it
`<C-k>` is undiscoverable. No active clients means a `vim.notify` rather than an
empty picker; a client that dies between opening and acting is caught by
`is_stopped()`; after a kill the finder refreshes in place so the list stays
truthful.

### Rejected

- **`vim.ui.select`** — one callback, so it cannot carry two distinct actions;
  kill-versus-restart would need a second prompt.
- **A bespoke float** — reimplements filtering, scrolling and highlighting
  telescope already provides, for a list of five rows.
- **Memory and process columns per row** — actionable for the ~1 GiB-per-client
  problem, but needs a `ps` walk per open and the numbers are noisy under node GC.
  [`../lsp-typescript-version.md`](../lsp-typescript-version.md) records the
  measured per-client cost instead.
- **`<CR>` jumping to the client's root in nvim-tree** — makes a server-management
  tool do file-tree work and couples the picker to nvim-tree.
