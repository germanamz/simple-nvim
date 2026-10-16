---
type: memory
title: "Nvim float winbar row trap"
kind: reference
description: "relative='win' floats render below the winbar (row=0 == first text row), but headless position APIs report frame-relative and \"prove\" the opposite."
---

# Nvim float winbar row trap

A `relative = "win"` float is composited below the target window's **winbar**, so
`row = 0` is the first *text* row. Never add a `+1` offset "to clear the winbar" —
that pushes the float one row too low and leaves a real buffer row visible above it.

**The trap:** headless probing argues confidently for the offset. Both
`nvim_win_get_position()` and `vim.fn.screenpos()` report a float's position
relative to the window **frame**, so comparing either against the window's text
area "proves" that `row = 0` sits on the winbar. It does not — that is a
reporting artifact of headless, not how the renderer composites. Screenshots from
the real UI are the authority; a headless probe cannot settle float placement.

Hit while building the nvim-tree sticky-folder header (`config.nvim_tree_context`,
which floats over a tree window whose winbar holds the `g? — all mappings` hint).
Cost two wrong turns: an unnecessary "fix" that introduced the bug, then a second
probe that confirmed the wrong model. The e2e spec now asserts the window
*config* (`row == 0`) rather than a rendered position, precisely because headless
cannot measure the rendered one.

Related: [[nvim-headless-window-height]], [[nvim-headless-no-insert-in-prompt]].
