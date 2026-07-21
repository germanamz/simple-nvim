# nvim-tree git integration

nvim-tree shows git state for a whole workspace: a superproject opened with
`nvim .` that contains many submodules, often hundreds, over tens of thousands of
files. Two concerns meet here. The tree should answer "which branch is each
submodule on, and is anything dirty, ahead, or behind" at a glance, and it should
do so without re-scanning every submodule on every window focus. This document
covers both what the tree displays and how it stays fast at that scale.

## What the tree shows

Three layers of git information render in the tree:

- **Per-file status codes and directory rollups.** The existing `nvim_tree_git`
  decorator prefixes each file with its status and rolls a dirty descendant up
  into a `*` marker on every ancestor folder. Codes come from the shared
  `config.telescope_smart` codes cache, the same source the [file
  picker](smart-files.md) uses.
- **The superproject's branch and working state**, appended to the tree's root
  folder label (the repo-name row at the top).
- **Each submodule's own branch and working state**, as colored trailing text
  after the submodule folder name. Submodules routinely sit on different branches
  or detached at a pinned tag, so each row reports its own.

```
monorepo   main ✎3 ↑2 ↓1          ← root folder label (monochrome)
├─ apps/
├─ libs/
└─ vendor/
    ├─ sdk/    main ✎ ↑2           ← submodule decorator (colored, "after")
    └─ theme/  v2.1 (detached)     ← submodule decorator (colored, "after")
```

Status comprises a dirty flag with a count of changed and untracked files (`✎3`),
ahead/behind counts versus upstream (`↑2 ↓1`), and on a detached HEAD a readable
ref from `git describe` (`v2.1 (detached)`). A clean repo on its upstream shows
just the branch name.

### Why the root header is monochrome

nvim-tree's `root_folder_label` renders its result as one buffer line under a
single highlight group, and decorators do not run on the header line. So the root
status can be text but not multi-colored; the `✎ ↑ ↓` glyphs are legible by shape.
Coloring it would mean moving the status to the winbar, which parses statusline
markup; the status stays on the repo-name row instead, where it scrolls with the
tree. Submodule labels are decorators, so they are fully colored.

## How branch and status are sourced

One generic module resolves branch and status for any repo directory, and two
consumers render it.

`config.repo_status` owns an async resolver and a per-directory cache. `get(dir)`
reads the cache and never spawns; `request(dir)` is a single-flight scheduler that
runs `git -C dir status --porcelain=v2 --branch` (chaining one `git describe` when
HEAD is detached), stores the parsed result, and fires a `User RepoStatusChanged`
event. `segments(status)` formats the highlighted parts for the decorator, and
`label_plain(dir)` formats the plain string for the root header, scheduling a
resolve on a cache miss so the header warms up and repaints. The module never
touches nvim-tree; it fires an event the same way `config.git_head` fires
`HeadChanged` and `config.review_base` fires `ReviewBaseChanged`, which keeps it
decoupled and reusable.

The cold-to-warm cycle is the pattern the codes cache already uses. A render asks
`get(dir)`, misses, and triggers `request(dir)`. The resolve lands, fires
`RepoStatusChanged`, and a subscriber in `nvim_tree_git` reloads the tree, which
re-renders the now-cached status.

Each resolve runs with `--ignore-submodules=all`, uniformly for the root and every
submodule. Each repo's `✎<count>` then reflects only its own tracked files, and
nested submodules report on their own rows, so the two levels never double-report
the same change. A moved submodule pointer is therefore not counted at the root;
the knob for counting it is `--ignore-submodules=dirty`.

The submodule labels come from a second decorator, `config.nvim_tree_submodule`,
placed `after` rather than `before` (a decorator has exactly one placement, and
the git decorator already owns `before`). The `after` placement is also what makes
the labels behave: after-text lands in the buffer line, so it colors per part and
replays into nvim-tree's full-name truncation float when a row overflows the
column. `right_align` does neither and can overlap file names. It snapshots the
submodule path set for
the current cwd from `telescope_smart._submodule_paths_async`, the cheap
`.gitmodules` enumerator (see the [picker doc](smart-files.md)), and identifies a
submodule row by matching `node.absolute_path` against that set. nvim-tree has no
submodule concept of its own, so the caller must supply the set. The decorator
runs `icons()` only on visible nodes, so a submodule resolves only when its folder
row is actually on screen, never for one you have not navigated to.

## Staying fast: a tiered status model

The branch and status labels above are lazy by construction: they resolve visible
rows only. The per-file codes were the opposite, eager over the whole tree and all
submodules, even though the tree only renders visible nodes. A collapsed submodule
folder needs only "is it dirty?" for its rollup marker, so recursing into it for
per-file detail is waste. That eager scan re-ran on every cold open and on every
`FocusGained`, producing a recurring several-hundred-spawn storm.

One constraint shapes the fix: you cannot know a submodule's working-tree
dirtiness without effectively running status inside it, and full rollups for every
submodule fundamentally require scanning them. The model below makes that scan run
once, in the background, cached and incremental, and gives instant fidelity for
the common cases without waiting on it. Three tiers fill in progressively and
nothing blocks the UI.

### Tier 0: instant, one spawn

The outer whole-repo status runs with `--ignore-submodules=dirty` instead of
`=all`. This still keeps the per-submodule working-tree scan off, since it only
reads each submodule's HEAD ref inside the single outer git process, but it now
reports every commit-diverged submodule, where HEAD differs from the SHA the
superproject recorded. Because the submodule path set is already known from
`.gitmodules`, each outer-status line is classified: a path in the set is a
dirty-submodule rollup signal, anything else is a file code. The tree rolls a
commit-diverged submodule up into all its ancestor directories, so a collapsed
folder shows a dirty marker for a bumped nested submodule immediately, at zero
added cost. The picker filters these gitlink lines out of its file list, since the
path is a folder.

### Tier 1: lazy, visible rows only

This is the branch-and-status feature above. `config.repo_status` resolves branch
plus working-tree dirty count for each visible submodule row, upgrading its marker
to reflect working-tree dirt the moment the row is on screen.

### Tier 2: background, cached, incremental

`config.submodule_status` runs `git status` inside each submodule to catch
working-tree-only dirt (same HEAD, uncommitted edits) that Tier 0 cannot see.
Results are cached per submodule, keyed by `HEAD sha + .git/index mtime`. The scan
runs to completion once on a cold open, non-blocking and progressive, and the tree
reloads as rollups fill in. On later focus or refresh, only submodules whose HEAD
or index actually changed re-run, so steady-state cost is near zero instead of the
old per-focus storm. The picker reuses this exact cache, so one computation feeds
both consumers.

### Fidelity

| Change class | Fidelity | Latency |
| --- | --- | --- |
| Outer-repo files and folder rollups | full | instant (one status) |
| Commit-diverged submodule, any depth, even collapsed | full | instant (Tier 0) |
| Working-tree-dirty submodule, visible row | full | instant (Tier 1) |
| Working-tree-dirty submodule, collapsed or nested | full | progressive cold, instant once cached (Tier 2) |
| Per-file codes inside an expanded submodule | full | on expand, from the Tier 2 cache |

## Caching and invalidation

The cheap building block is `util.git.index_key`, a spawn-free read of a repo's
git index mtime. It state-keys both the `repo_status` per-directory cache and the
`submodule_status` cache. On `FocusGained`, `refresh_labels` revalidates each entry
with a stat only and keeps unchanged submodules, instead of dropping everything and
re-resolving. The definitive signals still force a hard flush: `HeadChanged`,
`ReviewBaseChanged` for the cwd, and the manual `<leader>gR`. In-session edits
under a submodule path invalidate that submodule's Tier 2 entry through the
filesystem watcher.

The event wiring lives in `config.nvim_tree_git.register_autocmds`:

- `FocusGained` revalidates the outer status (one spawn) plus the state-keyed
  entries, with no blind re-scan.
- `HeadChanged` and `ReviewBaseChanged`, scoped to the cwd root, behave as before,
  and the Tier 2 cache absorbs the unchanged submodules.
- Filesystem-watcher churn under a submodule targets that submodule's entry.
- `<leader>gR` hard-flushes every cache.

### Known staleness window

A submodule with unstaged working edits only (same HEAD, nothing staged), not
currently visible, changed externally since the last scan, will not auto-refresh:
its `.git/index` mtime does not move, so the Tier 2 state key stays valid until you
touch it, expand to it, or hit `<leader>gR`. In-session edits are caught by the
filesystem watcher. Setting `core.fsmonitor` and `core.untrackedCache` in git
config helps as an accelerator, but neither is required.

## Why per-file laziness is not the win

Skipping the scan of collapsed submodules entirely cannot satisfy the full-rollups
requirement. A collapsed, working-tree-dirty submodule can only get its rollup
marker by scanning it, and git offers no cheaper way, so skipping the scan would
drop exactly the fidelity the workspace view exists to provide. Per-file laziness
would only skip parsing already-scanned lines for collapsed nodes, a few
microseconds of Lua, not the expensive part (the git spawns), which nvim-tree
already skips rendering.

The architecture is therefore the achievable optimum. A cold open costs one outer
status plus one bounded background scan of all submodules, the irreducible cost of
full working-tree fidelity, cached. Every later focus is near-zero, re-scanning
only submodules whose index moved, and the recurring per-focus spawn storm is gone.
One further lever, gating the outer status refresh on the outer repo's `index_key`
too, is left unused: it would trade live pickup of bare external edits for a wider
staleness window, and the current balance (a 500 ms TTL, the filesystem watcher,
and `<leader>gR`) already keeps status fresh at near-zero steady-state cost.

## Module boundaries

- **`config.repo_status`** (generic, nvim-tree-free) owns the async branch/status
  resolver, the per-directory cache with its `index_key` state, and the
  `RepoStatusChanged` event. Consumed by the root header and the submodule
  decorator.
- **`config.submodule_status`** owns the per-submodule codes cache, the state key,
  the bounded incremental scan, and targeted invalidation. It knows nothing about
  nvim-tree and fires a `User` event on completion. Consumed by `nvim_tree_git`
  and `telescope_smart`.
- **`config.nvim_tree_submodule`** is the `after`-placement decorator that renders
  each visible submodule's segments.
- **`config.nvim_tree_git`** unions the outer-repo file codes with the
  dirty-submodule set for rollups, memoizes the ancestor-marker walk by the codes
  cache identity, and requests a submodule's Tier 2 scan on expand.
- **`config.telescope_smart`** delegates per-submodule statuses to
  `submodule_status`, runs its outer status with `--ignore-submodules=dirty`, and
  splits gitlink lines from file lines against the submodule set.

## Edge cases and scope

Intended behaviors:

- **cwd not a git repo:** the root label is the plain basename, the submodule set
  is empty, the decorator is inert. No spawns.
- **plain repo, no `.gitmodules`:** the root status shows and the submodule set is
  empty, so single-repo buffers get a branch/status root header for free.
- **detached HEAD, root or submodule:** `git describe --tags --always` yields the
  tag or a short sha; the full-name float shows a long ref in full.
- **uninitialized or nested submodules:** the enumerator's `fs_stat` gates exclude
  uninitialized ones and recurse into nested ones, each labeling when visible.
- **no upstream:** ahead/behind are omitted rather than shown as `↑0 ↓0`.
- **unborn HEAD:** the branch name may still resolve, `describe` fails, and the
  render falls back to branch-or-nothing without crashing.
- **200-submodule workspace:** one spawn for the root, and one spawn only per
  submodule whose row you expand into view.

Out of scope:

- **Per-submodule review base** (the `b` "changed since base" codes). The
  `base...HEAD` diff is computed only for the outer repo, so a submodule's "changed
  since base" is not derivable; only its working-tree state is.
- **Instant submodule repaint** via per-submodule HEAD watchers. External
  submodule checkouts repaint on the next `FocusGained` or `<leader>gR`, consistent
  with the statusline and gitsigns. A watcher lifecycle for buffer-less submodule
  roots is a possible follow-up.

## Where the code lives

`lua/config/repo_status.lua`, `lua/config/submodule_status.lua`,
`lua/config/nvim_tree_submodule.lua`, and `lua/config/nvim_tree_git.lua`, wired in
`lua/plugins/nvim-tree.lua`. Unit specs cover the pure parse and derive functions
(status parsing, rollup derivation, state-key equality); an e2e spec drives a real
loaded nvim-tree over a fixture superproject to pin the root branch, distinct
submodule branches, a detached ref, the root ignoring submodule dirt, and the lazy
guarantee that a collapsed submodule is not resolved until its row is visible. Run
with the sandbox disabled.
