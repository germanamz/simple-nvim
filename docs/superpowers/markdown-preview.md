# Markdown preview

`lua/config/markdown_preview.lua` — a live, read-only markdown preview rendered
through [`glow`](https://github.com/charmbracelet/glow) in a right-hand split.
Toggle with `<leader>mp` from either the source buffer or the preview pane.

## Why a preview pane at all

`wrap = false` is global in this config, so long prose lines run off-screen.
Turning soft-wrap on would fix prose but **shatter tables**, which routinely
exceed the window width: soft-wrap splits rows mid-cell and destroys alignment.
`wrap` is a per-window option, not per-region, so one buffer cannot statically
wrap prose while leaving tables alone.

`render-markdown.nvim` did not help — it decorates in place (hides markers, draws
icons) but never reflows, so neither problem moved. Offloading layout to a real
renderer dissolves the tension instead of fighting it: glow reflows prose *and*
keeps wide tables intact, truncating over-wide cells with `…` rather than
shattering them.

`render-markdown.nvim` was subsequently removed. Editing is raw markdown;
reading happens in the preview.

**A browser preview was considered and rejected** — the window-switching cost
defeats the point of a reading aid you glance at while editing. This is the first
alternative anyone suggests (`markdown-preview.nvim` and friends all take that
route), so it is recorded here rather than re-litigated.

## What verification changed

Several assumptions in the original design were falsified against a real glow
before the code was written. These are the durable findings:

- **Color requires a TTY.** Piping glow through `vim.system` yields bold and
  italic but no foreground color, regardless of `CLICOLOR_FORCE`, `FORCE_COLOR`,
  `COLORTERM` or `-s dark`. A captured pty (`jobstart { pty = true }`) **hangs**
  on glow's terminal-capability queries (OSC 10/11 plus DSR), even when they are
  answered by hand. A Neovim **terminal buffer** renders in full color in about
  18 ms, because Neovim's own emulator answers those queries. That drove the
  switch to a terminal buffer and removed the planned `baleia` dependency
  entirely.
- **An explicit `-s dark`/`-s light` is required.** The default `auto` renders
  monochrome off a TTY.
- **glow lays out to roughly `-w` plus a ~6-column left margin**, so the engine
  targets `pane width − 6` to avoid horizontal overflow.
- **A finished terminal job appends a `[Process exited N]` line**, stripped in
  `on_exit`.

## The render pipeline

```
live source buffer lines
  → transform_links(lines) → writefile(tmpfile)      (renders the UNSAVED buffer)
  → fresh scratch terminal buffer
  → nvim_win_call(preview_win): jobstart(
        { "glow", "-s", "light", "-w", <panewidth − 6>, tmpfile })
  → Neovim's terminal emulator renders glow's full-color output
  → on_exit: strip "[Process exited N]"; sync scroll
  → swap into the preview window; wipe the previous terminal buffer
```

A generation counter discards stale renders. Rendering a temp *file* rather than
stdin sidesteps the pty stdin/EOF problem while still previewing unsaved work.

`GLOW_STYLE` is a constant `"light"`: the config is light-only, and glow's `-s`
style is its own theme, independent of the Neovim colorscheme. The
`ColorScheme` and `OptionSet background` re-render autocmds the design called for
are dead code and have been removed.

### Link rewriting

Added after the design, and load-bearing for how this config uses markdown.
`transform_links` rewrites two things before glow sees them:

- **Wiki-style `[[target]]` / `[[target|alias]]`** are not CommonMark, so glow
  prints them literally.
- **Standard `[text](dest)`** links get `dest` appended as a visible tail by
  glow, which for a local path is the meaningless temp-file path.

Both become `[text](#)` — a bare fragment, so glow renders link-styled text with
no tail. Images are left alone. The links stay usable: `gd` in the preview buffer
calls `config.wikilinks.follow_in_preview(src)`, matching the text back to the
source, because glow's output is reflowed and carries no target.

## Lifecycle

State is keyed by source buffer. Two augroups per source, deliberately split:

**Lifecycle** (created once when the preview is enabled, removed only on a real
close) ties the pane's existence to the file's visibility so the two move as a
group:

| Event | Behavior |
| --- | --- |
| `BufWinLeave` on the source | Hide the pane — but only once the file is gone from *every* window, so closing one split of a file shown twice keeps the preview |
| `BufWinEnter` on the source | Restore the pane next to it |
| `BufWipeout` / `BufDelete` on the source | Tear the whole group down |

**Window-scoped** (recreated on each show, torn down on each hide) drives the
output:

| Event | Behavior |
| --- | --- |
| `BufWritePost`, `InsertLeave`, `TextChanged` on the source | Debounced refresh, 300 ms, via a `vim.uv` timer. Deliberately **not** `TextChangedI` — each refresh re-runs glow, so per-keystroke rendering would flicker |
| `VimResized`, `WinResized` | Debounced refresh, recomputing the width |
| `CursorMoved` on the source | Approximate scroll sync |
| `WinClosed` on the preview | A real close: `:q` in the pane disables the preview rather than hiding it |

### Scroll sync

Approximate by construction — glow reflows, so source line to rendered line has
no stable mapping. The preview is placed at the same fraction through its line
count as the source cursor, then `zz`.

Two corrections that are not obvious:

- **Frontmatter offset.** glow strips YAML frontmatter, so the preview starts at
  the first source line after it. The source position is offset by the
  frontmatter length (`util.markdown.frontmatter_end`) or the fraction is wrong
  for the whole document.
- **Horizontal moves are skipped.** The sync maps the source *line*, so a move
  that leaves the line unchanged would recompute an identical position. The
  handler early-returns on it. `on_exit` calls `sync_scroll` directly, bypassing
  that guard, so a preview-length change still re-syncs.

## Wiring and fallback

Contrary to the design, this module has no `setup()` and is not required from
`init.lua`. It exposes `set_keymap(buf)`, called from the single markdown-family
`FileType` autocmd in `lua/config/options.lua` alongside
`markdown_paragraphs.attach` and `wikilinks.set_keymap`. One autocmd, registered
at startup before any file is read, means `nvim file.md` hits it on the first
`FileType` and no module needs to backfill already-open buffers.

`M.open` / `M.toggle` guard on `vim.fn.executable("glow")`. When glow is absent
they `vim.notify` once per session with the install hint (`brew install glow`, or
`go install github.com/charmbracelet/glow@latest`) and abort. The config loads
cleanly on a machine without it; the feature stays dormant.

There is no auto-install: mason does not carry glow, and a cross-platform
scripted install is fragile.

## Testing

`tests/spec/unit/markdown_preview_spec.lua` covers the pure pieces
(`_frontmatter_lines`, `_transform_links`);
`tests/spec/smoke/markdown_preview_spec.lua` covers wiring. CI would not have
glow, so the automated coverage asserts the graceful-fallback path. The parts
that need a real UI — flicker and scroll feel while editing at a normal pane
width, color contrast under the colorscheme — were checked by hand.
