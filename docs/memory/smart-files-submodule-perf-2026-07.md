---
type: memory
title: "Smart-files submodule perf 2026-07"
kind: project
description: "<leader><leader> slow-open on many-submodule superprojects — discovery (git submodule status --recursive) is the ~7s pole; fix + design/plan docs."
---

# Smart-files submodule perf 2026-07

`<leader><leader>` (config.telescope_smart.smart_files) is slow to OPEN on
superprojects with hundreds of submodules. Measured on a synthetic 200-submodule /
20k-file repo (2026-07-13): end-to-end open ~7.3s, of which **~7.4s is a single
command — `git submodule status --recursive`** (the submodule *discovery* step). It
spawns a subprocess per submodule to resolve a SHA + `git describe` that the code
throws away (only the path column is used). Warm≈cold (fork/CPU-bound). Everything
else is noise: outer `git status --ignore-submodules=all` 75ms, per-submodule status
fan-out ~280ms (pool of 8), `rg --files` walk 33ms.

**Flat repos are NOT the problem:** at 20k files with no submodules, git status and rg
are ~30ms each and telescope already chunks entry-building — the 366ms "realize all
displays" never hits (only ~250 visible rows realize; entry_manager short-circuits).

**Fix (measured):** replace discovery with a cheap per-directory `.gitmodules` read —
`git config --file <dir>/.gitmodules --get-regexp '^submodule\..*\.path$'` (0.00s) or
`git ls-files --stage` gitlinks mode 160000 (0.01s) — recursing only where a submodule
has its own `.gitmodules` (fs_stat gate), skipping uninitialized (fs_stat `<sub>/.git`).
Takes 200-submodule open ~7.3s → ~0.3s (≈20×). Also make `util.pool.GIT_CONCURRENCY`
(was 8) adaptive: `max(4, min(available_parallelism()-2, 24))`.

Design + plan live in the repo (user prefers docs/, untracked): `docs/smart-files-perf-design.md`
(3 levers: P1 discovery fix = the win; P2 debounced "Loading changes…" float; P3
optional streaming finder) and `docs/smart-files-perf-plan-p1-discovery.md` (TDD tasks).
**P1 SHIPPED (2026-07-14, merged to main, ff 3c57d3f..104298c):** parse_config_values + gated
recursive submodule_paths_async (cheap `.gitmodules` reads, bounded drain); parse_submodule_status
removed; GIT_CONCURRENCY adaptive. Verified 200-submodule E2E 7309ms→392ms; unit 437/0/0 + e2e
59/0/0 green. **P2 SHIPPED (2026-07-14, merged to main, ff 104298c..3aa7e37):** debounced "Loading changes…"
float (`docs/smart-files-perf-plan-p2-loading-float.md`, 3 commits). Pure `_load_guard(my_gen,live_gen,opened)
-> {mount,dismiss}` predicate carries the race; OWN Overlay instance (separate from `legend`); ONE debounce
timer created **lazily** via `loading_timer()` accessor (NOT `vim.uv.new_timer()` at module scope — that
stranded a handle on every test reload; caught in review); armed BEFORE the async kicks (not-a-repo cb is
sync); dismiss inside `maybe_open` (picker-open, not git-resolve) gen-guarded before touching the shared
overlay. Verified headless vs a real superproject with hundreds of submodules: float mounts at 150ms during the genuine wait,
picker opens ~613ms, dismisses on open; unit 441/0/0 + e2e 59/0/0. Known follow-up (plan-sanctioned, opus
final review): the `smart_files()` WIRING has no committed CI test (only the primitives) — seams aren't
cleanly injectable, so covering it needs a testability-only production change or a flaky real-timer test.
**Part A (P2 wiring-test quick win) SHIPPED (2026-07-14, merged ff to main 3aa7e37..474c843).** Closed the
one P2 gap (float PRIMITIVES were tested; the COMPOSITION in smart_files() was not). Behavior-neutral seam:
export `M._open_picker`, route smart_files' open through `M._open_picker` + the already-exported
`M._refresh_async` (call at :816). 4 synchronous wiring tests (no telescope, no real 150ms timer) —
seam-routing/does-not-open-sync, dismiss-on-open (gate-on-both), fire-once, gen-guarded-dismiss (stale press
never closes newer float) — EACH **mutation-verified** to go RED when its guard breaks. Full unit+smoke+e2e
(incl. `<Space><Space>` prefix contract) green, +85/-2 additive. Teardown cancels the armed debounce via
`M._loading_timer():stop()` in restore_fn.

**P3 (streaming finder) DECLINED by user (2026-07-14) — the handoff's own sanctioned "legitimate finding."**
Rationale: the user's pain is the many-submodule open, already solved ~18.6× by P1+P2; P3's value is only
flat/huge-walk non-submodule repos and it carries the transient incomplete-filter behavior change. Full
handoff remains at `docs/smart-files-perf-handoff-p3.md` (verified vs HEAD 3aa7e37, adversarially fact-checked)
if ever revisited — the exported `M._open_picker` seam is the groundwork P3's `stream` branch would build on.
P3 gotchas (verified): stock async_oneshot_finder STILL has the inverted yield guard `if x % await_count then`
at :69 AND :90 (await_count=1000 :7) → ~20k schedules/tree — ship a CORRECTED COPY, fix both. Seeds-first
ordering rests on feed-order + empty-prompt score==1 (entry_manager tiebreak :140 gated on score<1, never
reached), NOT entry.index (design §7 misconception — corrected in handoff §8); a score-0 sorter would break it.
4th finder:close() site at pickers.lua:1685 beyond design's :1033/:1625/:1663 — close() must be idempotent.
WALKER_TIMEOUT_MS(10s, :234) NOT inherited when the walk moves into the finder — re-add a close() timer.
P3 is OPTIONAL (near-nil value on the submodule case; one accepted behavior change: typing mid-stream filters
an incomplete set, self-heals on walk complete) — dropping it is a legitimate finding, and the user did
(above). **The whole smart-files-perf effort is now DONE for this user: P1+P2 shipped, Part A shipped, P3 declined.**

Related: [[multi-submodule-perf-changes]] [[multi-submodule-plan]] [[nvim-tests-need-sandbox-disabled]]
Benchmark harness this session: build_submodules.sh + bench_sub.lua in a throwaway temp dir (200 submodules).
