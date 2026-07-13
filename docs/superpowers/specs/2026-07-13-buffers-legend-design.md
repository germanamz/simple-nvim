# Buffers-picker flags legend — design

**Date:** 2026-07-13
**Status:** approved (floating-box style chosen by user)

## Problem

`<leader>fb` (Telescope buffers picker) shows an indicator column (`%a +`,
`#h`, …) whose flags are cryptic. The user wants a legend box visible while
the picker is open.

## Design

A non-focusable floating legend strip anchored directly below the picker's
results window, opening with the buffers picker and closing with it —
the same presentation `<leader><space>` (smart_files) already uses for its
git-status legend.

Legend content (two centered rows, flag chars highlighted, labels muted):

```
+ modified   % current   # alternate <C-^>
a active     h hidden    = read-only
```

Only flags telescope's `gen_from_buffer` entry maker can actually render are
listed (`%`/`#`, `a`/`h`, `=`, `+`); `:ls`'s `-`/`u`/`x`/`R`/`F` never appear
in this picker. Both rows fit the ~43-cell results window of a 120-column
horizontal layout, and the float sets `wrap=false` so an overlong row clips
instead of hiding the second row.

## Components

- **`lua/util/picker_legend.lua` (new)** — the generic "legend under a
  telescope picker" machinery, extracted from `telescope_smart.lua` where it
  is currently local: resolve the results window from a prompt buffer, window
  config math (row/col/width, below-results placement with
  overlay-bottom-rows fallback, no-op when taller than results), line
  centering (`fit_line`), and lifecycle wiring (schedule-open, close on
  `BufWipeout`/`BufLeave` of the prompt buffer, re-render on `VimResized`).
  Mirrors the `util/overlay.lua` precedent: extract when two callers would be
  byte-identical.
- **`lua/config/telescope_smart.lua` (refactor)** — delegates window math +
  lifecycle to `util.picker_legend`; keeps its counts→segments rendering.
  No behavior change; existing tests must keep passing.
- **`lua/config/buffers_legend.lua` (new)** — `M.open()` launches
  `require("telescope.builtin").buffers()` with an `attach_mappings` that
  wires the legend via `util.picker_legend`. Static two-row content; pure
  line-builder exposed for unit tests.
- **`lua/plugins/telescope.lua`** — `<leader>fb` calls
  `require("config.buffers_legend").open()`.
- **`docs/keybindings.md`** — note the legend on the `<Space>fb` rows.

## Error handling

- Picker failed to open / results window gone → no float.
- Terminal too short: legend overlays the results window's bottom rows
  instead of falling off-screen (existing smart_files behavior).
- Resize: re-rendered at the new position (existing smart_files behavior).

## Testing

- Unit (`tests/spec/unit/buffers_legend_spec.lua`): line builder returns two
  rows containing all 7 flag/label pairs; highlight ranges in bounds.
- E2E (extend `tests/spec/e2e/telescope_spec.lua`): `<Space>fb` opens the
  picker plus a float containing legend text; closing the picker removes it.
- Existing `telescope_smart` unit + e2e specs guard the refactor.
