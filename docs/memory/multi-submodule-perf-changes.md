---
type: memory
title: "Multi-submodule perf changes"
kind: project
description: "Perf work for multi-submodule/polyglot repos — branch, the 13 changes, and the LSP-watcher behavior tradeoff."
---

# Multi-submodule perf changes

Branch `perf/multi-submodule` (created 2026-06-22, tests green, NOT yet committed/merged) reworks the config to stay fast in a superproject with many git submodules in different languages. 13 fixes across telescope, telescope_smart, gitsigns, lsp, nvim-tree, treesitter(-context), util/git, lsp_refs.

**Key behavioral tradeoff (non-obvious):** `lua/plugins/lsp.lua` now disables `workspace/didChangeWatchedFiles` (`dynamicRegistration=false`) for *every* server, because without `watchman`/`fswatch` Neovim falls back to a recursive libuv walk per submodule root. Consequence: LSP servers no longer auto-refresh on out-of-editor file changes (git checkout/rebase, codegen, npm install). Recover with `<leader>lr` (restart LSP on buffer) or `:edit`. If the user reports "LSP not seeing external changes," this is why.

**Other behavior changes to remember:** smart-picker git status + file listing are now async (`vim.system`) — pickers open instantly and git-status prefixes/tree labels stream in a frame later (driven by the `User SmartCodesRefreshed` event). Treesitter highlight/fold and treesitter-context skip files >5000 lines / >512KB. `git.root` is memoized per-dir (`util/git.lua`, clear via `_clear_root_cache`).

Related: [[nvim-refactor-stage-plan]].
