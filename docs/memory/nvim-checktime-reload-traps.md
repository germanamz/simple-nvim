---
type: memory
title: "Nvim checktime/reload traps"
kind: project
description: "autoread needs a check that nothing runs; bare :checktime skips hidden buffers; FileChangedShell is suppressed under autocmd_busy; :checktime's Ex try context unwinds User consumers."
---

# Nvim checktime/reload traps

Four traps found fixing the 2026-09-05 "stale git/lsp/lint indicators after an
external edit" bug (shipped as `lua/config/file_reload.lua`, documented in
`docs/external-changes.md`).

1. **`'autoread'` is a policy, not a trigger.** It is on by Neovim default but
   only acts once a timestamp *check* runs, and Neovim runs one only on real
   terminal focus-gain, on entering a buffer that is in a window, and after a
   real `:!cmd`. A config that shells out via `vim.system`/`systemlist` never
   gets the third. "No autoread in the config" is a red herring — the missing
   piece is the check.

2. **A bare `:checktime` only visits buffers with a window**, despite
   `doc/editing.txt` saying "each loaded buffer is checked". The per-bufnr form
   `:checktime {bufnr}` does reach a loaded-but-hidden buffer. The stale buffers
   are always the hidden ones, so the usual `au FocusGained * checktime` recipe
   fixes only what is on screen.

3. **`FileChangedShell` does not fire on the happy path, and is suppressed
   inside autocmds.** For an unmodified buffer, `'autoread'` reloads silently and
   the event never fires at all. It fires only for `conflict` / `deleted` — and
   *not even then* when called from inside an autocmd, because `autocmd_busy`
   suppresses the decision half of the check. Fix: `vim.schedule()` the sweep one
   tick off the autocmd stack. **Headless does not reproduce this** (it fires the
   event on every sweep), so only a PTY probe shows it.

4. **`vim.cmd("checktime " .. buf)` runs in an Ex try context.** A Lua error in
   any `User` autocmd fired from inside that reload becomes an exception that
   unwinds the whole chain — every consumer registered after the thrower is
   skipped — and a surrounding `pcall` then swallows it, leaving no message
   anywhere. Fix: `vim.schedule()` the `nvim_exec_autocmds` too; off the Ex stack
   the normal rules apply (error reported, remaining consumers still run).

Also: a checktime reload fires `BufReadPre`/`BufReadPost`/`BufRead`/`FileType`/
`FileChangedShellPost` and `on_reload`, but **never `BufWritePost`** (so
BufWritePost-only linters go stale) and **never `BufEnter`** (so a sweep cannot
recurse). `vim.lsp`'s `on_reload` sends didClose+didOpen, so LSP resync is free
once the buffer actually reloads. Cost is ~18us/buffer, no spawn.

Related: [[nvim-headless-no-insert-in-prompt]], [[nvim-pty-probe-key-timing]],
[[nvim-virtual-lines-and-headless-lies]], [[docs/nvim-tree-git]].
