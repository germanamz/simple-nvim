---
type: memory
title: "Nvim-tree ignore filter"
kind: project
description: "nvim-tree builtin git is OFF; ignore-hiding is config.ignore_filter (static set + async check-ignore oracle). Disabling builtin git exposed a latent SmartCodesRefreshed cwd-mismatch bug."
---

# Nvim-tree ignore filter

To fix `[NvimTree] git jobs timed out ... disabling git integration` in a
superproject with well over a hundred submodules, nvim-tree's builtin git was turned OFF
(`git.enable = false`, `filters.git_ignored = false`). Builtin git spawned one
synchronous `git status --ignored` per submodule and tripped a module-level,
never-reset 5-timeout kill switch (`runner.lua` `timeouts`/`MAX_TIMEOUTS`) that
permanently disabled git — and with it the ignore filter.

Replacement: `lua/config/ignore_filter.lua`, wired as `filters.custom` (a
function `(abs)->bool`, true=hide; evaluated synchronously per node in
nvim-tree's `explorer/filters.lua`). Two layers feed one O(1) lookup: a STATIC
basename set of never-tracked heavy dirs (node_modules/.venv/__pycache__/...)
hidden instantly, and a lazy async `git --no-optional-locks -C <top> check-ignore
-z --stdin` ORACLE (true gitignore fidelity, index-aware). Since the 2026-07-04
quality pass, drain() is TWO-STAGE async: roots resolve off-thread through
`util.pool.run` (the generic bounded pool extracted from telescope_smart; both
stages guard on `_ignored ~= cache` table identity so a mid-flight `_clear()`
drops stale verdicts AND skips the `git._prime_root` memo prime). Cache cleared
by `config.dir_cache` (submodule topology) + a `.gitignore`/`exclude`
BufWritePost in `ignore_filter.setup()` (armed in `init.lua`). `--no-optional-locks`
matters: check-ignore runs concurrently with the decorator's status/diff in the
SAME repo and would otherwise contend on `.git/index.lock` (telescope_smart
serializes its own status+diff for this reason).

**Non-obvious gotcha (cost ~hours to find):** disabling builtin git made the
`nvim_tree_git` decorator labels (M*, bM, ?*) flaky in the e2e suite. Root cause
was a LATENT pre-existing bug: the `SmartCodesRefreshed` autocmd in
`plugins/nvim-tree.lua` compared `args.data.cwd` (which the decorator fires as
`fnamemodify(getcwd, ":p")` — TRAILING SLASH) against `vim.fn.getcwd()` (no
slash), so `==` never matched and the repaint was always skipped. It went
unnoticed because builtin git's own `renderer:draw()` calls supplied redundant
repaints. Lesson: the custom decorator implicitly depended on builtin git's free
redraws. The `same_dir()` normalize only patched the symptom: the 2026-07-04
review found the ROOT CAUSE was `nvim_tree_git` Decorator:new keying the shared
codes cache with `fnamemodify(getcwd, ":p")` (trailing slash) while every other
caller keys plain `getcwd()` — the key ping-pong blanked labels and double-ran
the recursive scan on every repaint. Fixed: `self.cwd = vim.fn.getcwd()`;
`same_dir()` kept as symlink defense.

See [[multi-submodule-perf-changes]], [[multi-submodule-plan]],
[[nvim-tests-need-sandbox-disabled]].
