# nvim-tree git-status performance at superproject scale

**Date:** 2026-07-17
**Status:** design approved (direction), implementation staged below
**Goal:** make nvim-tree git status fast on folders and submodules for a very
large repository — 200+ submodules, 20,000+ files — without losing rollup
fidelity.

## Problem

The nvim-tree git decorator sources per-file status codes from the shared
`config.telescope_smart` codes cache. On a cold render `Decorator:new()` calls
`_refresh(cwd)` → `recursive_changes_async(root, base)`, which:

1. enumerates every submodule via cheap `.gitmodules` reads (already optimized —
   `fdc6c66`),
2. runs one whole-superproject `git status --porcelain --untracked-files=all
   --ignore-submodules=all` plus a `base...HEAD` diff,
3. **runs `git status --porcelain` inside every submodule** — ~200 spawns,
   bounded at `cores-2` (≈9 sequential waves), merged into one codes map.

Step 3 re-runs **eagerly over the whole superproject** on:

- every cold tree open,
- **every `FocusGained`** (`refresh_labels` → `invalidate_all` → full
  `_refresh_async`),
- `HeadChanged` / `ReviewBaseChanged` for the cwd,
- the `<leader>gR` manual refresh.

## The core mismatch

The submodule **branch/status labels** (`config.nvim_tree_submodule` +
`config.repo_status`) are already **lazy — visible rows only**. But the per-file
**codes** are **eager — whole-tree, all 200 submodules** — even though the tree
only *renders* visible nodes. A collapsed submodule folder needs only "is it
dirty?" for its `*` rollup marker; the expensive per-file recursion into a
collapsed submodule is pure waste. Per-file detail is only genuinely needed for
the outer repo plus the *expanded* submodule.

A hard constraint: the codes cache is **shared with the Telescope pickers**,
which genuinely do want whole-tree codes (they list every file, including inside
submodules). Tree and picker have different needs from one source.

An inherent git limit: **you cannot know a submodule's working-tree dirtiness
without effectively running status inside it.** Full working-tree rollups for
200 submodules fundamentally require scanning them. The design makes that scan
run *once*, *non-blocking*, *cached*, and *incremental*, and gives instant
fidelity for the common cases without waiting on it.

## Design — a tiered status model

Three tiers fill in progressively; **nothing blocks the UI**.

### Tier 0 — instant, one spawn (already in the hot path)

Change the outer whole-repo status flag from `--ignore-submodules=all` →
`--ignore-submodules=dirty`. This keeps the per-submodule **working-tree scan
off** (cheap — it only reads each submodule's HEAD ref inside the single git
process) but now **reports every commit-diverged submodule** (HEAD ≠ the SHA
recorded in the superproject — the "submodule bumped to a new commit" case).

We already enumerate the submodule path set from `.gitmodules`, so we
cross-reference each outer-status line:

- path ∈ submodule set → a **dirty-submodule rollup signal** (not a file),
- otherwise → a **file code** (existing v1 parse unchanged).

The picker filters submodule gitlink lines out of its file list (path is a
folder, not a file). The tree rolls a commit-diverged submodule up into **all**
its ancestor directories — so **collapsed folders show a dirty marker for
commit-diverged nested submodules immediately, at zero added cost**.

**Empirically validated** (see appendix): `--ignore-submodules=dirty` prints
` M child` for a commit-diverged submodule and stays silent for a working-tree-
only-dirty one; `--ignore-submodules=all` hides both.

### Tier 1 — lazy, visible rows only (exists today)

`config.repo_status` resolves branch + working-tree dirty count for each
*visible* submodule row (`git status --porcelain=v2 --branch
--ignore-submodules=all`). Upgrades a visible submodule's marker to reflect
working-tree dirt the moment its row is on screen. Unchanged in behavior; gains
a state-keyed cache (below) so `FocusGained` stops blindly re-resolving it.

### Tier 2 — background, cached, incremental (the new "cache")

A bounded background scan runs `git status --porcelain` inside each submodule to
catch **working-tree-only dirt** (same HEAD, uncommitted edits) — the fidelity
Tier 0 cannot see. Results are **cached per-submodule keyed by
`HEAD sha + .git/index mtime`**, so:

- it runs to completion **once** cold (non-blocking, progressive; the tree
  reloads as rollups fill in),
- on `FocusGained`/refresh only submodules whose HEAD or index **changed**
  re-run — steady-state cost ≈ 0 instead of today's 200 spawns *per focus*,
- **the picker reuses the exact same cache** — one computation feeds both.

## Fidelity outcome

| Change class | Fidelity | Latency |
| --- | --- | --- |
| Outer-repo files & folder rollups | full | instant (one status) |
| Commit-diverged submodule (any depth, even collapsed) | full | instant (Tier 0) |
| Working-tree-dirty submodule, visible row | full | instant (Tier 1) |
| Working-tree-dirty submodule, collapsed/nested | full | progressive cold, instant once cached (Tier 2) |
| Per-file codes inside an expanded submodule | full | on expand, from Tier 2 cache |

### Known limitation (documented, escape-hatched)

A submodule with **unstaged working edits only** (same HEAD, nothing staged),
**not visible**, changed **externally** since the last scan: its `.git/index`
mtime does not move, so Tier 2's state key will not auto-invalidate it until you
touch it, expand to it, or hit `<leader>gR`. In-session edits are caught by the
filesystem watcher (below). Recommend `core.fsmonitor` + `core.untrackedCache`
git config as accelerators (noted, not required).

## Cache & invalidation contract

**Per-submodule codes cache (Tier 2)** — new state, owned by a focused module
(`config.submodule_status`, see boundaries):

- key: `submodule abs dir` → `{ codes, state = HEAD_sha .. ":" .. index_mtime }`
- a scan re-runs a submodule only when its current `state` differs from cached.
- reused by both the tree decorator and `telescope_smart`'s
  `recursive_changes_async`.

**`repo_status` state key (Tier 1)** — extend its per-dir cache entry with the
same `HEAD sha + index mtime` state, so `refresh_labels` on `FocusGained` can
**revalidate cheaply** (stat only) instead of `invalidate_all` + full re-resolve.
`<leader>gR` keeps a hard flush.

**Event wiring** (extends `config.nvim_tree_git.register_autocmds`, unchanged in
shape):

- `FocusGained` → revalidate outer status (one spawn) + state-keyed revalidate of
  visible submodules + Tier 2 state-keyed revalidate. No blind 200-spawn storm.
- `HeadChanged` / `ReviewBaseChanged` (scoped to cwd root) → as today, but the
  Tier 2 cache absorbs unchanged submodules.
- `filesystem_watchers` churn under a submodule path → targeted invalidation of
  that submodule's Tier 2 entry (in-session edit precision).
- `<leader>gR` → hard flush of all caches (unchanged hatch).

## Tree decorator changes (`config.nvim_tree_git`)

- **Rollups from two sources**, unioned: (a) outer-repo file codes (as today, one
  status), (b) the **dirty-submodule set** (Tier 0 commit-diverged ∪ Tier 1
  visible-dirty ∪ Tier 2 working-dirty). A dirty submodule marks all ancestor
  dirs `SmartFilesModified` (`*`).
- **Memoize `_dir_markers`** keyed by the codes-cache identity so it is **not**
  recomputed on every render (scroll/expand). At 20k files the ancestor walk is
  pure Lua but should run only when codes actually change.
- **Per-file codes for an expanded submodule** come from the Tier 2 cache; when a
  file node inside a not-yet-scanned submodule is decorated, request that
  submodule's scan (priority) and repaint on completion — same
  request-then-repaint pattern `repo_status.request` already uses.

## Module boundaries

- **new `config.submodule_status`** — owns the per-submodule codes cache, the
  state key (`HEAD sha + index mtime`), the bounded/incremental scan, and
  targeted invalidation. Knows nothing about nvim-tree; fires a `User` event on
  completion. Consumed by `nvim_tree_git` and `telescope_smart`.
- **`config.repo_status`** — gains the state-keyed cache entry; otherwise
  unchanged public surface (`get`/`request`/`segments`/`label_plain`).
- **`config.nvim_tree_git`** — rollups union the dirty-submodule set; memoized
  `_dir_markers`; lazy on-expand submodule codes request.
- **`config.telescope_smart`** — `recursive_changes_async` delegates the
  per-submodule statuses to `config.submodule_status`; outer status switches to
  `--ignore-submodules=dirty` and splits gitlink lines from file lines against
  the submodule set.

## Phased implementation (as shipped)

Each phase is independently valuable, test-first, and lands as its own commit(s)
on branch `perf/nvim-tree-git`.

- **P1 — `repo_status` state-keyed cache. (shipped)** Add a spawn-free
  `util.git.index_key` (git index mtime) to the per-dir cache; `refresh_labels`
  revalidates on `FocusGained` (keep unchanged submodules) instead of
  `invalidate_all`, with `{ hard = true }` for the definitive HeadChanged /
  ReviewBaseChanged / `<leader>gR` signals. Kills the per-focus branch-label
  re-resolve storm.
- **P2 — `config.submodule_status` module. (shipped)** Per-submodule codes cache
  keyed by `index_key`, shared single-flight behind the pickers' bulk `scan()`
  and the tree's on-demand `request()`. `telescope_smart.recursive_changes_async`
  delegates its per-submodule statuses to it, so the whole-tree scan runs cold
  once and re-scans only changed submodules thereafter. (A follow-up fix makes
  the recursion `revalidate()` each run so a changed submodule is never served
  stale, restoring the old always-fresh semantics incrementally.)
- **P3 — Tier 0 outer status. (shipped)** Outer status switched to
  `--ignore-submodules=dirty`; `apply_worktree_lines` classifies gitlink rows
  against the discovered submodule set into a `dirty_subs` set (not codes/counts);
  `dirty_subs` threads through the codes cache to the tree, where `_dir_markers`
  rolls a bumped submodule up through its ancestors. Surfaces commit-diverged
  submodules the recursion (which finds no files inside a clean-worktree
  submodule) never could.

### P4 — reframed: aggressive per-file laziness is moot under "full rollups"

The original P4 was "the tree stops scanning collapsed submodules." Building
P1–P3 surfaced why that is the wrong move **given the approved full-rollups
requirement**: a collapsed, working-tree-dirty submodule (same HEAD, uncommitted
edits) can only get its rollup marker by *scanning it*, and git offers no cheaper
way. So full rollups **require** scanning every submodule — exactly what the
cached, incremental Tier 2 scan already does, once, in the background.

Per-file laziness would only skip **parsing** already-scanned lines for collapsed
nodes (nvim-tree already skips *rendering* them) — a few microseconds of Lua, not
the expensive axis (the git spawns). The scan itself cannot be skipped without
losing the fidelity the user asked for. Therefore the shipped architecture
(P1 state-keys + P2 cache + P3 Tier 0) is the achievable optimum:

- **Cold open:** non-blocking; one outer status + one bounded background scan of
  all submodules (the irreducible cost of full working-tree fidelity), cached.
- **Every subsequent focus / refresh:** near-zero — only submodules whose index
  moved re-scan; branch labels revalidate; commit-diverged rollups are instant
  from Tier 0.
- **Recurring per-focus 200-spawn storm (the actual pain): eliminated.**

Remaining lever, if ever wanted: gate the *outer* status refresh on the outer
repo's `index_key` too (skipping the 20k-file walk when nothing staged), trading
live pickup of bare external edits for less steady-state work. Not shipped —
current freshness/cost balance (500 ms TTL + filesystem watcher + `<leader>gR`)
is good, and it would widen the documented staleness window.

## Test strategy

- **Unit** (`tests/spec/unit`): pure parse/derive functions — dirty-submodule
  splitting against the submodule set, `_dir_markers` rollup incl. a dirty
  submodule ancestor chain, state-key equality/invalidations, memoization
  identity. Drive async completion via the existing swappable `_resolve`/`_run`
  seams (no real spawns).
- **e2e** (`tests/spec/e2e`): a fixture superproject with a nested submodule;
  assert collapsed-folder rollup for a commit-diverged submodule (Tier 0),
  visible-row label (Tier 1), expanded per-file codes (Tier 2), and that a second
  `FocusGained` issues no per-submodule status for unchanged submodules (assert
  via a spawn-counting seam). Follow the isolated-env rules in the test memories
  (create buffers via API, `full_init`, sandbox off for git/parser/swap writes).

## Appendix — empirical validation

Scratch superproject `super` embedding submodule `child`:

```
=== submodule checked out to older commit (commit-diverged) ===
--- ignore=dirty ---   ->   " M child"     # Tier 0 sees it, cheap
--- ignore=all   ---   ->   (nothing)      # today's blind spot
=== submodule working-tree dirty (same HEAD) ===
--- ignore=dirty ---   ->   (nothing)      # Tier 0 can't; Tier 1/2 do
--- ignore=none  ---   ->   " M child"     # expensive full scan
```
