---
type: memory
title: "Virt_lines traps + two more headless lies"
kind: reference
description: "virt_lines traps (silent no-render on folds and when ephemeral) plus two more headless-only lies: float compositing at the origin, and state() reporting 'oS' with no UI."
---

# Virt_lines traps + two more headless lies

Five findings from building `config.long_line_peek`, all of which fail **silently** —
no error, the API accepts everything, the screen is just wrong.

**`virt_lines` never render on a line inside a closed fold.** The extmark is
accepted and `nvim_buf_get_extmarks` returns it; nothing draws. Any feature that
reserves space with `virt_lines` must bail on `vim.fn.foldclosed(lnum) ~= -1`, or
whatever it drew over that reserved space covers real code instead.

**Ephemeral `virt_lines` never render at all.** Set from a decoration provider's
`on_win`/`on_line` with `ephemeral = true`, they draw nothing and raise nothing —
`kDecorKindVirtLines` is write-only dead state, and all virtual-line work goes
through `decor_virt_lines()`, which scans the marktree and short-circuits on a
counter ephemeral marks never increment. (Same shape as the known ephemeral
inline-virt_text bug.) Persistent marks set from `on_win` do work. Sibling of the
already-recorded `line_hl_group` ephemeral trap — see
[[nvim-ephemeral-extmark-no-line-hl]].

**`virt_lines` below the cursor line are clipped at the window bottom and Neovim
will not scroll to reveal them.** With the cursor on the last text row, *zero*
render. So "unfold downward" designs need geometry bounded by the window.

**Headless composites a `relative = "win"` float at the screen ORIGIN.** Not just
the position *APIs* lying (that is [[nvim-float-winbar-row-trap]]) — `screenstring()`
itself shows the float's grid painted at row 1/col 1 while `nvim_win_get_config`
correctly reports row/col. So even reading the rendered screen headlessly cannot
settle float placement. A Python PTY where nvim writes `screenstring` dumps to a
file is the authority, and it is cheap: see the probes in this session.

**`state()` reports `"oS"` at idle with no UI attached**, so any guard like
`state("mo") == ""` refuses in every headless lane while working fine in a real
session (measured: `""` with a UI). Don't "fix" the guard — stub the predicate in
the spec and pin the *field spelling* instead (assert no letter outside `"mo"`,
which still catches a `state("mo")` → `state()` regression).

Bonus: **`vim.fn.win_findbuf(buf)` counts floating windows**, so a "is this buffer
shown more than once?" check taken *after* opening a float on it is always true —
that silently turned a fallback branch into dead code.

Related: [[nvim-float-winbar-row-trap]], [[nvim-pty-probe-key-timing]],
[[nvim-headless-window-height]].
