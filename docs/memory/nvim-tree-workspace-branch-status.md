---
type: memory
title: "Nvim-tree workspace branch status"
kind: project
description: "nvim-tree shows superproject + per-submodule branch/status in a workspace: config.repo_status (async resolver + RepoStatusChanged event) + config.nvim_tree_submodule (after-decorator); submodules resolve only when visible."
---

# Nvim-tree workspace branch status

Workspace branch/status in nvim-tree (design: `docs/nvim-tree-branch-status-design.md`).
Shows the superproject's branch + working state on the root_folder_label line
(monochrome — see [[nvim-tree-decorator-gotchas]] rule 4) and each submodule's
OWN branch/dirty/ahead-behind/detached label after its folder name (coloured,
`icon_placement = "after"`).

Modules:
- **`lua/config/repo_status.lua`** — nvim-tree-free async resolver + per-dir cache
  + formatter. `get`/`request`/`invalidate_all`, pure `parse`/`segments`/`plain`.
  One `git status --porcelain=v2 --branch --ignore-submodules=all` per repo (uniform
  for root AND submodules), plus `git describe --tags --always` only on detached
  HEAD. Fires `User RepoStatusChanged {dir}` on a successful resolve (mirrors
  [[multi-submodule-perf-changes]]'s HeadChanged/ReviewBaseChanged event shape).
- **`lua/config/nvim_tree_submodule.lua`** — the "after" decorator. `_subs_for(cwd)`
  discovers the submodule set via `telescope_smart._submodule_paths_async` (cheap
  .gitmodules parse; set keyed by the enumerator's OWN paths to dodge the
  /var↔/private/var symlink trap), fires RepoStatusChanged when ready. `:icons`
  resolves a submodule's status ONLY when its row is visible (decorators run on
  visible nodes) — user's explicit perf constraint for 200-submodule repos.
- Wiring: `nvim-tree.lua` sets `root_folder_label` + appends the decorator;
  `nvim_tree_git.refresh_labels` calls `repo_status.invalidate_all()` and its
  `register_autocmds` adds the RepoStatusChanged→reload subscriber (repaint on
  FocusGained/<leader>gR, consistent with the rest of the git liveness).

Dirty+count for submodules ALSO available free from the recursive codes cache
(prefix-filter), but the impl uses the uniform resolver instead (A1). Deferred
(out of scope): per-submodule review base (bX), instant submodule repaint via
per-visible-submodule HEAD watchers (B2 — git_head watchers are buffer-driven).

Tests: `tests/spec/unit/repo_status_spec.lua`, `.../nvim_tree_submodule_spec.lua`,
`.../nvim_tree_git_spec.lua`; e2e `tests/spec/e2e/nvim_tree_branch_status_spec.lua`.
See [[spec-docs-in-repo-not-scratchpad]], [[nvim-tests-need-sandbox-disabled]].
