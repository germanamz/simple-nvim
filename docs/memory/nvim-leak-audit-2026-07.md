---
type: memory
title: "Nvim leak audit 2026-07"
kind: project
description: "2026-07-06 CPU/memory runaway investigated — 400GB VSZ is macOS red herring; no config runaway confirmed; playbook in docs/leak-diagnostics.md"
---

# Nvim leak audit 2026-07

2026-07-06: user reported ~96% CPU across 3 processes + "400GB virtual memory" after ~1h of nvim.
A 78-agent audit of the whole config (12 confirmed / 11 refuted findings) concluded:

- 435GB VSZ is NORMAL for every macOS ARM64 process — only RSS/%CPU are signals.
- No runaway timer/watcher/loop in the config; nothing ramps after 1h or sustains at idle.
- Only pinned burner: minuet → Ollama qwen2.5-coder:7b, ~1 FIM request/s while typing (by design,
  bounded: throttle 1000ms, debounce 400ms, --max-time 3, prior curls SIGTERMed). Idle within ~3s.
- gopls "no package metadata" semantic_tokens errors were a 2s startup race (4 log lines), NOT a loop —
  don't re-blame it without log evidence. Nvim 0.12.3 semantic-tokens does lack a terminal error state, though.
- Identity of the 3 hot processes was never captured. Full capture playbook + verified minor defects
  (Makefile orphan reaping, unguarded curls in ai_models.lua:574/:422, telescope_smart :381 no-timeout rg,
  ungrouped nvim-tree autocmds, FocusGained git-spawn sweeps, git.root negative-cache miss) are in
  docs/leak-diagnostics.md (untracked, in-repo per [[spec-docs-in-repo-not-scratchpad]]).
- plenary test orphans: `make test-*` leaves hung headless nvim children (~35 found, ~6MB each, 0% CPU);
  cleanup `pkill -f plenary.busted`. Related: [[nvim-tests-need-sandbox-disabled]].

2026-07-06 (later): ALL verified defects FIXED via TDD (7 parallel fixers + 3-lens review + 1 must-fix
follow-up: statusline sweep guard needed a spawn timeout + pcall'd fan-out so on_done can't wedge).
Makefile now reaps via scripts/run-plenary.sh (SIGKILL the parent's pgroup; SIGTERM ignored by
Lua-wedged children). Gotcha: plenary children finish specs but a live libuv handle keeps them alive —
DIRECT single-spec runs still strand children; use scripts/run-plenary.sh <init> <spec> instead.
Suites unit/smoke/e2e all green after; changes left uncommitted for user review.

**Why:** avoid re-auditing the same 8.8k lines from scratch; refuted leads must not be re-proposed.
**How to apply:** if the runaway recurs, run playbook step 1 (`ps -Ao pid,ppid,pcpu,rss,etime,command -r | head -20`)
before any code hypothesis; suspect Ollama-while-typing first, then `sample` the hot pid.
