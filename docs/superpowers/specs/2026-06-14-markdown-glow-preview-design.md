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
| Color handling   | `baleia.nvim` — translate glow's ANSI into real highlights in a normal scratch buffer |
| Layout           | Vertical split on the **right**, read-only scratch buffer (`nofile`) |
| Trigger          | Manual toggle `<leader>mp`. No auto-open. |
| Live update      | Debounced (~250 ms) refresh by piping the **live buffer** to glow over stdin — no save required |
| Width            | glow width = preview pane width; recompute on resize |
| Scroll sync      | **Approximate** — sync preview to the same % through the doc as the source cursor (exact line-mapping is impossible because glow reflows) |

## Non-goals

- No exact, line-mapped scroll sync (glow reflows; source line → rendered line has
  no stable mapping).
- No replacement of `render-markdown.nvim`'s in-buffer decoration.
- No browser preview (rejected — window-switching cost).
- No auto-install of glow (mason doesn't carry it; cross-platform scripted install
  is fragile). Install stays a documented manual step.
- No change to the editing buffer's wrap / long-line behavior.

## Architecture

Two new files, following the existing custom-module convention
(`markdown_paragraphs.lua`, `block_guides.lua`):

### 1. `lua/plugins/markdown-preview.lua` — lazy.nvim spec

- Declares the only new plugin dependency: `m00qek/baleia.nvim`.
- Lazy-loads on `ft = { "markdown", "mdx" }`.
- `config` requires `config.markdown_preview` and calls its `setup()`.

### 2. `lua/config/markdown_preview.lua` — the engine

A module with a header comment (matching the style of the other `config/*` modules)
explaining purpose and the glow/baleia/stdin pipeline.

**State** (keyed by source buffer): source bufnr, preview bufnr, preview winid,
debounce timer handle, current glow job handle, shared baleia instance.

**Public functions**

- `M.setup()` — create the singleton baleia instance; install a `FileType`
  autocmd for `markdown`/`mdx` that sets the buffer-local `<leader>mp` →
  `M.toggle` (desc `"Toggle markdown preview"`). This mirrors how
  `options.lua` wires `markdown_paragraphs.attach` per buffer.
- `M.toggle()` — preview open for this source → `close`; else `open`.
- `M.open(src_buf)` — guard on `vim.fn.executable("glow")` (see Fallback); open a
  right-hand `vsplit`; create the scratch preview buffer (`buftype=nofile`,
  `bufhidden=wipe`, `swapfile=false`, `modifiable=false` to the user,
  `number=false`, `signcolumn=no`, `statuscolumn=""`, `wrap=false` — glow already
  wraps to width); wire per-source autocmds (below); return focus to the source;
  trigger the first `refresh`.
- `M.refresh(src_buf)` — read the source lines, compute width from the preview
  window, run glow (see Pipeline), and on completion write the colorized output
  into the preview buffer, then restore the previous preview scroll position.
- `M.sync_scroll(src_buf)` — `pct = src_cursor_line / src_line_count`; place the
  preview view at the same fraction of the preview's line count.
- `M.close(src_buf)` — stop the timer, kill any in-flight glow job, close the
  window, wipe the buffer, clear autocmds and state.

**Autocmds wired while a preview is open** (in a per-source augroup):

- `TextChanged` / `TextChangedI` on the source → debounced `refresh`.
- `CursorMoved` / `WinScrolled` on the source → `sync_scroll` (approximate).
- `VimResized` / `WinResized` → recompute width + `refresh`.
- `WinClosed` / `BufWipeout` (preview or source) → `close` / cleanup.

### Render pipeline (the load-bearing detail)

```
source buffer lines
  → vim.system({ "glow", "-w", <panewidth>, "-" },
               { stdin = <text>, env = { CLICOLOR_FORCE = "1", ... } }, on_exit)
  → on_exit (vim.schedule): stdout = ANSI-styled lines
  → set lines in preview buffer (temporarily modifiable)
  → baleia: strip ANSI, apply highlights as extmarks
  → modifiable = false; restore scroll
```

- Piping the live buffer over **stdin** is what makes updates appear without
  saving.
- `CLICOLOR_FORCE=1` forces color even though stdout is not a TTY (glow/termenv
  honor it). **This is unverified until glow is installed — first thing to confirm.**
- Debounce uses a libuv timer (`vim.uv.new_timer`): on change, `stop()` then
  `start(250, 0, schedule_wrap(refresh))`.

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
   short paragraph: live, read-only glow preview; updates as you type; reflows prose
   and wide tables to the pane; approximate %-based scroll sync; requires the `glow`
   binary.
4. `README.md` "What's included" — extend the **Markdown** bullet (line 92) to
   mention the glow-backed live preview and its `glow` prerequisite.

## Risks & verification

- **glow stdin + width + forced color** — the whole pipeline assumes
  `glow -w N -` reads stdin and `CLICOLOR_FORCE=1` yields ANSI. Verify immediately
  after `brew install glow`; if `-` is rejected, fall back to bare stdin (glow
  auto-detects a pipe).
- **glow wide-table behavior** — the entire premise is that glow renders
  wider-than-pane tables more readably than nvim soft-wrap. Verify glow degrades
  acceptably (reflow/scale) at realistic pane widths with a genuinely wide table.
- **Refresh cost** — baleia + glow on every keystroke would be heavy; the 250 ms
  debounce mitigates. Confirm responsiveness on a large document.
- **Off-by-one width** — pane width vs glow's border math; tune `-w` if the output
  is one column too wide and wraps.

## Testing

- **Manual smoke** (primary, given the external binary): open a doc with long prose
  + a wide table → `<leader>mp` → preview renders, prose wraps, table stays
  readable; edit without saving → preview updates after the debounce; resize →
  reflows; move the cursor → preview tracks approximately; `<leader>mp` again →
  closes; rename/remove glow from PATH → toggle notifies and no-ops without error.
- **Automated** (light): an e2e that toggles in a markdown buffer should assert the
  **graceful-fallback** path (notify, no crash) since CI likely lacks glow. See
  the memory note that the nvim test harness needs the Claude sandbox disabled.
