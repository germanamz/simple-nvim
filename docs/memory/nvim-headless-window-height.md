---
type: memory
title: "Nvim headless window height"
kind: project
description: "headless e2e windows are ~43 rows tall, so scroll-dependent specs must shrink vim.o.lines or the topline silently clamps."
---

# Nvim headless window height

In the headless plenary harness the nvim "screen" is much taller than a normal
terminal — an nvim-tree sidebar window measures ~43 rows, not ~23. A spec that
needs the window to actually scroll (e.g. driving a buffer line above `w0`) will
have its `winrestview({topline = N})` silently clamped back, because Neovim will
not scroll past the last buffer line.

Two ways out, both used in `tests/spec/e2e/nvim_tree_context_spec.lua`:
set `vim.o.lines` to a small value in `before_each` (restore it in `after_each`),
and/or size the fixture so the buffer is comfortably taller than the window.
Assert the achieved topline as an explicit precondition — a clamped topline
otherwise shows up as a confusing assertion failure much further down.

Related headless constraints: [[nvim-headless-no-insert-in-prompt]],
[[nvim-headless-mini-operator-hang]], [[nvim-e2e-single-file-needs-minimal-init]].
