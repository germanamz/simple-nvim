---
type: memory
title: "Minuet multicursor accept \u2014 FIXED"
kind: project
description: "AI accept reached only the main cursor because multicursor replays the REDO RECORD (dot-repeat), not getreg('.') — fixed 2026-09-01 by re-expressing minuet's nvim_buf_set_text as nvim_paste, insert-mode only."
---

# Minuet multicursor accept — FIXED

**Shipped 2026-09-01** as `lua/config/minuet_multicursor.lua`, wired from
`lua/plugins/minuet.lua`, documented in `docs/ai-accept-multicursor.md`, pinned by
`tests/spec/unit/minuet_multicursor_spec.lua` (22 cases) plus three smoke cases in
`tests/spec/smoke/multicursor_spec.lua`.

**The correction that matters most.** multicursor replays an insert at the other
cursors from the **redo record** (`feedkeys(".", "nx")`, `input-manager.lua:188`),
NOT from `getreg(".")`. Every cursor this config's keymaps produce (`<C-n>`,
`<S-Down>`, `<leader>ca…`) is added from normal mode, so `cursor:mode()` is `"n"`
for all of them (`cursor-manager.lua:1314` clones the mode, `:2295-2303`
normalises it) and they all take the dot branch. The `getreg(".")` branch at
`:191-193` needs a cursor still holding a **selection** at insert exit. So the
comment in `lua/plugins/multicursor.lua` was wrong for years, and
**populating the `.` register alone would NOT have fixed anything** — I nearly
shipped a `<C-r><C-o>{reg}` fix on that false premise.

**Decisive primitive facts, all measured (`nvim --headless -u NONE`):**
- `nvim_buf_set_text` in insert mode → dot register `""`, dot-repeat is a no-op.
- `nvim_paste` in insert mode → dot register `<80>PS<text><80>PE`, text embedded
  **literally**, dot-repeat reproduces it exactly. Immune to autoindent,
  indentexpr, comment leaders, mini.pairs, blink — none of which a plain
  `feedkeys` of the text survives (this config sets a treesitter `indentexpr` on
  ~36 filetypes).
- `<C-r><C-o>z` also round-trips, but **by reference** — the dot register holds
  3 bytes naming register `z`, so replay depends on `z` being intact. Rejected.
- `<C-r><C-o>=expr<CR>` does NOT round-trip: only `<C-r><C-o>=` is recorded, the
  expression and `<CR>` are eaten by the cmdline.

**`nvim_paste` == `nvim_buf_set_text` ONLY in insert mode.** `vim.paste`
dispatches on mode. `HELLOWORLD` + `ZZZ` at col 5: insert `HELLOZZZWORLD`,
Replace `HELLOZZZLD` (overwrites), normal `HELLOWZZZORLD` (one col right).
Replace is reachable — minuet's gate is `^[iR]` and `<Insert>` fires no
CursorMovedI — so the guard is `mode() == "i"` **exactly**, never an `^[iR]`
family match. A judge panel killed the winning design over precisely this.

**Capture must happen after, not before.** `action.accept` resets `ctx`
(`virtualtext.lua:375-377`) and clears the extmark (`:379`) SYNCHRONOUSLY, before
its own `vim.schedule`d edit — so there is no instant to read the suggestion
from minuet. Recover it from the buffer delta instead (line-count change + a
tail-length pin, gated on changedtick moving exactly once). Bonus: covers
`<C-l>`/`accept_line` for free and survives a swap to `nvim_buf_set_lines`.
minuet has **no accept event/hook at all** — its only six `User` events are
request-lifecycle.

**Delete-then-paste, never paste-then-delete.** The latter's failure mode is the
suggestion in the buffer twice (silent corruption); the former's is text missing,
repaired from the local. Decide success by changedtick, not by the return value —
`vim.paste` is a user-overridable hook.

**How to apply:** `virtualtext.keymap.accept` must stay nil — `set_keymaps`
captures `action.accept` BY VALUE at `:558`, so a key bound there bypasses the
wrapper. Adjacent latent bug NOT fixed: `minuet_guard.install()` returns **false**
when already installed while `lua/plugins/minuet.lua` warns on false, so any
`:Lazy reload` emits a spurious WARN; the new module deliberately returns **true**
in that case. Same root cause, not fixed here: `nvim-ts-autotag` also inserts `>`
with `nvim_buf_set_text` (`internal.lua:473-483`).

Related: [[multicursor-autopairs-conflict]] (same failure class, and its stated
mechanism needs the same correction), [[minuet-stale-ghost-text]],
[[nvim-headless-no-insert-in-prompt]] (the insert-mode-keymap testing trick),
[[nvim-pty-probe-key-timing]].
