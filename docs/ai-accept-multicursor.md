# AI accept with multiple cursors

Reported symptom: *"when I have multiple cursors and accept the AI suggestion it
only appears on the cursor making the changes even after I press esc."*

Reproduced with three cursors on three `ret` lines, `A`, `u`, `<Tab>`, `<Esc>`:

```
{ "retu", "retu", "return a - b" }
```

The typed `u` reached every cursor. The accepted suggestion reached one.

Line numbers below are the pinned commits:
`~/.local/share/nvim/lazy/minuet-ai.nvim/lua/minuet/virtualtext.lua` at `d29dec4`,
and `~/.local/share/nvim/lazy/multicursor.nvim/lua/multicursor-nvim/` on branch
`1.0`.

## Why

**multicursor does not re-apply an edit at the other cursors — it replays one.**
`_handleExitInsertMode` (`input-manager.lua:174-200`) runs once per cursor and
picks between two sources:

```lua
if cursor:mode() == "n" then
    feedkeysManager.nvim_feedkeys(".", "nx", false)   -- :188  dot-repeat
else
    feedkeysManager.nvim_feedkeys(self._typed, "", false)
    feedkeysManager.nvim_feedkeys(reg, "nx", false)   -- :193  getreg(".")
end
```

Every cursor this config's keymaps produce takes the **first** branch. `<C-n>`,
`<S-Down>` and `<leader>ca…` all add cursors from normal mode; clones copy the
main cursor's mode verbatim (`cursor-manager.lua:1314`) and every action ends by
normalising each enabled cursor to it (`:2295-2303`). The `getreg(".")` branch
needs a cursor still holding a *selection* at insert exit, which none of these
have. So the operative source is the **redo record**, not the `.` register.

**minuet's accept never writes the redo record.** `action.accept`
(`virtualtext.lua:348-402`) inserts the suggestion with

```lua
api.nvim_buf_set_text(0, line, col, line, col, suggestions)   -- :393
```

inside a `vim.schedule`. An API buffer edit bypasses Vim's insert recording
entirely: it lands in neither the redo record nor the `.` register. There is
simply nothing for the other cursors to replay, which is why `<Esc>` changes
nothing — the replay runs, and replays the typed characters only.

This is the same failure class as the `mini.pairs` problem already handled in
`lua/plugins/multicursor.lua`, and as multicursor's own `SnippetManager`, which
exists because `vim.snippet.expand` inserts by API too.

## The fix

`lua/config/minuet_multicursor.lua` wraps `action.accept`. While two or more
cursors are enabled, it lets minuet run its entire accept unmodified, then
re-expresses that one insertion as `nvim_paste` — the one insertion primitive
that writes the redo record. The buffer and the cursor end up byte-identical;
what changes is that `.` can now reproduce the suggestion, so multicursor's
existing machinery carries it everywhere with no multicursor internals touched.

With three cursors, the same keystrokes now give:

```
{ "return a - b", "return a - b", "return a - b" }
```

### Why it reads the text back instead of asking minuet for it

There is no instant at which a wrapper can read the suggestion. `accept` resets
`ctx` (`:375-377`) and clears the ghost-text extmark (`:379`) **synchronously**,
before its own deferred edit — so after `accept()` returns, the text is gone from
minuet and not yet in the buffer. `snapshot()`/`measure()` therefore recover it
from the buffer delta: line-count change plus a tail-length pin, gated on the
changedtick having moved exactly once.

Reading the delta rather than intercepting a particular API call also means
`<C-l>` (`accept_line`, which is `action.accept(1)` at `:425-427`) is covered for
free, and that the most plausible upstream restructure — swapping
`nvim_buf_set_text` for `nvim_buf_set_lines` — leaves this working.

### Insert mode only, and strictly

`nvim_paste` is equivalent to `nvim_buf_set_text` **in insert mode and in no
other mode**, because `vim.paste` dispatches on mode. Measured on the same buffer
and cursor, inserting `ZZZ` at column 5 of `HELLOWORLD`:

| mode | `nvim_buf_set_text` | `nvim_paste` |
| --- | --- | --- |
| insert | `HELLOZZZWORLD` | `HELLOZZZWORLD` |
| replace | `HELLOZZZWORLD` | `HELLOZZZLD` (overwrites) |
| normal | `HELLOZZZWORLD` | `HELLOWZZZORLD` (one column right) |

Replace mode is genuinely reachable: minuet's own gate is `^[iR]`
(`virtualtext.lua:129`), and pressing `<Insert>` mid-suggestion fires no
`CursorMovedI`, so the ghost text survives. The guard is therefore
`mode() == "i"` exactly, never a `^[iR]` family match. In Replace mode the
rewrite declines and the accept stays exactly as upstream left it — the
suggestion lands at the main cursor only, which is the old behaviour rather than
a corrupted buffer. Verified by probe.

### What it refuses

Every refusal falls back to upstream's behaviour: the suggestion at the main
cursor, no replication, nothing corrupted.

- Mode is not plain insert (Replace, or `<Esc>` already drained from typeahead
  before the deferred edit ran).
- The changedtick moved by anything other than exactly one step — a second edit
  landing in the same window would otherwise be folded into the recovered text
  and pasted twice.
- The buffer or window changed under the accept, or the text after the cursor no
  longer matches the snapshot.
- `vim.paste` is overridden by something that inserts nothing. The rewrite
  deletes minuet's copy *before* pasting and compares the changedtick after, so a
  no-op paste is repaired by re-inserting the text it still holds. The ordering
  is deliberate: the opposite order fails by leaving the suggestion in the buffer
  twice, which is silent corruption.

## Coupling

`install()` wraps `minuet.virtualtext.action.accept`, an internal upstream offers
no stability contract for — the same posture, and the same debt, as
`lua/config/minuet_guard.lua`. A rename disables the fix rather than erroring, so
`install()` returns false and `lua/plugins/minuet.lua` surfaces a warning.

Two behaviours are observed rather than documented: that `vim.schedule` callbacks
run FIFO (so the rewrite sees minuet's completed edit), and that nothing else
edits the buffer in between. Both are policed by the changedtick arithmetic, so
either one breaking degrades to the old behaviour rather than to a wrong buffer.

`virtualtext.keymap.accept` must stay `nil`. `set_keymaps` captures
`action.accept` **by value** at `:558`, so a key bound there would bypass the
wrapper and reproduce the original bug while `<Tab>` kept working. `<Tab>`
(`lua/plugins/completion.lua`) and `<C-l>` both resolve it at press time and are
covered; `tests/spec/smoke/multicursor_spec.lua` pins that it stays unbound.

## Verifying it by hand

Headless Neovim cannot enter insert mode through typeahead, so the end-to-end
proof is a PTY probe: real config, real multicursor, real accept path, with only
the FIM backend's `complete` stubbed to answer instantly. The committed specs pin
the pieces — `tests/spec/unit/minuet_multicursor_spec.lua` drives genuine insert
mode via an insert-mode Lua keymap fed with `nvim_feedkeys(keys, "mx")`, which is
the one way a headless spec gets `mode() == "i"`.

Probed and confirmed: three `<C-n>` cursors and three `<S-Down>` cursors,
single-line and multi-line suggestions, `<Tab>` and `<C-l>`, and the Replace-mode
refusal.

## Not fixed by this

`nvim-ts-autotag` inserts its `>` with `nvim_buf_set_text` too
(`internal.lua:473-483`), so typing a tag in `tsx`/`jsx`/`html` under multiple
cursors has the same root cause. A general fix belongs in multicursor, not here;
this one is scoped to the AI path that was reported.
