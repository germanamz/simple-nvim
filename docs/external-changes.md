# Files changed outside nvim

An agent writing to disk, a CLI formatter, a `git checkout`, a codegen run — and
the file is open in a buffer. What follows is how the editor notices, what each
indicator does about it, and the four separate reasons it used not to.

## The symptom

Fix a problem on disk and the editor keeps reporting it: gitsigns hunk signs for
changes that are gone, LSP diagnostics for errors already corrected, ESLint
diagnostics that survive the fix, nvim-tree rows still coloured modified. Pressing
`<Space>lr` to restart the language server did not clear them either, which made
the whole thing read as one stubborn cache.

It was four unrelated defects that happened to look alike.

## 1. Nothing ever asked whether the file had changed

`'autoread'` is on by Neovim's default, but it is only a *policy* — it decides
what happens once a timestamp **check** has noticed something, and it does
nothing on its own. Neovim runs a check in exactly three situations: a real
terminal focus-gain, entering a buffer that is in a window, and the sweep after a
`:!cmd`. This config shells out only through `vim.system` and
`vim.fn.systemlist`, so the third never fires; and when the rewrite happens in a
neighbouring terminal pane while nvim keeps focus, neither do the first two.

The buffer therefore kept the pre-fix text. That alone explains the git and LSP
halves, because **both of them read the buffer, never the file**:

- gitsigns diffs `util.buf_lines(bufnr)` against a git blob.
- `vim.lsp` serializes buffer lines into `didOpen`/`didChange`
  (`$VIMRUNTIME/lua/vim/lsp.lua`, `_buf_get_full_text`). Every sync kind derives
  from the buffer; none of them reads the file.

So the signs and the diagnostics were arithmetically correct about text that no
longer existed.

`lua/config/file_reload.lua` is the missing half. It re-stats every open file
buffer on `FocusGained`, `BufEnter` and `CursorHold`, throttled to one sweep per
second, and lets `'autoread'` do the reload.

`CursorHold` fires once per idle period and does not re-arm until the cursor
moves, so this is not a poll: an editor left completely untouched since the
rewrite catches up on the next keypress or focus change, not on a timer. Verified
in a real TUI — an unmodified buffer follows the file after a single cursor move,
and a buffer with unsaved edits keeps them, stays `modified`, leaves the file on
disk alone, and takes the disk copy on `:e!`.

### Trap: a bare `:checktime` skips hidden buffers

`doc/editing.txt` says "each loaded buffer is checked". The implementation only
visits buffers with a window. Measured:

```
start:                      a=A1  b=B1        (a current, b hidden)
after global :checktime  -> a=A2  b=B1        hidden buffer NOT reloaded
after :checktime <bufnr> -> b=B2              per-buffer form does reach it
```

This matters more than it sounds, because the stale buffers are precisely the
hidden ones — the other seven files the agent rewrote while you were reading the
eighth. The conventional `autocmd FocusGained * checktime` recipe would have
fixed only what was on screen. The sweep uses the per-bufnr form.

### Trap: the conflict prompt is modal

If the file changed *and* the buffer has unsaved edits, Neovim's built-in answer
is a `W12` hit-enter prompt. A prompt is fine when you typed the command; from an
unattended `CursorHold` it would stop the editor dead. So the module owns
`FileChangedShell` and answers itself: the buffer is left exactly as it is, and
you get a one-row warning naming the file. Nothing is ever discarded — `:e!`
takes the disk copy, `:w` keeps yours.

Two details that are easy to get wrong here:

- The happy path is unaffected. For an **unmodified** buffer `'autoread'` reloads
  silently and `FileChangedShell` never fires at all, so owning the event costs
  nothing in the ordinary case.
- Inside an autocmd Neovim is `autocmd_busy` and suppresses the *decision* half
  of the check — a plain content change still reloads, but the conflict and
  deleted branches never fire. The sweep is therefore scheduled one tick off the
  autocmd stack, so the automatic edges behave like the manual hatch. Headless
  does not reproduce this suppression, so no spec can pin it.

The warning is kept to a single screen row deliberately. `vim.notify` here is
core's `nvim_echo` (this config installs no notify replacement), and a message
that wraps past `'columns'` becomes a hit-enter prompt — the exact thing the
handler exists to prevent, moved one step along.

### Cost

One `fs_stat` per open file buffer, no spawn. A forced sweep over 201 real file
buffers measured 3.68 ms. It scales with how many files you have open, not with
repo size, which is why it can ride `CursorHold` in a config that turned
`workspace/didChangeWatchedFiles` off for cost (`lua/plugins/lsp.lua`) — a stat
per open buffer is not a recursive FSEvents walk per workspace root.

What the throttle does *not* bound is the fan-out: a buffer that actually reloads
costs its consumers a re-lint and a git re-resolve, so a branch switch across many
open buffers is real work.

## 2. `<Space>lr` could not fix it, by construction

Commit `a6f5c36` replaced the keymap's stop-and-`:edit` with a stop-and-re-attach,
for two good reasons: `:edit` refuses a modified buffer with `E37` — after the
clients were already stopped, leaving the buffer with no server at all — and it
only ever re-attached the current buffer while the stop had detached every
sibling.

But the *re-read* `:edit` was also doing went with it. A restart then handed the
fresh server the same stale buffer through `didOpen`, and it republished
byte-identical diagnostics. `restart_clients` now re-reads each attached buffer
with `:checktime {buf}` first. That form is strictly better than the `:edit` it
replaces: it reaches buffers that are neither current nor in a window, it is a
no-op when the stat is unchanged, and on a buffer with unsaved edits it warns
instead of throwing.

The re-read runs *before* the clients are stopped. `get_clients` filters on
`initialized`, never on `_is_stopping`, so re-reading afterwards would hand a
dying client a fresh `didOpen` and schedule a `vim.diagnostic.show` for its
namespace — a flash of the stale diagnostics before `_on_detach` clears it.

## 3. Lint diagnostics had no reload path and no eraser

`nvim-lint` registers no autocommands of its own; this config gave it exactly one
trigger, `BufWritePost`. A reload fires `BufReadPre`, `BufReadPost`, `BufRead`,
`FileType` and `FileChangedShellPost` — **no** `BufWritePost` — so the linter
never re-ran.

Worse, a reload does not clear what is already painted: `vim.diagnostic`'s store
is dropped only on `BufWipeout`, and Neovim re-anchors the display extmarks. So
fixing defect 1 on its own would have made this look *worse*, not better — the
corrected text with the old ESLint sign sitting on an unrelated line.

`lua/plugins/nvim-lint.lua` now runs the same gated lint on `User FileReloaded`,
and resets the `eslint_d` namespace before the async pass and on both early
returns (the large-file guard and the toolchain gate), so a buffer that stops
qualifying drops its paint instead of keeping a lie.

Deliberately still not `BufReadPost`: that would lint every JS file the moment it
is opened, so every grep hit and definition jump would cost a daemon pass.

## 4. Git caches keyed on a signal a worktree write cannot move

`util.git.index_key` stats one thing: `<gitdir>/index`. Staging, committing,
checking out and resetting all rewrite it, which makes it a cheap and correct
gate for those. A bare working-tree write touches it not at all — so every cache
gated on it (`config.repo_status`, `config.submodule_status`) kept serving a
stale `git status` for the rest of the session.

The design named two escape hatches for exactly this window and both were broken:

- The "in-session filesystem watcher" the comments referred to **did not exist**.
  `submodule_status.invalidate(dir)` had no production caller at all.
- `<Space>gR`'s hard flush sat *below* an `api.tree.is_visible()` guard, and
  `quit_on_open = true` means the tree is closed for essentially all editing
  time — so pressing it from a normal buffer flushed nothing.

The flush now runs above the visibility guards (both calls are bare table
assignments; there was never a cost reason for them to be gated), and the dead
lever is wired: on `User FileReloaded` the buffer's own repo is resolved and only
that entry is dropped. Deliberately not a per-submodule `uv.new_fs_event` — 200
watcher handles is the storm the tiered design exists to avoid.

`config.ignore_filter` had the same shape of bug: its "watcher" was a
`BufWritePost` hook, so an externally changed `.gitignore` left tree visibility
wrong until something else cleared the memo.

## The events

One publisher, so consumers subscribe instead of guessing at reload edges:

| Event                 | Payload | Meaning                                   |
| --------------------- | ------- | ----------------------------------------- |
| `User FileReloaded`   | `{buf}` | that buffer's text just changed on disk   |
| `User FileRefreshForced` | —    | `<Space>r` was pressed; re-resolve everything |

`FileReloaded` is published from `FileChangedShellPost`, which fires only after a
reload actually happened — a conflict or a deletion stops at `FileChangedShell`.
It is emitted one tick later rather than inline: `:checktime` runs the reload as
an Ex command, and inside that try context a consumer that throws unwinds the
whole chain, skipping every consumer after it, with the error swallowed.

## What still needs `<Space>r`

The sweep can only fix state derived from buffers. It cannot see:

- a file **created or deleted** on disk, which changes `git status` without
  touching any open buffer;
- diagnostics a server published for a file **nothing has open** — with
  `didChangeWatchedFiles` off, the server is never told to re-check it;
- a terminal that does not forward focus events, where `FocusGained` never
  arrives.

`<Space>r` sweeps unconditionally, re-diffs gitsigns and fires
`FileRefreshForced`. `<Space>gR` remains the git-only version of the same thing.

## See also

- `lua/config/file_reload.lua` — the sweep, the conflict handler, the events.
- [nvim-tree-git.md](nvim-tree-git.md) — the tiered scanning model `index_key`
  belongs to.
- [lsp-fs-sync.md](lsp-fs-sync.md) — the sibling problem: file *operations* made
  from the tree, which the same watchers-off decision made invisible.
- [keybindings.md](keybindings.md) section 25.
