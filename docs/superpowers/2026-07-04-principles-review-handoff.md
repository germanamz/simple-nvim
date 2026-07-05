# Principles Review — Follow-Up Handoff

**Landed:** commit `1bcfff1` on `main`, pushed. Whole-config review against a
code-quality principles catalog (DRY/AHA, KISS, SRP, coupling, perf, fail-fast);
41 adversarially-verified findings applied — 12 bug fixes, 4 new modules
(`util/pool.lua`, `util/state.lua`, `config/nvim_tree_hl_decorator.lua`,
`config/lock_drift.lua`), 2 new spec files, `parser-revisions.lua` moved to the
repo root.
**Status at handoff:** lint + unit + smoke + e2e + `make check` all green;
working tree clean; `main` == `origin/main`.

This document lists what was **deliberately left** for a later session. Nothing
here is broken — items are ordered by value. You do not need prior context;
everything needed is below.

---

## 0. Environment caveats (read first)

1. **Run tests with the sandbox DISABLED.** `make test-*` spawns real headless
   nvim + git fixtures that write outside an agent sandbox's allowlist; failures
   under a sandbox are environment errors (`E303` swap, git-status mismatches),
   not logic errors. Pure-Lua specs are the exception, but just disable it for
   all `make test-*`.
2. **Verify against the code, not this doc** — file:line references drift.

---

## 1. Run the slow lane — ✅ DONE 2026-07-04

Ran green with the real server exercised (attach + initialize handshake, not
the self-skip). Note for future runs: the isolated test env never sees mason's
bin dir, so a plain `make test-lsp` self-skips as pending — prepend it:

```bash
PATH="$HOME/.local/share/nvim/mason/bin:$PATH" make test-lsp   # sandbox off
```

---

## 2. Housekeeping — ✅ DONE 2026-07-04

Both branches deleted locally and `review/engineering-improvements` deleted on
origin (verified 0 commits ahead first). Stale `branch.*` upstream sections
(including an old `block-scope-guides`) removed from `.git/config`.

---

## 3. Optional hardening tests — ✅ DONE 2026-07-05

All three landed as mutation-verified characterization tests (each test was
watched to fail against a temporarily-reintroduced bug, by the implementer and
independently by an adversarial reviewer):

1. **`review_base.get` timeout path** — pinned in `review_base_spec.lua`:
   timed-out resolve returns the persisted base, does not prune, does not
   validate.
2. **`ignore_filter` mid-batch invalidation** — pinned in
   `ignore_filter_spec.lua` with a callback-capturing `vim.system`/
   `vim.schedule` stub. Note: there are THREE identity guards (stage-1 prime,
   stage-1 on_complete, stage-2 verdict), not two; each is individually
   mutation-witnessed.
3. **statusline FocusGained sweep** — pinned in `statusline_spec.lua` (spy on
   `util.path.buf_start_dir` + an end-to-end stale-branch overwrite test). The
   spec work surfaced a latent production quirk: `refresh()`'s async callback
   guards only on buffer validity, so a wiped-then-recreated buffer number can
   briefly receive another buffer's branch. Left unfixed (cosmetic, self-heals
   on next refresh); worth a guard token if ever touched.

---

## 4. Optional cleanups — ✅ DONE 2026-07-05

All five landed:

- **`markdown_paragraphs.M.frontmatter_end(bufnr)`** removed with its spec
  block (grep-verified no other callers; the compute-path frontmatter test
  stays).
- **Decorator `ColorScheme` augroups** — per-decorator named augroups with
  `clear = true` (`nvim_tree_hl_<spec.group>` in the factory,
  `nvim_tree_git_hl` in nvim_tree_git); re-requires now replace instead of
  stack, siblings unaffected. Red-first tests in both decorator specs.
- **`telescope_smart` cwd canonicalization** — shared `canonical_cwd` helper
  at the top of both refresh paths; `/` root guarded.
- **`review_base.get` retry backoff** — the deferred escape hatch was
  implemented (upgraded from "if it ever bites"): per-root `timeout_at`
  timestamp, `TIMEOUT_BACKOFF_MS = 10000`; within the window `get()` returns
  the persisted base from a table lookup without re-running resolve. Cleared
  by any completed resolve; deliberately NOT reset with the cache (tracks git
  responsiveness, not store contents). Seams `M._timeout_at` /
  `M._TIMEOUT_BACKOFF_MS`.
- **`DEFAULT_MODEL` single-sourced** — exported as `config.ai.M.DEFAULT_MODEL`
  (ai_models already required config.ai, so this direction is cycle-free);
  ai_models reads it call-time at its hint site. Remaining nit: a doc comment
  in `lua/plugins/minuet.lua:10` still carries the literal in an example
  `ollama pull` command.

---

## 5. Do NOT re-propose (adversarially refuted)

A future review pass will re-flag these; they were examined against the code
and rejected — see memory note `nvim-principles-review-2026-07` for the full
list with reasons. Highlights:

- Splitting the 1008-line `ai_models.lua` (cohesive around one modal; the
  header comments are load-bearing design records).
- telescope_smart "status/diff serialization race across pipelines",
  gitsigns `file_new_vs_base` sync-spawn / GitSignsUpdate double-fetch perf
  flags, the buffer-loop "triplication" in gitsigns.
- Deduplicating the 2000ms bound / status argv / rg-arg literals (coincidental
  similarity, would couple modules).
- From the earlier refactor: highlight-color util, buf-local keymap helper,
  cursor-pos0 util.

---

## 6. Facts a new session will want

- **plenary.curl** raises `error()` *inside a luv callback* on any curl failure
  unless `opts.on_error` is passed — a `pcall` around the call cannot catch it.
  Sync path: `on_error`'s return is discarded; the request returns an empty
  table (no `.status`). `opts.timeout` is sync-only; in callback mode bound via
  `raw = { "--max-time", "N" }`. (Memory: `plenary-curl-error-semantics`.)
- **`util.git.run`** now returns `lines, ok, timed_out` — timeout is
  `code == 124 and signal == 9` from `vim.system():wait(ms)`; the old
  nil-return branch survives only for SIGKILL-proof processes.
- **`util.state.write_atomic` returns a boolean** — `os.rename` does NOT
  raise; `review_base.write_state` gates its cache write-through on it. The
  review_base spec stubs `os.rename` to throw, which still propagates.
- The full review + verification artifacts lived in the old session's
  scratchpad (gone); the durable summary is in the memory notes
  `nvim-principles-review-2026-07` and `nvim-tree-ignore-filter`.
