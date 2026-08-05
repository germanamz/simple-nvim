# Git at scale: multi-submodule support

This config is used on superprojects: monorepos with a few, or a few hundred,
git submodules over tens of thousands of files, polyglot. Naive git integration
is unusable there — a project-wide `git submodule status --recursive` alone
spawns one process per submodule and takes seconds.

The hardening was done in eight stages plus a recursion stage, each independently
green. What follows is what the config now guarantees, how, and what it
deliberately does not do.

User-facing behavior lives in [`../smart-files.md`](../smart-files.md) (the
`<leader><space>` picker) and [`../nvim-tree-git.md`](../nvim-tree-git.md) (branch
and status in the file tree). This document is the engineering side.

## What each stage bought

| Stage | Guarantee | Pinned by |
| --- | --- | --- |
| P1 | `util.git` resolves each submodule, grandchild, linked worktree and unborn repo to its own toplevel and gitdir | `submodule_spec.lua` |
| P2 | `git.buf_root` scopes per buffer; `review_base.diff_range` follows the focused submodule | `submodule_spec.lua`, `review_base_spec.lua` |
| P3 | The HEAD watcher is gated on the resolved object id, not the branch name, so a **detached commit move** (`git submodule update`) is detected | `git_head_spec.lua` |
| P4 | `git.buf_in_root` is exact equality; event refresh is scoped to the changed root instead of fanning out to every buffer | `submodule_spec.lua`, `statusline_spec.lua` |
| P5 | `git.run` is time-bounded and no longer merges stderr into stdout; HEAD watchers are evicted by buffer lifecycle and on fs-event errors | `util_git_spec.lua`, `git_head_spec.lua` |
| P6 | HEAD resolution is asynchronous — no main-thread git on that path — with single-flight and recheck | `util_git_spec.lua`, `git_head_spec.lua` |
| P7 | Review bases are validated lazily on first read; no startup sweep, so launch cost is submodule-count-independent | `review_base_spec.lua` |
| P8 | Directory-keyed caches are invalidated on a cwd or `.gitmodules` change | `dir_cache_spec.lua` |
| Recursion | Per-file git status **inside** submodules, in both pickers and the tree | `telescope_smart_spec.lua`, `nvim_tree_git_labels_spec.lua` |

## The machinery

- **`lua/util/git.lua`** — the whole shellout surface. `run` bounds every call at
  `TIMEOUT_MS = 2000` via `vim.system():wait(ms)` and returns
  `lines, ok, timed_out`, so a caller can tell a transient hang from a real git
  error. `buf_root` / `buf_in_root` do the per-buffer scoping. `head` /
  `parse_head` share one parse between the sync and async paths.
  `index_key(dir)` is the state key that lets a status cache skip an unchanged
  submodule.
- **`lua/config/git_head.lua`** — one `fs_event` watcher per root, gated on the
  resolved sha. Single-flight with recheck, so a burst of writes collapses into
  one resolve. `unwatch` scans open buffers and evicts a root's watcher when its
  last buffer is wiped; an fs-event error tears the handle down. Live handles are
  therefore proportional to *submodules with an open buffer*, not submodules
  visited.
- **`lua/config/submodule_status.lua`** and **`lua/config/repo_status.lua`** — the
  per-submodule status and branch caches, keyed by index mtime, shared by the
  picker and the tree so a submodule is scanned once and read twice.
- **`lua/config/dir_cache.lua`** — clears the directory-keyed caches (`util.git`'s
  root cache, conform's pyproject cache, `ignore_filter`'s oracle,
  `js_toolchain`'s formatter/linter map) on `DirChanged` and on writing
  `.gitmodules`. It only clears; the next resolve re-probes.
- **`lua/config/telescope_smart.lua`** — the recursion: cheap `.gitmodules`
  discovery instead of `git submodule status --recursive`, then per-submodule
  status through `util.pool`.
- **`lua/config/gitsigns_base.lua`** — keeps gitsigns' single global base
  (`config.base`) unset and gives each attached buffer the review base of its
  *own* root instead, via `change_base(ref, false)` under `nvim_buf_call`. The
  global base is not only a diff base: gitsigns passes it to
  `git blame <revision>`, so a superproject base leaking into a submodule buffer
  made the current-line blame name whoever last touched the line on that ref —
  a squash or merge commit — instead of the line's real author. A base change
  re-bases that root's buffers only (exact `git.buf_in_root` equality).
- **`lua/config/gitsigns_blame.lua`** — makes blame answer "who wrote this line"
  rather than "who last touched this file", on two axes.

  Everywhere, it passes `-C -C` so blame follows lines back through moves and
  copies. Plain `git blame` stops at the commit that put a line in *this* file,
  so a file created by lifting code out of another one credits the extraction
  for every line it moved — a 435-line test file in one repo blamed entirely on
  its extraction commit, versus eleven real authoring commits with `-C -C`. The
  flags are injected in `Obj:run_blame`, not in `current_line_blame_opts`,
  because the per-buffer blame cache is not keyed by opts: whichever path ran
  first — the eol label, `<leader>hb`, the blame window — would otherwise fix
  the flags for all of them.

  With a review base it additionally blames from the buffer's own history, by
  patching the two places the base reaches blame: the `<revision>` argument, and
  `CacheEntry:get_blame`'s short-circuit that calls every hunk line "Not
  Committed Yet" (against a base, that is all of your branch's committed work).
  That half is scoped by the `git_obj._review_base` tag, so a `gitsigns://`
  buffer showing a historical revision still blames from that revision. Hunks
  and signs keep following the base.

### Bounds

- **Concurrency** is `util.pool.GIT_CONCURRENCY`:
  `clamp(available_parallelism() - 2, 4, 24)`. The original design fixed it at 8;
  it now scales with the machine.
- **Per-process timeout** is 2000 ms, matching `util.git`'s bound. A hung
  submodule degrades to "no labels for that one" rather than wedging the pool.
- **Recursion is skipped entirely when there is no `.gitmodules`** — one `fs_stat`,
  so ordinary single repos pay nothing.
- **Startup is submodule-count-independent** (P7).

## Deliberate non-goals

Do not file these as bugs.

- **Review-base diff is outer-repo-only.** The `b`-prefixed "changed since base"
  codes apply to the outer repo. Submodules contribute worktree codes (`A`, `M`,
  `D`, `?`, with the `*` unstaged marker) but no `b` codes, because `review_base`
  is keyed by the outer toplevel and a submodule's "changed since base" is
  ill-defined.
- **`dir_cache` does not see external shell changes.** A `git submodule
  add/deinit/init` run outside the editor fires neither `DirChanged` nor a
  `.gitmodules` write. `<leader>gR` clears the same caches as the manual hatch.
- **One unnamed-buffer watcher is never reaped.** The lifecycle autocmd skips
  empty buffer names, so the cwd-root watcher an unnamed buffer seeds stays alive.
  One handle, kept alive by any named sibling.
- **nvim-tree's own git scan and LSP-per-root** are separate concerns, addressed
  elsewhere (see [`../nvim-tree-git.md`](../nvim-tree-git.md) and
  [`../lsp-typescript-version.md`](../lsp-typescript-version.md)).

## Verifying by hand

The suite uses synthetic fixtures. To check the actual UX, build a throwaway
superproject with a grandchild submodule:

```sh
WORK=$(mktemp -d); cd "$WORK"
mk(){ git init -q "$1" -b main; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }
mk gc;    echo 1 > gc/g.txt;    git -C gc add -A;    git -C gc commit -qm c1
mk child; echo 1 > child/c.txt; git -C child add -A; git -C child commit -qm c1
git -C child -c protocol.file.allow=always submodule add -q "$WORK/gc" grand
git -C child commit -qm addgc
mk parent; echo 1 > parent/p.txt; git -C parent add -A; git -C parent commit -qm c1
git -C parent -c protocol.file.allow=always submodule add -q "$WORK/child" childA
git -C parent commit -qm addchild
git -C parent -c protocol.file.allow=always submodule update --init --recursive -q
# dirty some files INSIDE the submodules
echo changed > parent/childA/c.txt
echo new     > parent/childA/new.lua
echo gnew    > parent/childA/grand/g.txt
cd parent && nvim .
```

Then, in that Neovim:

| # | Action | Expected |
| --- | --- | --- |
| 1 | Open `p.txt`, then `childA/c.txt` | The statusline branch and base reflect each file's own submodule — `childA` shows `childA`'s branch, not the parent's |
| 2 | `<leader><space>` | Files *inside* submodules carry porcelain prefixes: `childA/c.txt` → `M*`, `childA/new.lua` → `?*`, `childA/grand/g.txt` → `M*`. The submodule itself is not one bogus `childA` row |
| 3 | `<leader>e`, expand `childA` then `childA/grand` | Inner files carry the same labels; both directories carry the `•` subtree-change marker |
| 4 | With `childA/c.txt` focused: `<leader>gB` pick a base, then `<leader>gv` | The base is set on **childA's** repo and the diff is childA-vs-its-base |
| 5 | From another terminal, `git -C parent/childA checkout -q <other-commit>`, then refocus nvim (or `<leader>gR`) | childA's statusline and labels update — the watcher noticed a commit move with no branch change |
| 6 | `git -C parent submodule update --init` after changing a recorded submodule commit | Same detached SHA-to-SHA detection (this is the P3 fix; the pre-P3 code was blind to it) |
| 7 | `git -C parent submodule deinit -f childA`, then edit `.gitmodules` in nvim or press `<leader>gR` | The directory caches flush and roots re-resolve (P8) |

Steps 2 and 3 are the headline feature. Steps 5 and 6 prove the sha-gated async
watcher.
