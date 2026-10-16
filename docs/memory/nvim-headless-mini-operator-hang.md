---
type: memory
title: "Nvim headless mini operator hang"
kind: feedback
description: "Driving mini.surround/mini.ai operator+textobject keystrokes via feedkeys in a headless -c luafile script hangs/times out; call the plugin Lua API instead."
---

# Nvim headless mini operator hang

Simulating `gsaio)` / `gsaiof` / `vio` / `dio` with `nvim_feedkeys(..., "x", false)` inside a
`nvim --headless -c "luafile ..."` script **hangs until timeout**. mini.surround's `gsa`
operator and mini.ai's a/i textobjects run `getcharstr`/operatorfunc loops that never drain the
feedkeys typeahead in a non-interactive script context (same root cause as
[[nvim-headless-no-insert-in-prompt]] — input is never drained). mini.surround's `f` output
additionally blocks on a `vim.fn.input("Function name")` prompt.

**Why:** Burned two 2-minute timeouts trying to prove the dotted-chain `o` textobject +
mini.surround composition end-to-end via keystrokes.

**How to apply:** To verify a mini.ai textobject, drive the Lua API directly —
`require("mini.ai").find_textobject("i", "o")` returns the region; assert
`line:sub(region.from.col, region.to.col)` (cols are 1-based inclusive). This is what
tests/spec/smoke/dotted_chain_spec.lua does. Only reach for a PTY + `--remote-send` if you truly
must exercise the operator-pending keystroke path.
