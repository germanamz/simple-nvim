# CPU and memory runaway: findings and capture playbook

Incident (2026-07-06): after about an hour of an interactive nvim session
(editing a Go project), CPU sat near 96% across three processes with a reported
"400+ GB virtual memory."

## What the audit established

- **The 400 GB virtual memory is a red herring.** On Apple Silicon macOS every
  process shows roughly 435 GB of reserved address space, not real memory. Even
  WindowServer shows 437 GB. Watch RSS and %CPU only.
- **The three hot processes were never identified.** That is the missing evidence.
  Run step 1 below the moment it recurs.
- A 78-agent audit of all ~8,800 lines of config found no runaway loop, timer, or
  watcher that could sustain 96% CPU or ramp up after an hour. Every claimed hot
  loop was refuted or measured to be microscopic; the block_guides recompute, for
  example, is about 1.1 ms per keystroke, near 1% CPU.

## Best current explanation (partial)

1. **Ollama runner.** minuet fires a FIM completion at qwen2.5-coder:7b about once
   a second while typing (`auto_trigger_ft = {"*"}`, throttle 1000 ms, debounce
   400 ms, `--max-time 3`, all verified working). A 7b prefill per second keeps the
   runner near 100% by design, but only while typing, and it stops about 3 seconds
   after the last keystroke. If the runner shows 96% CPU rather than GPU, the Metal
   offload failed; check the GPU column of `ollama ps` during the burn.
2. **gopls.** The "semantic_tokens: no package metadata" errors were a two-second
   startup race (four log lines), not a loop. Neovim 0.12.3's semantic-tokens
   client does re-request after errored responses with no terminal error state (a
   real upstream weakness), but the log rules it out as this session's burner.
   gopls's own background typechecking was never profiled.
3. **nvim itself.** No confirmed mechanism exceeds a few percent CPU. If nvim was
   hot, `sample` it (step 2). One possibility not investigated: nvim, Ghostty, and
   WindowServer together in a redraw storm, which heats all three at once.

## Capture playbook

Run the first three within a minute of noticing the burn; everything else was
guesswork for lack of them.

1. Name the processes:
   ```sh
   ps -Ao pid,ppid,pcpu,pmem,rss,etime,command -r | head -20   # x3, 10s apart
   ps -o ppid= -p <hot-pid>                                    # child of nvim?
   ```
2. Wall-clock profile each hot pid:
   ```sh
   sample <pid> 10 -file ~/sample-<name>.txt
   ```
3. Check whether RSS actually grows:
   ```sh
   while :; do date; ps -o pid=,rss=,pcpu= -p <p1>,<p2>,<p3>; sleep 60; done | tee ~/leak.log
   ```
4. Ollama: `ollama ps` (CPU vs GPU column) and
   `grep -c /v1/completions ~/.ollama/logs/server.log` per minute.
5. gopls: pre-arm `cmd = { "gopls", "-debug=localhost:6060" }` in lsp.lua, then
   `curl 'localhost:6060/debug/pprof/profile?seconds=15' -o /tmp/gopls.pb.gz` and
   `go tool pprof -top /tmp/gopls.pb.gz`.
6. In-nvim spot checks:
   ```vim
   " autocmd stacking (nvim-tree handlers registered without a group)
   :lua print(#vim.api.nvim_get_autocmds({event="FocusGained"}))
   " event-loop spin at idle (hands off keyboard; thousands = spinning timer)
   :lua local a=vim.uv.metrics_info().loop_count; vim.defer_fn(function() print(vim.uv.metrics_info().loop_count-a) end, 5000)
   " libuv handle census: run twice 30 min apart; growing timer/process/fs_event = leak
   :lua local c={}; vim.uv.walk(function(h) local t=h:get_type(); c[t]=(c[t] or 0)+1 end); vim.print(c)
   " in-flight LSP request pileup
   :lua vim.print(vim.tbl_map(function(c) return {c.name, vim.tbl_count(c.requests)} end, vim.lsp.get_clients()))
   ```

## Defects found and fixed (2026-07-06)

The audit turned up several real but minor defects, all fixed with a red-green
test (unit, smoke, and e2e suites green). The Makefile test targets now reap hung
plenary children through `scripts/run-plenary.sh`; use that wrapper for single-spec
runs too, since a direct `nvim --headless -c PlenaryBusted...` still strands
children (the run finishes but a live libuv handle keeps the process from exiting).
Pre-existing orphans need a one-time `pkill -f plenary.busted`.

| Where | Defect |
| --- | --- |
| `Makefile` test targets | Plenary spawns one headless nvim child per spec and never reaps hung ones; about 35 orphans (~6 MB each) had accumulated since June. Fixed with a timeout/trap wrapper. |
| `lua/config/ai_models.lua` (library scrape) | The fallback curl had no `--max-time`; a stall wedged `active_scrape` for the session, killing `<C-u>`. |
| `lua/config/ai_models.lua` (`pull_model`) | The streaming curl had no watchdog; a wedged ollama daemon wedged `active_pull` for the session. |
| `lua/config/telescope_smart.lua` (`_list_all_async`) | The rg/fd walk had no timeout, unlike every other git spawn in the file. |
| `lua/plugins/nvim-tree.lua` | Three autocmds registered without an augroup; re-sourcing or `:Lazy reload` stacked duplicate handlers, multiplying git spawns per `FocusGained`. |
| `lua/config/statusline.lua` + `lua/config/review_base.lua` | `FocusGained` swept every loaded buffer with no per-root dedup, firing N identical `git rev-parse` spawns per alt-tab plus cache invalidation forcing sync re-validation. Burst churn, not sustained CPU. |
| `lua/util/git.lua` | `root_cache` cached only successes, so every non-repo buffer re-ran a synchronous `git rev-parse ... :wait(2000)` on each miss, stalling the main thread on buffer churn. |
| `lua/config/nvim_tree_git.lua` | `refresh_labels` bypassed the in-flight dedup, overlapping whole-tree `git status` pipelines during rebases and rapid refreshes. |

The timer-handle discipline these defects exposed is why the [file
picker's](smart-files.md) loading float reuses one lazily created `vim.uv` timer
rather than allocating one per press.
