---
type: memory
title: "Cmux browser from nvim"
kind: reference
description: "Neovim runs inside cmux (Ghostty-based); `cmux` CLI drives its built-in browser, so URLs can open in-app instead of the system browser."
---

# Cmux browser from nvim

The user runs Neovim inside **cmux** (`com.cmuxterm.app`),
a Ghostty-based terminal with a built-in WKWebView browser. The `cmux` CLI talks to
cmux's unix socket, authed by `CMUX_SOCKET_CAPABILITY` in the env.
Neovim inherits that env from its pane, so `vim.system({ "cmux", ... })` works with
no auth handling.

Verified contract (2026-08-12):

- `cmux --json --id-format both browser open <url>` → creates a split, returns JSON
  with `surface_id` (UUID), `surface_ref`, `pane_ref`. **`--focus` defaults to false.**
  **`--id-format both` (or `uuids`) is required** — output defaults to positional refs
  only, so plain `--json` carries `surface_ref` but NO `surface_id`. Global flags go
  before the subcommand.
- `cmux browser <surface> goto <url>` → re-navigates an existing surface. Enables one
  pinned docs pane instead of a new split per lookup.
- `cmux browser <surface> get url` → reads current URL.
- `cmux open <path-or-url>` → generic opener (HTML→browser split, markdown→preview tab).
- `cmux markdown open <path>` → a *rendered* markdown panel that live-reloads from
  disk. Backs `<leader>mp` (see `lua/config/markdown_preview.lua`). Three traps,
  each cost a probe cycle (2026-08-27): it **always splits a new pane** (no
  `--pane` flag, and no dedupe — the same path twice gives two panels);
  `new-surface --type markdown` silently degrades to a plain **terminal**; and
  `move-surface` **ignores `--focus false`** and steals focus every time, so
  tabbing panels into one pane needs a trailing `focus-pane`. Careful: with
  `--surface <anchor>` the response's `source_pane_id` is the *anchor's* pane,
  not the caller's — read the caller from `tree`'s `caller.pane_id` instead.
  Full write-up: `docs/superpowers/markdown-preview.md` in the nvim config.
- Failure (e.g. dead surface) → `Error: invalid_params: ...` on **exit 1**, so
  goto-then-reopen is a clean fallback. Beware: piping to `head` masks the real `$?`.

Gotchas:

1. `surface:N` refs are **not stable** — `tab new` shifted the focused surface from
   `surface:11` to `surface:12`. Persist the `surface_id` UUID from `--json`.
2. `tab new` **steals focus**; `browser open --focus false` does not.
3. Detect cmux via `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID`, **never `TERM_PROGRAM`** —
   cmux embeds Ghostty so `TERM_PROGRAM=ghostty`.
4. The browser is disableable (`cmux disable-browser` / `browser-status`), so any
   integration needs a `vim.ui.open` fallback.
5. The Claude sandbox blocks the unix socket (`Operation not permitted, errno 1`);
   run `cmux` probes with the sandbox disabled.

Discoverability: `cmux --help`, `cmux docs browser`, `cmux browser --help`,
`cmux identify --json --id-format both`. Browser skill doc:
`https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux-browser/SKILL.md`

Design consequence for [[docs/superpowers/refactoring]]: a single `open_url(url)` seam in
the nvim config (cmux-aware, falls back to `vim.ui.open`) serves `gx`, markdown
preview, and dependency-docs lookups alike.
