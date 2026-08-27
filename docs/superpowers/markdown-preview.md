# Markdown preview

`lua/config/markdown_preview.lua` — `<leader>mp` hands a markdown file to a
**cmux markdown panel**: a surface of the terminal this Neovim runs inside, which
renders the file with real formatting and re-renders it whenever it changes on
disk. Neovim draws nothing. There is no preview window, no split and no terminal
buffer. Press `<leader>mp` again on the same file to close its panel; the keymap
fires from a markdown buffer and from nvim-tree alike.

## Why a preview at all

`wrap = false` is global in this config, so long prose lines run off-screen.
Turning soft-wrap on would fix prose but **shatter tables**, which routinely
exceed the window width: soft-wrap splits rows mid-cell and destroys alignment.
`wrap` is a per-window option, not per-region, so one buffer cannot statically
wrap prose while leaving tables alone.

`render-markdown.nvim` did not help — it decorates in place (hides markers, draws
icons) but never reflows, so neither problem moved. It was subsequently removed.
Editing is raw markdown; reading happens somewhere that does real layout.

**A browser preview was considered and rejected** — the window-switching cost
defeats the point of a reading aid you glance at while editing. This is the first
alternative anyone suggests (`markdown-preview.nvim` and friends all take that
route), so it is recorded here rather than re-litigated. A cmux panel is not that
idea under another name: it is a pane of the window you are already looking at,
which is precisely what the browser failed to be.

## What replaced what

The first implementation rendered the buffer through
[`glow`](https://github.com/charmbracelet/glow) into a Neovim **terminal buffer**
in a right-hand split, re-running the binary on a 300 ms debounce after every
edit. Three things ended it:

- **Neovim was the render loop.** Every edit rewrote a temp file, re-ran a
  subprocess and swapped a fresh terminal buffer into the split, with a
  generation counter to discard stale renders. A cmux panel watches the file
  itself, so the config now schedules nothing: `<leader>mp` fires a few socket
  calls once and the panel keeps up on its own for the rest of the session.
- **One width had to serve prose and tables.** glow lays out to a fixed `-w`,
  reflowing prose to the pane while truncating any cell wider than it with `…`.
  Widening the pane for the table over-widens the prose, so a document with both
  never rendered whole either way.
- **The binary was a dependency with a dormant mode.** glow is not in mason and a
  scripted cross-platform install is fragile, so the feature shipped with an
  install hint (`brew install glow`) and a notify-once no-op on any machine that
  did not have it.

One finding from that era is worth keeping, because it is the reason the design
ended up in a terminal buffer and anyone piping a TUI renderer into Neovim will
rediscover it: **glow's color needs a TTY**. Piping it through `vim.system`
yields bold and italic but no foreground color regardless of `CLICOLOR_FORCE`,
`FORCE_COLOR`, `COLORTERM` or `-s dark`, and a captured pty
(`jobstart { pty = true }`) *hangs* on its terminal-capability queries (OSC 10/11
plus DSR) even when they are answered by hand. Only a real terminal emulator —
Neovim's own, then; cmux's now — renders it in full color. Everything else about
the glow pipeline is in git history and stays there.

## What the cmux CLI actually does

Five probes against the real CLI, each of which shaped the code and each of which
is exactly what a future reader would try again:

| Probe | Result |
| --- | --- |
| `markdown open <file>` | **Always splits a new pane.** There is no `--pane` flag: no primitive opens a panel *into* an existing pane. |
| `markdown open` on a file already showing | Opens a **second panel**. cmux does not dedupe by path, so file identity is the caller's problem. |
| `new-surface --type markdown` | Accepted, and silently produces a plain **terminal** surface. `markdown` is not a supported `--type` despite the flag taking it. |
| `move-surface --focus false` | **Ignored.** The move takes focus every single time. |
| `close-surface` on a surface that is gone | Exits **1** with `Surface not found` (exit 0 on a live one). |

### Tabbing means open-then-move

Rows one and three leave exactly one way to get every preview into a single
pane: open the panel wherever cmux insists on putting it, then move it. So the
second and later files cost three calls.

```
markdown open <file> --focus false --surface <a surface already in the preview pane>
move-surface --surface <the new panel> --pane <the preview pane>
focus-pane   --pane <the pane the keypress came from>
```

Only the `markdown open` line is shown stripped down: it really leads with the
global `--json --id-format both`, because its response is the one that has to be
parsed (`surface_id` for the state table, `target_pane_id` to tell a tabbed open
from a first one). The other two are judged by exit code alone.

- **`--surface` on the open is what keeps the editor still.** cmux splits the new
  pane off the surface you name, so naming one that already lives in the preview
  pane puts the transient split inside that column. Neovim's own pane is never
  resized; without the anchor the split comes off it and the editor shrinks and
  grows again on every preview.
- **The trailing `focus-pane` is mandatory, not cosmetic.** `move-surface`
  ignores `--focus false`, so by the time the move returns the focus is sitting
  in the preview pane. Without the third call, every preview after the first
  would leave you typing into a markdown panel.
- **The pane to focus back cannot be read off the anchored open.** The obvious
  source is the open response's `source_pane_id` — and it is wrong exactly when
  it is needed: `--surface <anchor>` makes the anchor the split source, so an
  anchored open reports the *preview* pane as its source, and focusing that
  leaves focus precisely where the move stranded it. The caller's pane comes from
  `tree`'s `caller.pane_id` instead, or from an unanchored open, where
  `source_pane_id` really is us. When neither has ever answered, the third call
  is skipped rather than aimed at a guess: focusing the wrong pane would yank you
  somewhere you never asked to go, which is worse than the focus being off by
  one.
- **The cost, stated honestly.** Three socket round-trips, and a brief flash of
  the intermediate pane before it collapses into the preview column. That buys
  tabs instead of a wall of splits, which is the whole point of the feature on a
  screen you are also editing in.

The *first* file skips all of this: it has no preview pane to tab into, so
whatever pane `markdown open` split becomes the preview pane, and nothing took
focus that has to be given back.

### The toggle is self-correcting because `close-surface` fails loudly

Exit 1 / `Surface not found` distinguishes "I closed it" from "it was closed
behind my back", so `close()` re-opens instead of leaving the state machine one
press behind. Closing a panel tab by hand in cmux therefore costs nothing: the
next `<leader>mp` on that file opens it again, which is what you meant by
pressing it.

### What a surface will not tell you

`cmux --json tree` describes each surface with a **basename `title` and a null
`url`** — never the path it renders. A panel that predates this Neovim session
cannot be matched back to a file, and that sets the ceiling on startup adoption.

`discover()` runs once, lazily, before the first open: it scans the caller's
workspace for a pane whose surfaces are *all* markdown panels and adopts it, so
restarting Neovim tabs back into the panel column that is already there instead
of splitting a second one beside it. An empty pane does not qualify — an empty
pane is not evidence of anything.

It adopts the **pane only**. A file previewed in a previous session gets a second
tab when it is previewed again, and that is the accepted cost of not guessing:
matching by basename would eventually show a different repo's `README.md`, and
the mistake would look exactly like a working preview.

## State is keyed by path, not by buffer

`<leader>mp` also fires from nvim-tree, where the file has no buffer to key on,
so the state table is `absolute path -> surface id` and both entry points
canonicalize through `M._canonical` before touching it. That also makes the
toggle symmetric across the two: open a preview from the tree, close it from the
buffer.

That table is the only thing standing between you and duplicate panels, since
cmux will re-open a file it is already showing without complaint. Canonicalizing
is not decoration: a buffer name can be relative or `~`-prefixed where the tree
node is absolute, and two spellings of one path are two panels — one of which the
toggle can no longer close, because the press that would close it keys on the
other spelling.

So `M._canonical` is `fnamemodify(":p")`, then `vim.fs.normalize`, then
`vim.uv.fs_realpath`. The last step is not paranoia: on macOS `/tmp` is a symlink
to `/private/tmp`, and a buffer name comes back already resolved where an
nvim-tree node does not, so the two entry points genuinely disagree about the
same file until something resolves the link.

`fs_realpath` alone was not enough, and the gap is worth recording because it
looks fixed until you test the right file. It answers only for a path that
**exists**, so the first version of this collapsed spellings of files already on
disk and quietly failed for a markdown buffer holding a file you have not saved
yet — which is a case this keymap genuinely reaches. When the whole path will not
resolve, `M._canonical` now walks up to the deepest ancestor that does, resolves
that, and re-attaches the tail, so `/tmp/new.md` and `/private/tmp/new.md` land
on one key before either exists. Only a path with no resolvable ancestor at all
keeps the plain normalized spelling, which is better than losing the preview.

Nothing here watches buffer lifecycle. A cmux panel is an independent pane with
its own file watcher, so wiping the buffer is not a reason to kill it — the
`BufWinLeave` / `BufWinEnter` / `BufWipeout` group the glow implementation needed
to keep a split beside its source has no counterpart at all. Panels outlive their
buffers on purpose.

The tree keymap reads `node.absolute_path` and asks the filesystem rather than
calling `node:is_dir()`: nvim-tree hands `on_attach` and decorator callers
field-only **clones** of its nodes, fields and no methods (the same trap
documented in `config.nvim_tree_hl_decorator`). The markdown test runs through
`util.ft.is_markdown_path`, i.e. `vim.filetype.match` on the name, so the tree
agrees with whatever a buffer of that file would have been rather than carrying
an extension list of its own.

## What you see is what is on disk

cmux renders and watches the file on disk, so a modified buffer previews as its
**last saved state**. The keymap warns that it did and previews anyway. It does
not write your file: an edit-on-read is a surprise, and every later `:w`
re-renders the panel by itself.

Rendering a temp copy instead — the trick the glow implementation used to preview
unsaved work — would hand cmux a path that is not the one you are editing, so
every keystroke would have to be mirrored into that temp file by Neovim. That is
the render loop this rewrite removed, re-entered through the back door.

## Failure branches

| Situation | Behavior |
| --- | --- |
| Not a cmux session (`util.cmux.bin()` → nil) | Notify **once per session**, then no-op. The feature is dormant, not broken. |
| The anchor surface is gone | Retry the open with no `--surface`, keeping the pane — its other tabs are probably alive, and the move still lands the panel in the right column. |
| `markdown open` fails outright | Notify, naming the file's basename. |
| The preview pane is gone (`move-surface` exits non-zero) | The panel stays where it landed and that pane becomes the preview pane. Nothing stole focus, so there is nothing to put back. |
| `close-surface` says `Surface not found` | Re-open: the tab was closed by hand. |
| The buffer has no name | Notify — there is no file on disk to render. |
| The tree node is a directory, or not markdown | Notify, naming the node. |

"Not a cmux session" is answered by `util.cmux.bin()`, shared with
`config.open_url` so the rule is stated once. It keys on **`CMUX_SURFACE_ID`, not
`TERM_PROGRAM`**: cmux embeds Ghostty, so `TERM_PROGRAM` reads `ghostty` and
would also match a plain Ghostty window, which has none of the panes we would be
opening into. It falls back to `CMUX_BUNDLED_CLI_PATH` when `cmux` is not on
`PATH`, which a `:terminal` or a session restore can trim while the surface is
still a cmux one.

## Wiring

No `setup()`, and nothing requires this module from `init.lua`. Two keymap
installers, each called from wherever that kind of buffer is already handled:

| Entry point | Called from | Binds |
| --- | --- | --- |
| `M.set_keymap(buf)` | the single markdown-family `FileType` autocmd in `lua/config/options.lua`, alongside `markdown_paragraphs.attach` and `wikilinks.set_keymap` | `<leader>mp` in `markdown` / `mdx` buffers |
| `M.set_tree_keymap(buf)` | nvim-tree's `on_attach` in `lua/plugins/nvim-tree.lua` | `<leader>mp` on the tree node under the cursor |

One autocmd, registered at startup before any file is read, means `nvim file.md`
hits it on the first `FileType` and no module has to backfill already-open
buffers.

Both keymaps resolve a path and then call the same three-function surface —
`M.toggle(path)`, `M.open(path)`, `M.close(path)` — which takes an absolute path
and nothing else. A third entry point (a command, another tree) needs no new
plumbing, only a path.

## Testing

Every cmux invocation funnels through one function, exposed as `M._run` for a
spec to replace: `fun(args, on_done)`, receiving the exact argv and calling back
with an exit code and stdout. That is enough to drive the whole state machine —
first open, tabbed open, the move, the focus restore, and every row of the
failure table above — with no cmux socket anywhere near the suite. `M._reset()`
clears the surface table, the adopted pane, the caller's pane and the one-shot
notices between specs, so nothing a spec learned leaks into the next one;
`M._state()` returns `{ pane, anchor, caller, surfaces }` to assert against —
every value the sequence above is decided from — and `M._canonical` /
`M._markdown_anchor` expose the two pure decisions.

**Nothing in the suite may spawn the real `cmux`.** A test that did would split
panes and steal focus in the developer's live terminal, and would find no socket
at all in CI. So the unit tier stubs both ends — `M._run` and `util.cmux.bin`.
The second matters as much as the first: without it every spec would no-op on any
machine that is not itself running cmux, and pass while asserting nothing.
`tests/spec/unit/markdown_preview_spec.lua` pins the exact argv of every call, in
order, because the order *is* the contract — each of the three calls exists to
undo what the one before it did. The smoke spec stops at wiring: the keymap is on
the buffer it belongs on, and a press that reaches no cmux does not blow up.

What is left for a person: where the transient pane flashes, and how the panel
reads beside the editor at a real width. Both were checked by hand.

## What went away with glow

Recorded because the docs promised both until this rewrite, and because both are
properties of *any* out-of-editor renderer rather than of cmux specifically:

- **`gd` inside the preview.** The glow pane was a Neovim buffer, so a rendered
  link could be followed from it — `wikilinks.follow_in_preview` matched the
  reflowed text back to the source, since glow's output carried no destinations.
  A cmux panel is a terminal pane: no cursor of ours to read, no keymap of ours
  to bind, and that function is deleted. **`gd` in the source buffer is
  untouched** and still follows wikilinks and standard links, falling back to LSP
  go-to-definition.
- **Scroll sync.** The panel scrolls on its own and does not follow the cursor.
  The old sync was approximate by construction (glow reflows, so it placed the
  preview at the same fraction through the document, offset by the frontmatter
  length) — but it existed, and it does not any more.

Two smaller casualties, so nobody goes looking for them. The temp file's **link
rewriting** is gone with the temp file: wiki-style `[[target]]` and standard
`[text](dest)` links were both rewritten to `[text](#)` so glow would render
link-styled text with no URL tail, and cmux needs no such help. And `GLOW_STYLE`,
the light-only style constant that was independent of the Neovim colorscheme, has
no successor — the panel's appearance belongs to cmux.

## Out of scope

- **Mapping existing panel tabs back to files.** Blocked on the surface JSON
  carrying a path; guessing by basename is worse than a duplicate tab.
- **Previewing unsaved work.** It costs the render loop back, and the warning is
  cheaper than the surprise.
- **An in-Neovim fallback when cmux is absent.** Keeping a second renderer alive
  for a case this config never runs in would mean maintaining the pipeline that
  was just deleted. Outside cmux the feature is dormant and says so.
- **Anything that puts Neovim back in the render path** — a refresh timer, a
  write-through on `TextChanged`, a scroll-sync round-trip per `CursorMoved`. The
  panel keeping itself current with no help is the property that made this
  rewrite worth doing.
