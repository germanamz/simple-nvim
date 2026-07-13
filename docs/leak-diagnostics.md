# CPU/memory runaway — findings & capture playbook (2026-07-06)

Incident: after ~1h of an interactive nvim session (editing ~/projects/snippetbox,
Go), ~96% CPU sustained across 3 processes and "400+ GB virtual memory".

## What the audit established

- **The 400 GB virtual memory is a red herring.** On Apple Silicon macOS every
  process shows ~435 GB VSZ (reserved address space, not real memory). Even
  WindowServer shows 437 GB. Watch **RSS** and **%CPU** only.
- **The identity of the 3 hot processes was never captured** — that is the
  missing evidence. Run step 1 below the moment it recurs.
- A 78-agent audit of all ~8.8k lines of config confirmed **no runaway
  loop/timer/watcher** that could sustain 96% CPU or ramp up after 1 hour.
  Every claimed hot loop was refuted or measured microscopic (e.g. block_guides
  recompute ≈ 1.1 ms/keystroke ≈ 1% CPU).

## Best current explanation (partial)

1. **Ollama runner** — minuet fires a FIM completion at qwen2.5-coder:7b about
   once per second while typing (`auto_trigger_ft = {"*"}`, throttle 1000ms /
   debounce 400ms / `--max-time 3` all verified working). A 7b prefill per
   second keeps the runner near 100% **by design**, only while typing, ceasing
   ~3s after the last keystroke. If the runner shows 96% **CPU** (not GPU),
   Metal offload failed — check `ollama ps` GPU column during the burn.
2. **gopls** — the "semantic_tokens: no package metadata" errors were a 2-second
   startup race (4 log lines, 08:30:09–11), not a loop. Neovim 0.12.3's
   semantic-tokens client does re-request after errored responses with no
   terminal error state (real upstream weakness), but the log refutes it as
   this session's burner. gopls's own background typechecking was never
   profiled.
3. **nvim itself** — no confirmed mechanism exceeds a few % CPU. If nvim was
   hot, `sample` it (step 2). An unconsidered trio: **nvim + Ghostty +
   WindowServer** (a redraw storm heats all three at once).

## Capture playbook (first 3 within a minute of noticing)

1. Name the processes — everything else was guesswork for lack of this:
   ```sh
   ps -Ao pid,ppid,pcpu,pmem,rss,etime,command -r | head -20   # x3, 10s apart
   ps -o ppid= -p <hot-pid>                                    # child of nvim?
   ```
2. Wall-clock profile each hot pid:
   ```sh
   sample <pid> 10 -file ~/sample-<name>.txt
   ```
3. Memory truth (does RSS actually grow?):
   ```sh
   while :; do date; ps -o pid=,rss=,pcpu= -p <p1>,<p2>,<p3>; sleep 60; done | tee ~/leak.log
   ```
4. Ollama: `ollama ps` (CPU vs GPU column) and
   `grep -c /v1/completions ~/.ollama/logs/server.log` per minute.
5. gopls: pre-arm `cmd = { "gopls", "-debug=localhost:6060" }` in lsp.lua, then
   `curl 'localhost:6060/debug/pprof/profile?seconds=15' -o /tmp/gopls.pb.gz`
   and `go tool pprof -top /tmp/gopls.pb.gz`.
6. In-nvim spot checks:
   ```vim
   " autocmd stacking (nvim-tree handlers registered without a group)
   :lua print(#vim.api.nvim_get_autocmds({event="FocusGained"}))
   " event-loop spin at idle (hands off keyboard; thousands = spinning timer)
   :lua local a=vim.uv.metrics_info().loop_count; vim.defer_fn(function() print(vim.uv.metrics_info().loop_count-a) end, 5000)
   " libuv handle census — run twice 30 min apart; growing timer/process/fs_event = leak
   :lua local c={}; vim.uv.walk(function(h) local t=h:get_type(); c[t]=(c[t] or 0)+1 end); vim.print(c)
   " in-flight LSP request pileup
   :lua vim.print(vim.tbl_map(function(c) return {c.name, vim.tbl_count(c.requests)} end, vim.lsp.get_clients()))
   ```

## Verified real (but minor) defects — ALL FIXED 2026-07-06

Every defect below was fixed with a RED→GREEN test (unit+smoke+e2e suites green).
Makefile targets now reap hung plenary children via `scripts/run-plenary.sh`;
use that wrapper for single-spec runs too
(`scripts/run-plenary.sh tests/minimal_init.lua tests/spec/unit/<x>_spec.lua`) —
direct `nvim --headless -c PlenaryBusted...` invocations still strand children
(they finish their run but a live libuv handle keeps them from exiting).
Pre-existing orphans need a one-time manual `pkill -f plenary.busted`.

| Where | Defect |
|---|---|
| `Makefile:42-54` | Plenary spawns one headless nvim child per spec and never reaps hung ones — ~35 orphans (~6 MB each) accumulated since June. Cleanup: `pkill -f plenary.busted`. Fix: timeout/trap wrapper on test targets. |
| `lua/config/ai_models.lua:574` | Library-scrape fallback curl has no `--max-time`; a stall wedges `active_scrape` forever → `<C-u>` dead for the session. |
| `lua/config/ai_models.lua:422` | `pull_model` streaming curl has no watchdog; a wedged ollama daemon wedges `active_pull` for the session. |
| `lua/config/telescope_smart.lua:381` | `_list_all_async` rg/fd spawn has no timeout (all git spawns in the same file have one). |
| `lua/plugins/nvim-tree.lua:143,163,178` | Three autocmds registered without an augroup — re-sourcing/`:Lazy reload` stacks duplicate handlers (multiplies git spawns per FocusGained). |
| `lua/config/statusline.lua:158` + `lua/config/review_base.lua:118` | FocusGained sweeps every loaded buffer with no per-root dedup → N identical `git rev-parse` spawns per alt-tab, plus cache invalidation forcing sync re-validation. Burst churn, not sustained CPU. |
| `lua/util/git.lua:83` | `root_cache` only caches successes → every non-repo buffer re-runs a **synchronous** `git rev-parse … :wait(2000)` on each miss (main-thread stalls on buffer churn). |
| `lua/config/nvim_tree_git.lua:55` | `refresh_labels` bypasses the in-flight dedup → overlapping whole-tree `git status` pipelines during rebases/rapid refreshes. |
