---
type: memory
title: "Multicursor autopairs conflict"
kind: project
description: "multicursor.nvim replays an insert at non-main cursors from getreg('.'); mini.pairs' expr auto-pair plus a <CR> inside the pair truncates that register, so brackets vanish at every cursor but the main one — fixed by mapping the openers to themselves inside mc.addKeymapLayer."
---

# Multicursor autopairs conflict

Found 2026-08-18 while adding multicursor.nvim (`lua/plugins/multicursor.lua`,
branch `feat/multicursor`).

**Mechanism:** on insert-exit, `input-manager.lua:_handleExitInsertMode` feeds
`vim.fn.getreg(".")` to every non-main cursor. Anything a plugin inserts by a
route that does not land in the `.` register replays wrong or not at all. This
is the same class of bug as upstream issue #109, whose culprit was
`nvim-ts-autotag` ("does not support dot repeat") — this config has that plugin
too, ft-gated to html/js/ts/react/gohtmltmpl, so expect the same failure there.

**Bisect result (mini.pairs, via pty probe):** `A{` alone replays fine at all
cursors; `A` `{` `<CR>` `return` does NOT — the braces vanish and the text
lands at the wrong column. Plain multi-line insert (`A` `x` `<CR>` `y`) is
fine. So it is specifically auto-pair + newline inside the pair, not
auto-pairs generally and not multi-line replay generally.

**How to apply:** neutralise the openers only while cursors are alive, inside
`mc.addKeymapLayer` — `layerSet("i", opener, opener, ...)` for
`( [ { " ' \``. The layer's mappings are buffer-local and deleted on collapse
(`keymap-manager.lua`), so single-cursor auto-pairing is untouched.

Do NOT re-diagnose `$` as broken: a pty probe that writes `$ax` in one chunk
makes the motion look like it skips the other cursors. That is a probe
artifact — see [[nvim-pty-probe-key-timing]].
