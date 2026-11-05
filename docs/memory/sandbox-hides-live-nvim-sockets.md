---
type: memory
title: "Sandbox hides live nvim sockets"
kind: project
description: "Inside Claude Code's Bash sandbox every nvim RPC socket answers E247 connection refused and ps/pgrep are blocked, so live nvims look stale; listening on a socket fails too. Probe sockets with the sandbox off."
---

# Sandbox hides live nvim sockets

Inside Claude Code's Bash sandbox, `nvim --server <socket> --remote-expr` against
any nvim server socket fails with `E247: Failed to connect ... connection
refused`, the same message a socket left behind by an exited nvim gives. `ps`
and `pgrep` are blocked there too, so nothing in the sandbox can tell a live
nvim from a stale socket. `nvim --listen <path>` fails with `operation not
permitted`.

Found 2026-11-05 building the review-comments mod: 15 sockets under the per-user
nvim run directory all "refused" from the sandbox, which read as 15 stale
leftovers. Outside it, 12 were live nvims answering in ~25 ms, 3 were gone, and
2 accepted the connection and never replied (an nvim that is suspended or
blocked), which only showed up as timeouts once the mod ran outside the sandbox.

**Why:** a stale-socket conclusion drawn inside the sandbox is wrong by
construction, and a design built on it (here: "dead sockets fail fast") misses
the slow case the real machine has.

**How to apply:** run any probe of a live nvim's socket, and any test that
starts an nvim server, with the sandbox disabled. Treat "connection refused"
from inside the sandbox as no information. Related: [[nvim-tests-need-sandbox-disabled]],
[[docs/agent-review-comments]].
