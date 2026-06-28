# Multi-Submodule Support — Verification Handoff

**Branch:** `feat/multi-submodule` (14 commits on top of `main`, **not** merged or pushed)
**Status at handoff:** lint + unit + smoke + e2e all green; working tree clean.
**Goal of the work:** make this Neovim config robustly support superprojects with a
few OR hundreds of git submodules (polyglot), without freezing the UI or leaking
resources.

This document is a self-contained guide to **verify** that work. You do not need
prior context — everything needed is below.

---

## 0. Setup (do this first)

```bash
git checkout feat/multi-submodule
make warm          # restore pinned plugins/parsers/mason tools into the cache
```

**Two environment caveats — both already handled, but know them:**

1. **Run tests with the sandbox DISABLED.** The suites do real `git init/checkout`,
   parser writes, and swap/state writes. Under a restrictive sandbox they fail with
   environment errors (swap/parser/git), not logic errors. If you're in an agent
   harness with a command sandbox, turn it off for the `make test-*` commands.
2. **ShaDa is disabled in the harness on purpose.** Both `tests/minimal_init.lua`
   and `tests/full_init.lua` set `vim.o.shadafile = "NONE"` so buffer-loading specs
   don't touch (or fail on) the user's real ShaDa. This is intentional — don't
   "fix" it.

---

## 1. Automated verification

Run the full suite:

```bash
make lint          # stylua --check ; expect exit 0
make test-unit     # plenary-only ; expect exit 0
make test-smoke    # full init, no real LSP ; expect exit 0
make test-e2e      # full init, real plugins/parsers ; expect exit 0
```

**All four should exit 0.** Per-file totals print `Success: N / Failed: 0 / Errors: 0`.

### Known flake (not a real failure)
`make test-e2e` (and occasionally `make test-smoke`) can **exit 2 while every test
passes** (`Failed: 0` on every file). This is a pre-existing harness artifact: a
child nvim occasionally exits nonzero on a documented `:bdelete` `E89` ("No write
since last change", which `lua/config/buffers.lua` intentionally keeps "loud") or a
shutdown error. **Re-run — it goes to exit 0.** Confirm a real failure by looking
for a nonzero `Failed:`/`Errors:` total, not just the process exit code:

```bash
make test-e2e 2>&1 | grep -E "Failed : |Errors : " | grep -vE ": .0[[:space:]]*$"
# empty output = no real failures
```

### What proves what (stage → tests)

| Stage | Behavior verified | Spec file → `describe` |
|---|---|---|
| P1 | util.git resolves each submodule / grandchild / worktree / unborn to its own toplevel & gitdir | `tests/spec/unit/submodule_spec.lua` → *multi-submodule (util.git in a superproject)* |
| P2 | `git.buf_root`; `review_base.diff_range` scoped to the focused submodule | `submodule_spec.lua` → *git.buf_root*; `review_base_spec.lua` → *diff_range* |
| P3 | `git.head` {sha,branch}; watcher fires on a **detached commit move** (`git submodule update`) | `util_git_spec.lua` → *head*; `git_head_spec.lua` → *watch* (“fires when a detached HEAD moves between commits”) |
| P4 | `git.buf_in_root` exact equality; event refresh scoped to `data.root` | `submodule_spec.lua` → *git.buf_in_root*; `statusline_spec.lua` → *event fan-out scoping* |
| P5 | `git.run` timeout + stderr separation; HEAD watcher eviction (buffer-scan) + fs-error reap | `util_git_spec.lua` → *run*; `git_head_spec.lua` → *unwatch* / *lifecycle* |
| P6 | async HEAD check (no blocking `git.head`); single-flight + recheck | `util_git_spec.lua` → *parse_head*; `git_head_spec.lua` → *async check* |
| P7 | review bases validated lazily on first read (no startup sweep) | `review_base_spec.lua` → *lazy validation (M.get)* |
| P8 | dir-keyed caches invalidated on cwd / `.gitmodules` change; wikilinks non-merge | `dir_cache_spec.lua`; `boot_spec.lua` (wiring); `wikilinks_spec.lua` → *_project_root* |
| RECURSION | per-file status **inside** submodules in pickers; tree label on inner file | `telescope_smart_spec.lua` → *_parse_submodule_status / _has_submodules / _run_pool / _submodule_paths_async / _recursive_changes_async / _refresh_async*; `nvim_tree_git_labels_spec.lua` → *labels a file inside a submodule* |

Spot-check one stage's tests by name, e.g.:

```bash
make test-unit 2>&1 | grep -iE 'async check|unwatch|lifecycle|_recursive_changes_async'
```

---

## 2. Manual verification in a real superproject

The automated tests use a synthetic fixture. To verify the **actual UX**, build a
real superproject and open Neovim in it.

### 2a. Build a throwaway superproject

```bash
WORK=$(mktemp -d); cd "$WORK"
mk(){ git init -q "$1" -b main; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }
# a grandchild, a child that contains it, and a parent superproject
mk gc;    echo 1 > gc/g.txt;    git -C gc add -A;    git -C gc commit -qm c1
mk child; echo 1 > child/c.txt; git -C child add -A; git -C child commit -qm c1
git -C child -c protocol.file.allow=always submodule add -q "$WORK/gc" grand
git -C child commit -qm addgc
mk parent; echo 1 > parent/p.txt; git -C parent add -A; git -C parent commit -qm c1
git -C parent -c protocol.file.allow=always submodule add -q "$WORK/child" childA
git -C parent commit -qm addchild
git -C parent -c protocol.file.allow=always submodule update --init --recursive -q
# dirty some files INSIDE submodules
echo changed > parent/childA/c.txt
echo new     > parent/childA/new.lua
echo gnew    > parent/childA/grand/g.txt
cd parent && nvim .
```

### 2b. Checklist (in that nvim)

| # | Action | Expected |
|---|---|---|
| 1 | Open `parent/p.txt`, then open `childA/c.txt` | Statusline branch/base reflect **each file's own submodule** (childA shows childA's branch, not parent's) |
| 2 | `<leader><space>` (smart files / changed-first) | Files **inside** submodules show porcelain prefixes: `childA/c.txt` → `M*`, `childA/new.lua` → `?*`, `childA/grand/g.txt` → `M*`. The submodule itself is **not** shown as one bogus `childA` row. |
| 3 | `<leader>e` (nvim-tree), expand `childA` then `childA/grand` | The inner files carry the same labels; `childA` and `childA/grand` directories carry the `•` subtree-change marker |
| 4 | With `childA/c.txt` focused, `<leader>gB` → pick a base; `<leader>gv` (diffview) | The base is set on **childA's** repo and the diff is childA-vs-its-base — not the parent repo's |
| 5 | From another terminal: `git -C parent/childA checkout -q <some-other-commit>` (detached move), then return focus to nvim (or `<leader>gR`) | The statusline/labels for childA update — the watcher noticed a **commit move with no branch change** |
| 6 | From another terminal: `git -C parent submodule update --init` after changing a recorded submodule commit | Same: detached SHA→SHA move is detected (this is the P3 fix; the old code was blind to it) |
| 7 | External `git -C parent submodule deinit -f childA` (or add a new submodule) | After editing `.gitmodules` in nvim, or pressing `<leader>gR`, the dir-cache is flushed and roots re-resolve (P8) |

If steps 2 and 3 show per-file labels inside submodules, the headline feature
(RECURSION) is working. If step 5/6 update without reopening the buffer, the
sha-gated async watcher (P3+P6) is working.

---

## 3. Scale / resource verification (the "hundreds of submodules" claim)

The bounds are asserted in unit tests, but to sanity-check on real scale:

- **Bounded HEAD fs handles (P5):** open buffers across several submodules, then
  `:bd` them. The live `fs_event` handle set should shrink. Inspect from inside nvim:
  ```vim
  :lua local h=require('config.git_head'); print(vim.inspect(vim.tbl_keys(setmetatable({},{})))) " (handles are module-local; use _handle(root) per root)
  ```
  More practically: the eviction is covered by `git_head_spec.lua` → *lifecycle*
  ("evicts a root's watcher when its last buffer is wiped"). Trust that + the design:
  handles are proportional to **submodules with an open buffer**, not submodules visited.
- **No main-thread git on the HEAD path (P6):** a superproject-wide `git submodule
  update` should not freeze the editor. The HEAD resolve is async (`_resolve_head`).
- **Bounded recursion spawns (RECURSION):** the per-submodule status pool caps at
  **8 concurrent** processes (`SUBMODULE_CONCURRENCY`) with a **2s per-process
  timeout** (`GIT_TIMEOUT_MS`), and recursion is skipped entirely when there's no
  `.gitmodules` (one `fs_stat`). So a picker open over hundreds of submodules issues
  status in waves of 8, and a hung submodule degrades to "no labels for that one"
  rather than hanging the pool.
- **Startup cost is submodule-count-independent (P7):** review bases are validated
  lazily on first read, not swept at launch.

---

## 4. Known caveats / deliberate non-goals

These are **intentional** — don't flag them as bugs:

- **Base diff is outer-repo-only.** `bX` ("changed since base") labels apply to the
  outer repo; submodules contribute worktree codes (`A/M/D/?*`) but not `bX`.
  Rationale: `review_base` is keyed by the outer toplevel, so a submodule's
  "changed since base" is ill-defined. (RECURSION commit message documents this.)
- **gitsigns has a single global base.** Two submodules with different stored bases
  can't both be diffed against simultaneously by gitsigns (last `change_base` wins).
  Pre-existing plugin limitation, documented in `lua/plugins/gitsigns.lua`.
- **nvim-tree's own git scan and LSP-per-root** are out of scope (plugin-owned /
  separate concern); documented, not solved here.
- **Unnamed-buffer cwd-root watcher** isn't reaped by the lifecycle autocmd (it skips
  empty buffer names). One handle, kept alive by any named sibling; documented in
  `lua/config/git_head.lua`.
- **The e2e exit-2 flake** (§1) is pre-existing and unrelated.

---

## 5. Commit map (bisect points)

```
1a60399 Verify submodule-internal files are labeled in the tree end to end   (R3)
12af767 Aggregate per-file git status across submodules in the smart pickers (R1+R2)
e3fbc5f Document why wikilinks root resolution stays separate from git.root   (P8b)
86d011b Invalidate the dir-keyed caches on a topology change                  (P8a)
c2bd864 Validate review bases lazily instead of sweeping every one at startup (P7)
27ee565 Resolve HEAD asynchronously off the main thread                       (P6b)
f934fc3 Extract git.parse_head so sync and async HEAD resolution share parse  (P6a)
92dfe80 Evict HEAD watchers by buffer lifecycle and on fs-event errors        (P5a+b)
94193c5 Make the test harness hermetic with respect to ShaDa                  (infra)
020a2d4 Bound git.run with a timeout and stop merging stderr                  (P5c)
45ffece Add behavioral regression locks for the event fan-out scoping        (P4 tests)
b021d4d Scope the HEAD/review-base event fan-out to the changed root          (P4)
249d794 Gate the HEAD watcher on the resolved object id, not the branch name  (P3)
92993ea Scope review base to the focused submodule; add superproject fixture  (P1+P2)
```

Each commit is independently green (`git checkout <sha> && make test-unit`). If a
suite fails, `git bisect` over this range isolates the stage.

## 6. Key production files (what changed)

- `lua/util/git.lua` — `buf_root`, `buf_in_root`, `head`/`parse_head`/`HEAD_ARGS`,
  `run` (vim.system + timeout + clean stderr), `TIMEOUT_MS`.
- `lua/config/git_head.lua` — sha-gated async watcher, single-flight+recheck,
  `unwatch` (buffer-scan), `git_head_lifecycle` autocmd, fs-error teardown.
- `lua/config/statusline.lua` — resolves sha to seed the watcher; root-scoped
  `refresh_all_buffers`.
- `lua/config/review_base.lua` — `diff_range`; lazy validation; `bootstrap` removed.
- `lua/config/telescope_smart.lua` — the recursion: `parse_submodule_status`,
  `has_submodules`, `run_pool`, `submodule_paths_async`, `recursive_changes_async`,
  `apply_worktree_lines(prefix)`, `--ignore-submodules=all`.
- `lua/config/dir_cache.lua` — **new**; cache invalidation autocmds + `_clear` hatch.
- `lua/plugins/diffview.lua`, `lua/plugins/telescope.lua`, `lua/plugins/gitsigns.lua`,
  `lua/config/wikilinks.lua`, `lua/init.lua` — call-site wiring.

---

## 7. Verdict criteria

Consider the work verified when:
- [ ] `make lint && make test-unit && make test-smoke` all exit 0.
- [ ] `make test-e2e` exits 0 (re-run once if it hits the documented flake; confirm
      no nonzero `Failed:`/`Errors:` totals).
- [ ] Manual checklist §2b steps 2 and 3 show per-file labels inside submodules.
- [ ] Manual checklist §2b step 5 or 6 updates a submodule's display after an
      external detached-HEAD move without reopening the buffer.
