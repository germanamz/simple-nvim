---
type: memory
title: "Nvim-tree git perf tiered"
kind: project
description: "branch perf/nvim-tree-git — tiered submodule git-status for 200+ submodule superprojects; state-key cache kills the per-focus scan storm."
---

# Nvim-tree git perf tiered

Perf work (2026-07-17, branch `perf/nvim-tree-git`) making nvim-tree git status
scale to 200+ submodules / 20k+ files. Design in
`docs/nvim-tree-git-perf-design.md`. Five commits on top of `main`.

**Root cause:** the tree's per-file codes were eager over the *whole*
superproject (a `git status` per submodule, ~200 spawns) and re-ran on **every
FocusGained** — while the branch labels were already lazy/visible-only. That
per-focus 200-spawn storm was the pain.

**Shipped architecture (tiered):**
- **`util.git.index_key(dir)`** — spawn-free change key = git index mtime (moves
  on stage/commit/checkout, NOT on a bare unstaged edit — the documented gap).
  Resolves a submodule's real gitdir via its `.git` file.
- **P1** `config.repo_status` caches `index_key` beside each status; `revalidate()`
  drops only entries whose index moved. `nvim_tree_git.refresh_labels({hard=?})`:
  FocusGained = soft revalidate; HeadChanged/ReviewBaseChanged/`<leader>gR` = hard.
- **P2** new `config.submodule_status`: per-submodule status cache keyed by
  index_key, shared single-flight behind the pickers' `scan()` (silent, bulk) and
  the tree's `request()` (fires `SubmoduleStatusChanged`).
  `telescope_smart.recursive_changes_async` delegates to it → whole-tree scan is
  cold-once, incremental after. **Freshness fix:** recursion calls
  `submodule_status.revalidate()` each run or it serves stale codes.
- **P3 (Tier 0)** outer status → `--ignore-submodules=dirty`;
  `apply_worktree_lines` classifies gitlink rows (path ∈ submodule set) into a
  `dirty_subs` set (not codes/counts); threads via the codes cache 5th return to
  the tree, where `_dir_markers(codes, dirty_subs)` rolls a **bumped
  (commit-diverged) submodule** up through ancestors — a marker the recursion
  can't produce (clean worktree = no files). Watch the trailing-slash trap:
  `path_util.relative` :p-appends `/` for dirs; strip before keying dirty_subs.

**Key finding — no aggressive laziness:** full working-tree rollups *require*
scanning every submodule (git has no cheaper path), so the cached incremental
scan IS the optimum; skipping collapsed submodules would break the user's
"full rollups" requirement. Related: [[smart-files-submodule-perf-2026-07]],
[[nvim-tree-workspace-branch-status]], [[nvim-tree-decorator-gotchas]].

Tests: 519 unit / 70 smoke / 74 e2e all green. Not yet merged to main.
