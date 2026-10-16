---
type: memory
title: "Tempname vs getcwd symlink"
kind: project
description: "In specs, tempname() paths go through /tmp (symlink) but getcwd() after chdir is /private/tmp — util.path.relative then returns an absolute path and cwd-relative predicates silently fail open."
---

# Tempname vs getcwd symlink

`vim.fn.tempname()` with a `/tmp`-based `$TMPDIR` yields `/tmp/...`, but after
`vim.fn.chdir(that)` `vim.fn.getcwd()` returns the resolved `/private/tmp/...`.
`util.path.relative(abs, getcwd())` only strips a literal prefix, so an `abs`
built from the tempname comes back absolute ("outside the cwd"). Any predicate
that fails open for outside-cwd paths (e.g. `config.nvim_tree_changed.hides`)
then passes "keep" tests and fails every "hide" test with no error.

**Why:** cost a red-herring debug round on 2026-10-08 while TDD-ing the tree's
changed-only filter (C).

**How to apply:** in unit specs, build absolute paths from `vim.fn.getcwd()`
after the chdir (the form nvim-tree itself builds node paths from), not from the
fixture/tempname path. Same family as the /var↔/private/var trap in
[[nvim-tree-workspace-branch-status]].
