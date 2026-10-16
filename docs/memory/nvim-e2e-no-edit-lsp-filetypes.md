---
type: memory
title: "Nvim e2e: don't :edit LSP filetypes"
kind: project
description: "In e2e specs, don't :edit files with LSP filetypes (.lua) — the shared headless session caches the LSP log path from the FIRST isolated env, so later envs error mid-autocmd and contaminate following specs."
---

# Nvim e2e: don't :edit LSP filetypes

In the nvim config's e2e harness (tests/full_init.lua, one shared headless
child per spec file), `vim.cmd.edit("a.lua")` in a spec that runs after the
first `nvim_env.setup_isolated_env()` fails: the FileType→LSP chain tries to
open `$XDG_STATE_HOME/nvim/lsp.log` using a path cached from the FIRST
isolated env (already torn down), erroring mid-BufReadPost. The error also
leaks into the NEXT spec in the same file (observed 2026-07-13: a failing
`<leader>fb` test made the unrelated `<leader>gB` test time out).

**Why:** vim.lsp.log resolves its log path once per session; isolated envs
swap XDG dirs per test but the session is shared.

**How to apply:** when a spec just needs a listed named buffer, create it via
`vim.api.nvim_create_buf(true, false)` + `nvim_buf_set_name()` (no autocmds
fire) instead of editing a real file; if a real edit is unavoidable, use a
non-LSP filetype (.txt).

**The flip side (2026-09-15):** an API-built buffer never attaches a REAL
server — the LSP plugin lazy-loads on BufReadPre, which only a real read
fires, so `vim.lsp.enable` is never installed and the spec times out on
"never attached". For e2e-lsp specs that need a real server, use
`vim.fn.bufadd(path)` + `vim.fn.bufload(buf)` + set filetype, and keep ALL
servers inside ONE `it` (one isolated env per headless child). For a FAKE
in-process server (`vim.lsp.start` with a function `cmd`), set the filetype
with `:noautocmd setlocal filetype=cpp` — `/usr/bin/clangd` is on the macOS
PATH and a FileType event starts it beside the fake.

Related: [[nvim-headless-no-insert-in-prompt]],
[[nvim-e2e-single-file-needs-minimal-init]], [[docs/hover-docs]].
