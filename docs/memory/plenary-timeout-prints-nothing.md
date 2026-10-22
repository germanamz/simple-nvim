---
type: memory
title: "Plenary timeout prints nothing"
kind: project
description: "A spec file past plenary's 50 s per-file timeout prints only its Testing: header, no Fail line; retry loops must stop on an LSP error reply"
---

# Plenary timeout prints nothing

A spec file that is still running when `PlenaryBustedDirectory`'s per-file
timeout (50 s by default) expires prints only its `Testing: <file>` header, with
no `Fail` line and no `Success:`/`Failed :` totals. The harness reports the job
as a failure (its exit code is still unset at the join), and `run-plenary.sh`
kills it. The child's own output is lost, so you get neither the assertion nor
the reason.

It bit `tests/spec/e2e-lsp/python_navigation_spec.lua` when it was run against
plain pyright as a mutation check. A `vim.wait(60000, ...)` retry loop kept
re-sending `textDocument/implementation` to a server that answered `-32601`
every time, and the file never got as far as failing.

**Why:** e2e-lsp specs wait on slow servers, and a retry budget that covers a
slow machine also hides a server that will never answer.

**How to apply:** in a retry loop around an LSP request, treat `res.err` as
final: stop waiting and carry the message into the assertion. Keep the total of
an `it`'s waits well under 50 s on the failure path. When a lane prints a
`Testing:` header with nothing under it, suspect the timeout before the spec.
See [[nvim-test-lsp-needs-mason-path]] for running the lane at all.
