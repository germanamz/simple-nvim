---
type: memory
title: "Nvim refactor stage plan"
kind: project
description: "the staged quality refactor of the nvim config — goals, decisions, and Stage-2 phase order"
---

# Nvim refactor stage plan

Ongoing quality refactor of `~/.config/nvim` (started 2026-06-07): simplify
functions, decompose high-cyclomatic-complexity sections into named sub-functions,
extract reusable logic, improve naming — **no behavior change**. The 4-tier test
suite (unit/smoke/e2e/e2e-lsp) is the golden net; keep it green after every change.

Stage 1 (done) produced `docs/superpowers/specs/2026-06-07-refactor-design.md`
(actionable plan) and `2026-06-07-feature-inventory.md` (90-feature contract).

**User decisions:** create a greenfield `lua/util/` namespace; extraction-first
sequencing; write the 38 high-priority characterization tests just-in-time per
phase (not all upfront); pause for review after each phase (quality > velocity).

**Stage 2 COMPLETE** (branch `refactor/config-quality`, 12 commits, unit 119→191,
smoke 41, e2e 20, lint clean). P1 `util/git` → P2 telescope_smart (`git_status_codes`,
`_git_changes`, `open_legend`) → P3 gitsigns (`util/inline_diff`, `mark_hunks` split)
→ P4 markdown_paragraphs (`compute` split) → P5 review_base (`apply_selection`, adopt
`util/overlay`) → P6 options (extract `config/markdown_rewrap`) → P7 `lsp_refs.request`
→ P8 `util/path.buf_start_dir` + statusline `refresh_all_buffers`. Branch NOT yet
merged to main as of session end.

**Dropped (verified false premises):** `util/extmark` (gitsigns already pcall-wraps
set_extmark) and `lsp.lua` build_server_config H8 (loop already clean).

**SKIP (over-abstraction, per adversarial critique):** highlight-color util,
buf-local keymap helper, cursor-pos0 util (already a local in lsp_refs).

Tests must run sandbox-disabled — see [[nvim-tests-need-sandbox-disabled]].
