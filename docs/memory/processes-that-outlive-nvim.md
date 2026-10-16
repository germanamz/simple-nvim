---
type: memory
title: "Processes that outlive nvim"
kind: project
description: "The config leaks no processes: every LSP child is stdio and exits with nvim. Only prettierd (per cwd, no idle timeout) and eslint_d (idle-exits) outlive it by design; stale port badges in cmux's sidebar are a cmux bug, not live processes."
---

# Processes that outlive nvim

A 2026-08-17 report of "nvim starts lots of processes on multiple ports and they
never go away" turned out to be cmux's sidebar, not the config.

Verified findings:
- The config has NO process leak. In a PTY reproduction on a polyglot repo,
  dprint, ts_ls (+2 tsserver) and gopls (+telemetry) were all stdio, none was
  listening on a port, and all were gone 3s after `:qa!`. nvim's `--embed`
  server and every child run with no controlling tty, so a tty-based port scan
  cannot attribute anything to nvim at all.
- The ports cmux showed had no socket behind them (`lsof -iTCP:<port>` empty).
  cmux's port scanner (as of 2026-08) included the root-owned `login` process
  on each panel tty, failed to inspect it, marked the scan incomplete, and so
  never retired a port it had once seen. Fixed upstream in cmux PR #9324.
- cmux's port model: `ps -t` + `lsof -p … -sTCP:LISTEN` per panel, driven by
  shell preexec/precmd hooks with no timer; ports persist per panel across
  restarts; detached daemons (ppid 1, no tty) are invisible to it.
- What DOES outlive nvim, by design and invisible to cmux: prettierd runs one
  daemon per cwd (`CORE_D_DOTFILE=.prettierd@<cwd>`) with NO idle timeout and a
  portfile under `$TMPDIR`, so a different `TMPDIR` spawns a second daemon and
  strands the first; eslint_d runs one per project and exits after 15 idle
  minutes. The only path in the config that can start Ollama is the
  `ollama list` call in `lua/config/ai_models.lua`.

**Why:** avoid re-auditing nvim for a leak that lives in the terminal; sidebar
port badges are not evidence of live processes.
**How to apply:** if stale port badges recur, verify with `lsof -nP -iTCP:<port>`
before suspecting the config, and check whether the running cmux predates the
upstream fix. Related: [[nvim-leak-audit-2026-07]], [[cmux-browser-from-nvim]],
[[js-toolchain-detection-plan]].
