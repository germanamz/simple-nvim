---
type: memory
title: "Minuet stale ghost text \u2014 FIXED"
kind: project
description: "minuet painted stale FIM completions (no changedtick check + throttle drops keystrokes); FIXED 2026-08-22 via config.minuet_guard + throttle=0."
---

# Minuet stale ghost text — FIXED

**Shipped 2026-08-22** as `lua/config/minuet_guard.lua` + pacing in
`lua/plugins/minuet.lua`, documented in `docs/minuet-stale-guard.md`, pinned by
`tests/spec/unit/minuet_guard_spec.lua`. Symptom was ghost text painted against a
buffer it no longer fit (`    returnrn a - b`) that never corrected itself.

**Three defects in minuet's `virtualtext.lua`** (pin d29dec4, still true at tip):
- **A** — callback guard `:252` compares only its own request stamp, never buffer
  freshness, while `update_preview` anchors the extmark at the *live* cursor
  (`:166-167`, written `:189`). The plugin's own `duet/init.lua:73` DOES check
  changedtick; virtualtext has no equivalent.
- **B** — `schedule()` `:288-292` early-returns while throttled *before*
  `stop_timer()`/arming the debounce, so keystrokes in the window are dropped, not
  deferred. `on_cursor_hold_i` `:499` is **dead code, never registered**.
- **C** — `:271` `update_preview(ctx)` sits OUTSIDE the `if next(data)` guard at
  `:263`, so an EMPTY newer response repaints the *previous* text. Plus
  `cleanup()` `:199-204` never resets `current_completion_timestamp`.

**Key arithmetic:** the stamp is written only at `:249` and a second trigger can't
fire sooner than `throttle + debounce`, so the guard can only reject a round trip
EXCEEDING that sum. Measured round trip is **bimodal — median 433ms, p90 1058,
max 1572** (NOT the 355–510ms from the earlier model check, which was the
short-completion mode only). Against stock 1000+400 the guard was unreachable for
~96% of requests. So a **faster local model makes this worse**; a slow cloud model
self-heals.

**Both halves were required** — `throttle = 0` alone still gave 4 misaligned
renders of 7; the guard alone would trade wrong ghost text for silence.

**Verified** by PTY (headless can't enter insert): baseline probe log: ghost
`"rn a - b"` over `"    return"`; after the fix, 7 requests / 6 renders / **0
misaligned**, every `ctx_prefix_tail` matching `buf_prefix_now`. Full suite green
(unit 930, smoke 98, e2e 131), stylua clean.

**Why:** stops re-deriving this, and stops "just lower the debounce" — that
narrows the window without fixing the freshness check.

**How to apply:** keep `debounce` well under 433ms (150 measured best; 75 gave 29
requests/22 SIGTERMs). Restore minuet's defaults if this provider is ever pointed
at a PAID endpoint. The guard wraps
`minuet.backends.openai_fim_compatible.complete` — an internal with no stability
contract, so an upstream rename disables it silently; check
`require('minuet.backends.openai_fim_compatible').__stale_guard == true`. Never
drop a stale result via `callback({})` — that hits `:271` and manufactures defect
C. Unreported upstream (`git log -S'is_on_throttle' --all` = 1 commit, 2024-12-14),
so **upgrading the pin does not remove the need for this**. Related:
[[qwen-fim-ollama-template-blocker]], [[nvim-pty-probe-key-timing]],
[[nvim-headless-no-insert-in-prompt]].
