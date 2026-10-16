---
type: memory
title: "Nvim pty probe for blink"
kind: project
description: "To verify blink.cmp menus / snippet expansion for real (insert mode is headless-hostile), spawn a TUI nvim in a Python pty with --listen and query it via --remote-expr; a background thread MUST keep draining the pty or nvim blocks on stdout and --remote-expr deadlocks."
---

# Nvim pty probe for blink

Interactive verification recipe (used 2026-08-17 for the OpenFGA blink source):
`pty.fork()` → `nvim --listen <sock> file.fga` with `TERM=xterm-256color`; write
keys to the pty fd (`o`, text, `\x1b`, `\t`); read state with
`nvim --server <sock> --remote-expr 'luaeval(...)'` — e.g.
`require('blink.cmp').is_visible()`, `require('blink.cmp.completion.list').items`
labels, `vim.snippet.active()`, buffer lines. Script lives in the session
scratchpad as `pty_probe.py` (rewrite as needed).

**Why:** the plenary harness cannot enter insert mode ([[nvim-headless-no-insert-in-prompt]]),
so real menu behaviour (per_filetype source resolution, trigger chars,
mini.pairs interaction, Tab → snippet expand) is only observable in a real TUI.

**How to apply:** start a daemon thread that `select`+`os.read`s the pty
forever BEFORE any `--remote-expr` — without it the pty buffer fills, nvim's UI
thread blocks on write, and every RPC hangs (first attempt hung 120s+). Sandbox
must be off (nvim writes cache/shada). Findings from that probe: mini.pairs
auto-closing `[` means a `[` trigger char does NOT reopen blink's menu (the
`]` insert hides it, the `<Left>` cursor move never re-shows) — type a letter
or `<C-space>`; `#` as a trigger char works fine.
