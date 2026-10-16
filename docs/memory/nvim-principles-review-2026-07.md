---
type: memory
title: "Nvim principles review 2026-07"
kind: project
description: "2026-07-04 whole-config principles review — what landed (41 findings), and refuted proposals NOT to re-propose"
---

# Nvim principles review 2026-07

2026-07-04: full-config review against a code-review principles catalog (8
cluster reviewers + adversarial verifiers), all 41 confirmed findings landed
as commit `1bcfff1` on `main` (pushed), suite green (unit/smoke/e2e + make
check). Landed:
new `util/pool.lua` (bounded pool, ex-telescope_smart `run_pool`),
`util/state.lua` (read_file/write_atomic; write_atomic returns a boolean —
os.rename does NOT raise, review_base gates its cache write-through on it),
`config/nvim_tree_hl_decorator.lua` (factory for the 3 colour decorators),
`config/lock_drift.lua` (ex-init.lua), `util.markdown.is_fence`,
`parser-revisions.lua` moved tests/ → repo root. Bug fixes: ai_models plenary
on_error trio + exact-name CURATED_FIM (family-keyed let instruct tags skip
the /api/show gate), nvim_tree_git cwd cache-key (see
[[nvim-tree-ignore-filter]]), ignore_filter stale-batch identity guards,
review_base timeout≠prune (util.git.run now returns third value `timed_out`,
code==124 and signal==9), telescope_smart outer status/diff timeouts
(BULK_GIT_TIMEOUT_MS) unwedging `refreshing[cwd]`, gitsigns settle loop scans
all buffers, statusline FocusGained sweeps all buffers, block_guides cache
keys on filetype too, wikilinks scrubs inline code spans.

**Refuted by adversarial verify — do NOT re-propose:** splitting the
1008-line ai_models.lua (cohesive around the modal; comments are load-bearing),
start_pull's module-state reset "coupling", telescope_smart cross-pipeline
status/diff serialization "race", gitsigns file_new_vs_base sync-spawn and
GitSignsUpdate double-fetch perf flags, the buffer-loop triplication in
gitsigns, duplicated 2000ms bound / status argv / rg-arg literals, the legend
VimResized-after-BufLeave leak, ai.lua write-failure notify. Older rejects
still stand: highlight-color util, buf-local keymap helper, cursor-pos0 util.

zsh={shfmt} kept with a caveat comment; stylua deliberately Homebrew-managed,
not mason-pinned (PATH + shadowing).

**2026-07-05 follow-up pass (handoff sections 3+4) landed:** all three
hardening tests written mutation-verified (review_base timeout path,
ignore_filter's THREE drain identity guards, statusline FocusGained
non-current-buffer sweep), plus: markdown_paragraphs.frontmatter_end wrapper
removed, per-decorator named ColorScheme augroups (nvim_tree_hl_<group> /
nvim_tree_git_hl, clear=true), telescope_smart canonical_cwd trailing-slash
strip, review_base per-root timeout backoff (timeout_at + TIMEOUT_BACKOFF_MS
10s, seams M._timeout_at/M._TIMEOUT_BACKOFF_MS, deliberately NOT reset with
the cache), DEFAULT_MODEL now single-sourced as config.ai M.DEFAULT_MODEL
(ai_models requires ai — cycle-free direction). Latent quirk noted, unfixed:
statusline refresh()'s async callback can land on a recycled buffer number
(guards only nvim_buf_is_valid).
