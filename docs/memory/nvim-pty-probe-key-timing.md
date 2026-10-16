---
type: memory
title: "Nvim pty probe key timing"
kind: project
description: "pty probes for nvim: write ONE key per os.write with a ~0.8s pause (a burst like `$ax` makes multicursor miss the motion and fakes a bug), run one case per process (a shared drain thread wedges case 2), and prefer file-out over --remote-expr."
---

# Nvim pty probe key timing

Refinements to [[nvim-pty-probe-for-blink]], learned 2026-08-18 while debugging
multicursor.nvim.

**Why:** two probe designs produced false results before the real bug surfaced.

**How to apply:**

- **One key per `os.write`, ~0.8s apart.** Writing `b"$ax"` as one chunk made
  the `$` appear not to reach the non-main cursors — a pure artifact: the keys
  arrive without an intervening safe state, so multicursor never applies the
  motion. The same keys sent individually worked on every cursor. Any
  "plugin ignores my motion" result from a burst write is suspect; re-run
  slowly before believing it.
- **One case per process, then `os._exit(0)`.** A single script looping over
  cases with a shared pty + daemon drain thread completed case 1 and wedged
  forever on case 2 (`os.close(master)` races the blocked `os.read`). Driving
  `case.py <name>` once per case from a bash `for` loop is reliable.
- **Prefer keys-in / file-out over `--remote-expr`.** Ending the case with
  `:wq!` and reading the saved file needs no socket, no RPC, and no draining
  for correctness — and it exercises the real terminal key decoder. An
  RPC-based version of the same probe hung twice.
- Raw sequences that decode correctly: `<S-Up>`=`\x1b[1;2A`,
  `<S-Down>`=`\x1b[1;2B`, `<C-n>`=`\x0e`, `<Esc>`=`\x1b`.
