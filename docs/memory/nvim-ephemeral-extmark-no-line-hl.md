---
type: memory
title: "Ephemeral extmarks ignore line_hl_group"
kind: reference
description: "ephemeral extmarks silently ignore line_hl_group — accepted without error, never painted; use persistent marks for full-line/underline decorations."
---

# Ephemeral extmarks ignore line_hl_group

An **ephemeral** extmark (`ephemeral = true`, set from a
`nvim_set_decoration_provider` `on_line` callback) **silently ignores
`line_hl_group`**. `nvim_buf_set_extmark` accepts it without error and returns a
valid id — the line simply never paints. Same for the whole-line family; only the
`virt_text` / `hl_group` options actually render ephemerally.

**Why it bites:** `config.block_guides` is the obvious model to copy for any new
per-line decoration, and it *is* ephemeral. Copying its shape for anything that
needs a full-line highlight produces code that looks right, throws nothing, and
draws nothing.

**How to settle it:** a headless probe cannot — with no UI there is no grid, and
`screenattr()` returns 0 for every cell. Run under a **pty** and read
`nvim_api__inspect_cell(1, row, col)`, and always include a **persistent-mark
control on an adjacent row**. Without the control, "attrs are empty" is
indistinguishable from a broken harness. (`nvim__inspect_cell` reports attrs
oddly under `TERM=xterm-256color` — it showed `foreground` for an
`underline`+`sp` group — so compare rows against each other, don't trust the
field names.)

Persistent marks are usually the better fit anyway when the decoration depends on
the buffer's **text** rather than the cursor: they cost nothing per redraw and
shift with edits for free. Cache-key them on `changedtick .. ":" .. filetype` —
`:set filetype=` swaps the treesitter parser **without** bumping the tick, so a
tick-only key serves the old language's decorations until the next edit.

Hit building `config.decl_rules` (the hairline above each top-level declaration).

Related: [[nvim-lsp-semantic-tokens-outrank-treesitter]], [[nvim-float-winbar-row-trap]],
[[nvim-headless-window-height]].
