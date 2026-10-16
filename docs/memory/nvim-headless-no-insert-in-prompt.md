---
type: memory
title: "Nvim headless can't insert in prompt"
kind: project
description: "headless nvim can't enter insert mode in a buftype=prompt (telescope) window, and CursorMoved never fires in a script context — BUT an insert-mode Lua keymap fed with feedkeys 'mx' DOES run its callback with mode()=='i', which makes insert-only behaviour unit-testable."
---

# Nvim headless can't insert in prompt

In the plenary e2e harness (headless nvim, no UI attached), you cannot enter
insert mode in a `buftype=prompt` window such as the Telescope prompt. `i`/`a`
via `nvim_feedkeys`/`nvim_input` and even `vim.cmd("startinsert")` are all
no-ops — `nvim_get_mode().mode` stays `"n"`. Separately, `nvim_feedkeys` with
the `x` flag behaves like `:normal` and terminates any pending insert mode the
moment the typeahead empties.

**Why:** prompt-buffer insert handling is tied to the UI/prompt callback, which
isn't present headless; the test `press()` helper uses `"mx"`.

Worse (2026-07): in a **normal buffer**, `nvim_feedkeys("i", "x!", false)`
kills the PlenaryBustedDirectory child outright — the run dies silently right
after "Testing:" with no results printed. Interactive insert-mode entry is
generally headless-hostile, not just in prompt buffers.

More event-loop gotchas in the busted child (2026-07, from the snippet-session
work): `vim.wait` pumps vim.schedule'd callbacks but NEVER drains feedkeys
typeahead (interactive nvim drains typeahead before deferred events — the
harness inverts the order, manufacturing races that don't exist live; drain
manually with `feedkeys("", "x")` inside the wait predicate). `SafeState`
never fires during a spec body, so SafeState-based designs are untestable
there. `vim.fn.getchar(1)` inside a scheduled callback hangs the child.

**BUT there IS one way in (2026-09-01, from the multicursor/AI-accept work).**
An insert-mode **Lua keymap** whose trigger is fed with
`nvim_feedkeys(nvim_replace_termcodes("i<F13><Esc>", ...), "mx", false)` runs its
callback with `vim.fn.mode() == "i"` — genuinely, in the busted child. So
insert-mode-only behaviour IS unit-testable: put the code under test inside the
mapping. `vim.wait(ms, function() return false end, 10)` **inside that callback**
also pumps `vim.schedule`d callbacks while the mode is still `"i"`, which is how
you test a deferred insert-mode edit (minuet's accept defers one tick). The trap:
the `x` flag has already left insert by the time `nvim_feedkeys` RETURNS, so
draining outside the mapping silently tests the wrong mode — that read as a
product bug for one round. This is how
`tests/spec/unit/minuet_multicursor_spec.lua` pins `nvim_paste`'s
insert-vs-Replace-vs-normal divergence. See [[minuet-multicursor-accept]].

Cursor-driven events are unreachable too (2026-07, from the nvim-tree
full_name float work): in a headless **script** context (`-c "luafile ..."`,
and the busted child), `CursorMoved` NEVER fires — not for the plugin's
autocmds and not for a counter autocmd you register yourself, so a zero count
does not mean the feature is broken. Neither driver moves the cursor at all:
`feedkeys("j","x")` leaves `CursorMoved` unfired, and `nvim_input("2G")` leaves
the cursor sitting on row 1 with the keys unconsumed (the main loop that drains
input never runs there; `vim.wait` does not drain it either — same inversion as
above). Drive such features with `nvim_exec_autocmds("CursorMoved", {pattern =
...})` — for buffer-name-patterned autocmds like nvim-tree's `NvimTree_*`, pass
`pattern`, not `buffer`. To verify the real keypress→event link, spawn nvim in
a **PTY** (`pty.fork`) with `--listen <sock>` and drive it via `nvim --server
<sock> --remote-send 'j'` + `--remote-expr` to inspect state; that runs a real
main loop and does fire `CursorMoved`. Two harness traps that read as feature
bugs: `nvim .` hijacks the directory buffer into a FULL-WIDTH tree (no
truncation, so no float is correct — use `:NvimTreeFindFileToggle` for the real
35-col sidebar), and `gg` lands on the root row whose label is the whole path
and is itself usually truncated.

**How to apply:** design tests to avoid entering insert mode at all. E.g.
`vim.snippet.expand()` works from normal mode and its select_tabstop keys drive
the same select-mode session a completion accept does (see
tests/spec/e2e/snippet_session_spec.lua). To test insert-mode picker behavior, assert the resolved
buffer keymap (`vim.api.nvim_buf_get_keymap(buf, "i")`) rather than the live
mode. Telescope tags built-in actions with a `desc` like `telescope|close`;
custom mappings are plain Lua callbacks (`m.callback` is a function, `desc`
points at the source file). Normal-mode behavior (open mode, `<Esc>` to close)
drives fine. See tests/spec/e2e/telescope_spec.lua. Related:
[[nvim-tests-need-sandbox-disabled]], [[nvim-e2e-single-file-needs-minimal-init]].
