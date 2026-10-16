---
type: memory
title: "Gitsigns base is the blame revision"
kind: project
description: "gitsigns' base is also the `git blame <revision>` arg, so a global base leaks wrong blame authors across roots; fixed 2026-07-31 with per-buffer bases in config.gitsigns_base."
---

# Gitsigns base is the blame revision

gitsigns' base (`config.base`) is not only a diff base — `attach.lua` passes it
straight into `git blame <revision>` (`cache.lua` → `git/blame.lua`). So a base
belonging to one repo root, pushed globally via `change_base(ref, true)`, made
every OTHER root's buffers blame against a ref resolved in their own repo. In a
submodule checked out behind its branch tip, `origin/main` contains the squash or
merge commit, so the current-line blame named the latest committer instead of the
line's real author. Diagnosed and fixed 2026-07-31.

**Why:** the old comment in `lua/plugins/gitsigns.lua` claimed per-repo bases were
impossible ("inherently limited by that single global base"). They are not:
`change_base(ref, false)` targets the CURRENT buffer, so
`nvim_buf_call(bufnr, ...)` aims it at any buffer and leaves `config.base` unset.
Verified: the aimed buffer takes the ref, siblings keep theirs, global stays nil.

A second, independent mechanism produced the same "wrong blame" symptom inside a
based root: `CacheEntry:get_blame` short-circuits any line that falls in a hunk
to "Not Committed Yet" WITHOUT running blame — and against a review base, every
line committed on your branch is a hunk. Dropping only the blame revision does
not fix that; both must be patched. `lua/config/gitsigns_blame.lua` does both.

**How to apply:** `lua/config/gitsigns_base.lua` owns the per-buffer base —
`apply(bufnr)` at attach, `rebase_root(root, ref)` on ReviewBaseChanged. Two
traps: on_attach runs BEFORE gitsigns registers the buffer's cache entry (so the
base must land on a later tick — hence the poll), and only
`gitsigns.cache.cache[buf]` tells you a buffer is fully attached
(`b:gitsigns_status` is set earlier). `config.gitsigns_blame` patches blame,
scoped by the `git_obj._review_base` tag so `gitsigns://` historical buffers keep
blaming from their own revision. Regression fixtures:
`git_fixture.superproject_pinned_submodule` and the feature-branch case in
`tests/spec/e2e/gitsigns_spec.lua`. Related: [[multi-submodule-plan]].
