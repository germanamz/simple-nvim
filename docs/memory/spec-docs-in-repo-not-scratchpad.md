---
type: memory
title: "Spec docs in repo not scratchpad"
kind: feedback
description: "Specs/plans go in the repo but stay uncommitted; docs of how things currently work do get committed."
---

# Spec docs in repo not scratchpad

Write design specs into the working repo (e.g. `docs/<name>.md`), not the session
scratchpad. **What gets committed is decided by content, not location:**

- **Specs and plans — never commit.** Forward-looking framing: "Fix design", a
  table of files to change with "new" markers, a list of tests to write.
- **Documentation of how something currently works — commit it.** Present tense,
  a responsibility map instead of a change list, past tense for code that no
  longer exists.

**Why:** stated directly on 2026-08-27 — "specs and plans should not be commited,
but documentation about how things are currently implemented are." The earlier
version of this memory said only "leave it untracked", which led to committing a
spec-voiced doc and then rewriting it (`9bf44ea`).

**How to apply:** draft in `docs/<topic>.md` and leave it untracked while it is a
spec. If the feature ships and the doc should live on, **rewrite it into
implementation voice first**, then commit — do not commit the spec as-is.

The decision record ("rejected and why") **stays in** the committed version;
`docs/superpowers/README.md` sets that convention — those docs are for someone
*changing* the config, and "where a design and the implementation diverged, the
implementation wins" — and js-toolchain.md / lsp-fs-sync.md / zig.md all carry
one. Related: [[nvim-tagstack-api-traps]].

Note: `docs/superpowers/specs/2026-08-17-openfga-fga-support-design.md` is
tracked, which predates this rule and contradicts it.
