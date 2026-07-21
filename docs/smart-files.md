# Smart file picker (`<leader><leader>`)

`<leader><leader>` opens the "Files (changed first)" picker
(`config.telescope_smart.smart_files`). It is the default file finder for this
config, tuned to stay fast on very large projects, including superprojects with
hundreds of git submodules.

## What it does

Each press fans out two async jobs and waits for both:

1. `refresh_codes_async` resolves git status for the whole tree: one
   `git status` on the outer repo, an optional `base...HEAD` diff, and a
   per-submodule status pass across every initialized submodule.
2. `_list_all_async` runs a full `rg --files` walk.

The results merge with changed files first (sorted), then the rest of the walk,
deduped. A Telescope picker opens over the merged list with a patched
`gen_from_file` entry maker that prefixes every row with its two-character git
status (`A `, `M`, `D`, `R`, `?`, and a `b` column for "changed since review
base"). Unchanged files carry a blank prefix so the column lines up on every row.

Two behaviors are load-bearing and must survive any change here: the
changed-files-first ordering at an empty prompt, and the status prefix column on
every row.

## The performance problem

The picker felt slow to open on superprojects, and worse the more submodules the
repo had. Measurements on synthetic repos (macOS, SSD, warm cache) isolated the
cause.

A flat 20,000-file repo with no submodules already opens fast. Git status runs in
about 30 ms and the walk in about 28 ms, and those run in parallel. Telescope
itself is not the bottleneck: it only realizes `display()` for the roughly 250
visible rows, and the static finder yields to the event loop every 1000 entries,
so the full-tree render cost never lands on open.

The submodule case was different:

| Step (200 submodules, ~20k files total) | Time |
| --- | --- |
| `git submodule status --recursive` (discovery) | 6.5 to 7.4 s |
| outer `git status` (whole repo) | 75 ms |
| per-submodule `git status` × 200, pooled | ~280 ms |
| `rg --files` walk | 33 ms |
| End-to-end | ~7.3 s |

About 96% of the open time was a single command: `git submodule status
--recursive`. It spawns a subprocess per submodule to resolve each submodule's
HEAD plus a `git describe`, and the picker discards everything except the path.
Warm and cold timings matched, so the cost is fork and CPU bound, not disk bound.

## The fix: cheap submodule discovery

Git status resolution has two phases. Discovery answers "which submodules exist";
the per-submodule status pass answers "what changed inside each one." The
per-submodule pass was already cheap. The outer status keeps git's built-in
submodule scan off, since git runs that scan serially in-process at about 1.96 s
for 200 submodules, and the config fans out its own bounded, pooled per-submodule
status instead, about 280 ms at 200. Only discovery was pathological, and it threw
away almost everything it computed.

Discovery now reads each directory's `.gitmodules` declaration instead of running
`git submodule status`. The walk is recursive and gated by two filesystem stats:

```
discover(dir, prefix, emit):
  for each path p declared in dir/.gitmodules:
      sub := dir/p
      if fs_stat(sub/.git):              # skip uninitialized submodules
          emit(prefix .. p)
          if fs_stat(sub/.gitmodules):   # recurse only into nested superprojects
              discover(sub, prefix .. p .. "/", emit)
```

Each directory's declaration comes from one `git config --file <dir>/.gitmodules
--get-regexp '^submodule\..*\.path$'` spawn, which reads only `.gitmodules` and
never scans the index or tree. For a flat 200-submodule superproject that is one
`git config` call plus 200 stat checks that all miss, so recursion never fires.
Nested submodules recurse with another cheap `.gitmodules` read, preserving the
`child/grandchild` paths the old `--recursive` produced. The recursive reads run
through a bounded drain capped at `SUBMODULE_CONCURRENCY` so a deeply nested tree
cannot fork-bomb.

On a real 200-submodule superproject this took discovery from 7363 ms to 7.2 ms,
and end-to-end `_recursive_changes_async` from 7309 ms to 392 ms, about 18.6×.

### Adaptive concurrency

`util.pool.GIT_CONCURRENCY` scales the per-submodule fan-out to the machine
instead of a fixed 8:

```lua
M.GIT_CONCURRENCY = math.max(4, math.min((vim.uv.available_parallelism() or 8) - 2, 24))
```

The floor of 4 keeps low-core machines parallel; the cap of 24 avoids a fork
storm on large boxes. It is computed once at module load, since core count is
stable per session, and it is shared by both the submodule status fan-out and
`config.ignore_filter`'s check-ignore oracle. At 200 submodules the fan-out drops
from about 280 ms at 8 to about 150 ms at 16.

### Known limitation: declaration vs index

Discovery reads the `.gitmodules` working-tree declaration, whereas `git
submodule status` enumerates gitlinks from the index. In a healthy superproject
`git submodule add` keeps the two in sync, so real divergence is nil. The one
concrete gap is a gitlink that is present in the index and checked out on disk but
not declared in `.gitmodules`, a broken or transitional state. Such a submodule is
silently skipped, and files inside it render without their in-submodule status
prefixes, because the outer status does not descend into a submodule the discovery
step never found. This is an accepted limitation for the picker's purpose; the
`fs_stat(.git)` gate and the real-git integration tests cover the healthy case.

## The loading float

Cheap discovery removed the multi-second stall, but a residual wait remains on
cold git caches, very large submodule counts, and slow filesystems, where even the
cheap fan-out grows into seconds. A debounced "Loading changes…" badge covers that
wait so it never reads as a freeze.

The badge is a one-line, non-focusable float anchored bottom-center, mounted on
its own `util.overlay` instance (a float rather than a swapped picker title, which
would no-op on the borderless layout and cannot show before the picker exists). It
arms a debounce timer at the start of each press and mounts only if the picker has
not opened by the time the timer fires (150 ms). It dismisses the moment the
picker opens, which covers the whole `max(git, walk)` wait. When the whole
preparation finishes under the 150 ms debounce, as on a flat repo or a small warm
one, the badge never appears. On a large superproject it does show: a headless run
against the 200-submodule repo mounted the badge at 150 ms and cleared it when the
picker opened about 600 ms later. The debounce exists to catch those genuinely slow
opens; fast opens finish before it fires.

Several details are load-bearing and each fixed a real bug found in review:

- **Its own overlay instance.** `Overlay:mount` self-closes any prior mount on the
  same instance. Sharing the git-status legend's overlay would make the legend and
  the badge evict each other, so the badge gets a fresh `Overlay.new()`.
- **One reused, lazily created timer.** The module keeps a single `vim.uv` timer,
  reused across presses with `stop()` then `start()`. It is never allocated
  per-press (per-call handles accumulate across a session), never `close()`d on
  dismiss (that makes the next `start()` throw), and created lazily on first use so
  merely requiring the module allocates no libuv handle and the test harness's
  module reloads strand none. This is exactly the handle-leak class the
  [leak audit](leak-diagnostics.md) chased.
- **Stale-check before close.** Each press bumps a generation token. A callback
  whose generation is no longer live is a pure no-op that never touches the shared
  overlay, so a superseded press can never close a newer press's badge. The close
  is otherwise unconditional for the current generation, so the zero-changes and
  degraded-timeout paths still dismiss.
- **Arm before kick.** `refresh_codes_async` calls back synchronously when the cwd
  is not a repo, so the timer is armed before the async jobs start; the press state
  exists when a synchronous callback runs.

The race logic reduces to a pure `load_guard(my_gen, live_gen, opened)` predicate
returning `{ mount, dismiss }`, which is unit-tested as a matrix with no async.

## Considered and declined: a streaming finder

A third option was to open the picker as soon as git resolves and stream the `rg`
walk in behind the changed files, using a hand-rolled finder instead of waiting
for the full walk. It was declined.

Its value is narrow. On the submodule case git status dominates the 33 ms walk, so
opening at git-resolve saves almost nothing; the real benefit is only on flat,
huge, or cold-filesystem repos where the walk itself takes hundreds of ms. It also
carries the effort's one behavior change: typing while the walk is still streaming
transiently filters an incomplete set, which self-heals when the walk finishes but
never happened with the fully materialized list. Since the stated pain was the
many-submodule open, which cheap discovery and the loading float already solve,
the streaming path was not worth its complexity or its behavior change.

One caveat for anyone who revisits it: Telescope's stock `async_oneshot_finder`
has an inverted `% await_count` yield guard that yields on every iteration rather
than every 1000th (in Lua a nonzero modulo result is truthy). A streaming finder
would need a corrected copy with `% 1000 == 0`, not the vendored version.

## Where the code lives

- `lua/config/telescope_smart.lua` holds `smart_files`, the async git and walk
  fan-out, submodule discovery, the merge, and the loading float.
- `lua/util/pool.lua` holds the adaptive `GIT_CONCURRENCY` bound.
- Tests: `tests/spec/unit/telescope_smart_spec.lua`,
  `tests/spec/unit/pool_spec.lua`, and the `<Space><Space>` case in
  `tests/spec/e2e/telescope_spec.lua`, which pins the prefix column on both
  changed and unchanged rows. Run the suite with the sandbox disabled; the
  fixtures do real git writes.
