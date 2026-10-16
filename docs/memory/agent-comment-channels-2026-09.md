---
type: memory
title: "Agent comment channels"
kind: reference
description: "Which channels can carry nvim→agent review comments (prose + file#lines): ACP, Claude's IDE websocket, mcp__ide__ tools, cmux send, cc-socks."
---

# Agent comment channels

Researched 2026-09-05 for an nvim "comment on a change, agent receives it with
file#lines" feature. Verified against Claude Code 2.1.261's binary and the ACP
spec, not just docs.

**Claude's IDE websocket carries no prose.** The complete set of IDE→Claude
notification methods is `at_mentioned`, `selection_changed`, `log_event`
(`grep -a -o 'method:k("[a-z_]*")'`; the `project_*`/`write_files` names belong
to the artifacts subsystem). `at_mentioned` params are strictly
`{filePath, lineStart?, lineEnd?}` — **0-indexed on the wire**, Claude adds 1.
Claude renders it into the prompt box as literal text:
`` `@${rel}#L${start}-${end} ` `` (single `L`, one number when start==end). So
the reference format is just a string — anything that can type into the prompt
reproduces `at_mentioned` exactly, *and* can append a comment.

**Custom MCP tools over that websocket look viable** (UNVERIFIED — test before
building on it). The IDE connection registers as an MCP server named `ide`;
`mcp__ide__getDiagnostics` / `mcp__ide__executeCode` exist alongside a bare
`mcp__ide__` prefix constant, implying generic `tools/list` exposure. If so an
nvim IDE server can advertise e.g. `get_review_comments` and have Claude *pull*
structured `{file, line_start, line_end, comment}` — no terminal typing.

**ACP is the standard, but it cannot reach an already-running agent.** Its only
transport is stdio and "the client launches the agent as a subprocess"
(Streamable HTTP is still draft). Claude Code *is* ACP-reachable via
`zed-industries/claude-agent-acp`, Codex via `agentclientprotocol/codex-acp`;
Gemini CLI and OpenCode are native; nvim clients: CodeCompanion, agentic.nvim,
avante.nvim, hermes.nvim. `session/prompt` takes `Text` + `ResourceLink` blocks
(both baseline-mandatory), which carries prose + file refs natively, and
`ToolCallLocation {path, line}` would solve the follow-along dead end in
[[claudecode-automode-no-ide-events]] for free. **Rejected here only because it
requires the agent to live inside nvim**, not in its own cmux pane.

**`cmux send --surface <id> "text"`** types arbitrary text into any terminal
surface (`\n` submits, `send-key enter` also works) — agent-agnostic and the
only out-of-process channel that carries prose. It does not
depend on cmux's Claude Code integration hooks.

Verified live 2026-09-05 by injecting into a running Claude Code session's own
surface: the text lands in the prompt box of the **existing** conversation (same
pid, same context, nothing spawned); without a trailing `\n` it stays an
unsubmitted draft. An 89-char payload with `@ # / -` and spaces arrived intact
in one call — no escaping needed. Three traps found:

- `send-key ctrl+u` is a **no-op** in Claude Code's TUI (returns `OK`, does
  nothing). Do not assume readline bindings.
- **Bursts of repeated control keys are lossy**: 5 DEL deleted 5, 30 DEL deleted
  30, but 95 DEL deleted only 61. Same class as
  [[nvim-pty-probe-key-timing]]. Text blobs are fine; never drive the TUI with
  long key sequences, and chunk very large payloads.
- `cmux send` passes **raw bytes** through, beyond the documented `\n`/`\r`/`\t`
  — DEL (`0x7f`) works as backspace.

Remaining fragility is timing, not transport: input goes wherever focus is, so a
permission dialog or picker will swallow it. Sending without `\n` (user presses
Enter) avoids submitting blind.

**Do not use `/tmp/cc-socks/<pid>.sock`** (`CLAUDE_CODE_MESSAGING_SOCKET`, the
cross-session inbox). It does accept prose and wakes the session, but it is
private and unversioned, Claude-only, and nvim would have to scrape
`CLAUDE_CODE_MESSAGING_TOKEN` out of another process's environment.

**Outcome (shipped 2026-09-05, branch feat/agent-review-comments):** the cmux
sink was built, then DELETED in favour of the clipboard after it proved able to
deliver a review into the wrong agent's session — see
[[cmux-send-targeting-hazards]]. `<leader>as` copies; you paste where you are
looking. The durable write-up is committed at `docs/agent-review-comments.md`;
do not re-propose a terminal-typing sink without new evidence.

File-queue designs were explicitly discarded by the user.
