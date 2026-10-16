---
type: memory
title: "Lsp stale on tree delete/rename"
kind: project
description: "Root cause of \"LSP goes crazy\" on nvim-tree delete/package-rename — watchers off starves gopls; SHIPPED as config/lsp_fs_sync.lua, documented in docs/lsp-fs-sync.md"
---

# Lsp stale on tree delete/rename

Confirmed 2026-07-25: nvim-tree delete/rename → gopls error storms because
lsp.lua disables didChangeWatchedFiles globally (see [[multi-submodule-perf-changes]])
and gopls has no rename/delete fileOperations (didCreate only) — so nothing
ever tells it about in-editor fs changes; snapshot stays stale until restart.
ts_ls self-heals deletes via tsserver's native watcher; its willRename works
but leaves hidden dirty buffers on folder rename. Validated heal: manually
`client:notify("workspace/didChangeWatchedFiles", {changes={{uri=..., type=3}}})`
— gopls processes it unconditionally, no registration needed.

Fix IMPLEMENTED 2026-07-25: config/lsp_fs_sync.lua replaces the
nvim-lsp-file-operations plugin (spec + lock entry removed) — full analysis,
design, and review hardening (failed-rename recovery, cross-root moves,
:Lazy-reload-safe registration) in repo docs/lsp-fs-sync.md. Unit spec
gotcha: specs share one nvim, so buffer names must be unique per test (E95)
and scheduled callbacks must be drained in after_each or they leak.

**Why:** the perf tradeoff note "no auto-refresh; use <leader>lr" hid that
in-editor tree operations were also unreported.

**How to apply:** when touching lsp.lua watcher settings, nvim-tree fs
actions, or anything LSP-staleness-shaped, read docs/lsp-fs-sync.md first.
Repro gotcha: Go tooling ignores `_`-prefixed dirs — never name a scratch Go
package dir `__foo` or gopls will skip it entirely.
