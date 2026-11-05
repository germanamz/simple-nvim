---
type: memory
title: "Claude mod authoring traps"
kind: project
description: "Claude Code mods: $ may only be passed to top-level functions or the module fails to load; the test kit strips a refusal cause; prompt.fill insert glues onto the draft; read the TUI with tmux capture-pane, not a raw pty; claude --debug times every $ call."
---

# Claude mod authoring traps

Learned 2026-11-05 on Claude Code 2.1.318, building the mod that pulls review
comments out of nvim ([[docs/agent-review-comments]]). The mod API is early
access, so re-check these after an update.

**Why:** each cost a round trip that looked like a logic bug.

**How to apply:**

- **`$` goes only to top-level functions.** A helper declared inside
  `register` and handed `$` makes the hooks module fail to load ("$ is passed
  to X, which is not a function declared at the top of this file"). Keep the
  helpers, and the state they share, at module level; a closure that calls a
  top-level function with `$` is fine. `claude plugin validate` catches it
  before a session does.
- **The test kit strips a refusal cause.** A test's own `prompt.fill` hook
  answering `{ isFilled: false, refusal: 'dialog' }` reaches the mod without
  `refusal`, so the dialog branch's wording is untestable there. Assert on what
  must not happen (no ack) instead.
- **`prompt.fill` with `mode: 'insert'` glues text to the draft.** Read
  `$.prompt.read()` first and put a blank line before the insert when the text
  before the cursor is not empty.
- **A raw pty capture of the TUI cannot be searched.** It redraws only changed
  cells, so a capture holds fragments like `Insert th reviewcommentsqueued`.
  Run `claude --plugin-dir <mod>` in a private tmux server (`tmux -L <name>`)
  and read the screen with `capture-pane -p`; `send-keys -l` types, and
  `C-x Tab` then `Enter` presses the band's focused button.
- **A probe in a fresh folder stops at the trust dialog.** It defaults to
  "No, exit" there, so a blind Enter quits Claude (and the tmux server with it),
  and no hooks module loads until trust is accepted: send `Down` then `Enter`.
  The debug log says "hooks modules not loaded until workspace trust is
  accepted" when that is what happened.
- **`claude --debug` times everything.** Each `$.process.run` logs its exit
  code, duration and output size, each hook logs "settled in N ms", and
  `$.ui.log(text, { to: 'debug' })` lands there too. That is how a 4 s command
  was traced to queries waiting out a timeout.

Related: [[sandbox-hides-live-nvim-sockets]].
