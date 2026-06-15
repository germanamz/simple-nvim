# Markdown glow preview — design

**Date:** 2026-06-14
**Status:** Approved (pending spec review)

## Problem

Markdown in this config renders correctly in-buffer (`render-markdown.nvim`), but
reading is awkward:

- `wrap = false` (global, `options.lua:129`) means long prose lines run off-screen
  and require horizontal scrolling.
- Enabling soft-wrap would fix prose but **shatter tables**, which routinely exceed
  the window width — soft-wrap splits rows mid-cell and destroys alignment.

`render-markdown.nvim` does not help here: it decorates **in place** (hides markers,
draws icons) but never reflows lines, so neither the horizontal-scroll nor the
table problem is affected by it.

The root constraint: `wrap` is a per-window option, not per-region, so a single
buffer cannot statically wrap prose while leaving tables unwrapped.

## Approach

Offload layout to a real renderer in a **read-only preview pane** — the VSCode
"rendered side document" model. Because a true layout engine reflows prose *and*
keeps wide tables intact, it dissolves the wrap-vs-table tension instead of
fighting it in-buffer.

Renderer: **glow** (charmbracelet terminal markdown renderer). It reflows prose
and tables to a target width and emits styled ANSI output.

This is a **reading aid only**. It does not change the editing buffer — authoring
still happens in the raw, long-line source buffer as today. The existing
`render-markdown` in-buffer decoration stays exactly as-is.

## Decisions (locked)

| Topic            | Decision |
| ---------------- | -------- |
| Renderer         | `glow` (external binary; documented install + graceful fallback) |
| Color handling   | Render glow inside a Neovim **terminal buffer** — nvim's terminal emulator carries glow's full color. **(Revised after verification: baleia was the original plan but glow emits no color when piped, and a captured pty hangs on glow's terminal-capability queries. Only a real terminal buffer yields color. No baleia dependency.)** |
| Layout           | Vertical split on the **right**; read-only terminal buffer |
| Trigger          | Manual toggle `<leader>mp`. No auto-open. |
| Live update      | Refresh on save / leaving insert / debounced (~300 ms) normal-mode edits, rendering the live buffer via a private temp file (no save of your document required). **Not** every keystroke — each refresh re-runs glow in the terminal, so this limits redraw flicker. |
| Width            | glow `-w` = preview pane width − ~6 (left margin); recompute on resize |
| Scroll sync      | **Approximate** — sync preview to the same % through the doc as the source cursor (exact line-mapping is impossible because glow reflows) |

## Non-goals

- No exact, line-mapped scroll sync (glow reflows; source line → rendered line has
  no stable mapping).
- ~~No replacement of `render-markdown.nvim`'s in-buffer decoration.~~ **(Superseded:
  render-markdown.nvim was later removed in favor of this preview — editing is now
  raw markdown, reading happens in the preview pane.)**
- No browser preview (rejected — window-switching cost).
- No auto-install of glow (mason doesn't carry it; cross-platform scripted install
  is fragile). Install stays a documented manual step.
- No change to the editing buffer's wrap / long-line behavior.

## Architecture

One new file (no plugin dependency, since baleia was dropped), following the
existing custom-module convention (`markdown_paragraphs.lua`, `block_guides.lua`):

### `lua/config/markdown_preview.lua` — the engine

Wired from `init.lua` via `require("config.markdown_preview").setup()`, alongside
`block_guides`/`statusline`/`lsp_refs` (config-only modules are loaded there, not
through `lua/plugins/`).

**State** (keyed by source buffer): source bufnr, preview winid, current preview
(terminal) bufnr, debounce timer, current glow job, generation counter, augroup
id, temp-file path.

**Public functions**

- `M.setup()` — install a `FileType` autocmd for `markdown`/`mdx` that sets the
  buffer-local `<leader>mp` → `M.toggle` (desc `"Toggle markdown preview"`), and
  backfill any markdown buffers already open.
- `M.toggle()` — preview open for this source → `close`; else `open`.
- `M.open(src_buf)` — guard on `vim.fn.executable("glow")` (see Fallback); open a
  right-hand split (`nvim_open_win`, `enter=false`, so focus stays on the source)
  with a placeholder scratch buffer; set window-local display options
  (`number=false`, `signcolumn=no`, `statuscolumn=""`, `wrap=false`,
  `winfixwidth`); allocate a temp file; wire per-source autocmds; first `refresh`.
- `refresh(src_buf)` — write the live source lines to the temp file; create a
  fresh terminal buffer; inside `nvim_win_call(preview_win, …)` set it current and
  `termopen({"glow","-s",<style>,"-w",<width>, tmpfile})`; on exit, strip nvim's
  trailing `[Process exited N]` line and `sync_scroll`; swap it into the preview
  window and wipe the previous terminal buffer. A generation counter discards
  stale renders.
- `sync_scroll(src_buf)` — `pct = src_cursor_line / src_line_count`; place the
  preview view at the same fraction of the preview's line count.
- `M.close(src_buf)` — delete the augroup (first, to avoid WinClosed re-entry),
  stop the timer, `jobstop`, close the window, wipe the buffer, delete the temp
  file, clear state.

**Autocmds wired while a preview is open** (in a per-source augroup):

- `BufWritePost` / `InsertLeave` / `TextChanged` on the source → debounced
  `refresh`. (Deliberately **not** `TextChangedI` — avoids flicker while typing.)
- `CursorMoved` on the source → `sync_scroll` (approximate).
- `VimResized` / `WinResized` → debounced `refresh` (recomputes width).
- `WinClosed` (preview) / `BufWipeout` / `BufDelete` (source) → `close` / cleanup.

### Render pipeline (the load-bearing detail)

```
live source buffer lines
  → writefile(lines, tmpfile)                       (render the unsaved buffer)
  → new scratch buffer, shown in the preview window
  → nvim_win_call(preview_win): termopen(
        { "glow", "-s", <dark|light>, "-w", <panewidth−6>, tmpfile })
  → nvim's terminal emulator renders glow's full-color output into the buffer
  → on_exit: strip trailing "[Process exited N]" line; approximate scroll sync
  → wipe the previous terminal buffer
```

- The **terminal buffer** is what gives color: glow only colors a real TTY, and
  nvim's terminal emulator is one. Rendering a temp file (not stdin) avoids the
  pty stdin/EOF hassle while still rendering the **unsaved** buffer.
- An explicit `-s dark`/`-s light` (not the default `auto`) is also needed; `auto`
  renders monochrome off-TTY.
- Debounce uses a libuv timer (`vim.uv.new_timer`): on change, `stop()` then
  `start(300, 0, schedule_wrap(refresh))`.

### Graceful fallback

`M.open` / `M.toggle` check `vim.fn.executable("glow") == 1`. If glow is absent:
`vim.notify` once (per session) with the install hint
(`brew install glow` / `go install github.com/charmbracelet/glow@latest`) and
abort. The config still loads cleanly on a fresh machine; the feature simply stays
dormant until glow is installed.

## Documentation (explicit requirement)

The `<leader>mp` binding must be documented in **all four** places existing keymaps
live:

1. `lua/plugins/which-key.lua` — add `{ "<leader>m", group = "markdown" }` to the
   `spec`.
2. The keymap `desc = "Toggle markdown preview"` (surfaces via `<Space>?` Telescope
   keymaps and which-key).
3. `docs/keybindings.md` §18 "Markdown / MDX" — add a `<Space>mp` table row plus a
   short paragraph: read-only full-color glow preview; refreshes on save / leaving
   insert / edits; reflows prose and keeps wide tables aligned (wide cells
   truncated, not shattered); approximate %-based scroll sync; requires the `glow`
   binary.
4. `README.md` "What's included" — extend the **Markdown** bullet (line 92) to
   mention the glow-backed preview and its `glow` prerequisite.

## Verification outcomes

Verified against glow on this machine (`/opt/homebrew/bin/glow`) before/while
implementing — several assumptions in the original plan were **falsified**:

- **Color requires a TTY.** Piping glow (`vim.system`) yields bold/italic only —
  no foreground color — regardless of `CLICOLOR_FORCE` / `FORCE_COLOR` /
  `COLORTERM` / `-s dark`. A captured pty (`jobstart{pty=true}`) **hangs** on
  glow's terminal-capability queries (OSC 10/11 + DSR), even when answered
  manually. A Neovim **terminal buffer renders in full color in ~18 ms** because
  nvim's emulator answers those queries. → drove the switch to the terminal buffer
  and the removal of baleia.
- **Wide-table behavior is acceptable.** At a narrow `-w`, glow keeps the table
  aligned with box-drawing borders and truncates over-wide cells with `…` (it does
  **not** shatter the table the way soft-wrap does). Confirmed in the e2e render.
- **Width margin.** glow lays out to roughly `-w` + 6 columns (left margin), so the
  engine targets `panewidth − 6` to avoid horizontal overflow.
- **`[Process exited N]` line.** A finished terminal job appends this line; the
  engine strips it in `on_exit`. Confirmed absent in the rendered buffer.
- **Lifecycle + fallback.** Headless e2e confirms open creates the split, glow
  renders, close removes the window and temp file, and the full real config loads
  cleanly with the new `init.lua` wiring. When `glow` is absent the toggle notifies
  once and no-ops.

Remaining to confirm interactively (needs a real UI, not headless): the
flicker/scroll feel during live editing at a normal pane width, and color contrast
under the user's colorscheme.

## Testing

- **Manual smoke** (primary, given the external binary): open a doc with long prose
  + a wide table → `<leader>mp` → preview renders, prose wraps, table stays
  readable; edit without saving → preview updates after the debounce; resize →
  reflows; move the cursor → preview tracks approximately; `<leader>mp` again →
  closes; rename/remove glow from PATH → toggle notifies and no-ops without error.
- **Automated** (light): an e2e that toggles in a markdown buffer should assert the
  **graceful-fallback** path (notify, no crash) since CI likely lacks glow. See
  the memory note that the nvim test harness needs the Claude sandbox disabled.
