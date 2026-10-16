---
type: memory
title: "Nvim e2e single file needs minimal_init"
kind: project
description: "Running one nvim e2e/smoke spec file directly: use PlenaryBustedDirectory <file> { minimal_init='tests/full_init.lua' } (PlenaryBustedFile ignores the opts table) or only bundled treesitter parsers attach."
---

# Nvim e2e single file needs minimal_init

When running a SINGLE e2e/smoke spec file for this nvim config (instead of the
whole `make test-e2e` directory), you MUST pass the harness init explicitly:

`nvim --headless -u tests/full_init.lua -c "PlenaryBustedDirectory tests/spec/e2e/foo_spec.lua { minimal_init = 'tests/full_init.lua' }"`

(2026-08-17 correction: it has to be **PlenaryBustedDirectory** — it accepts a
single file path — with the sandbox off. `PlenaryBustedFile <file> { minimal_init
= ... }` does NOT parse the opts table: it treats the whole argument as one
filename and fails with "cannot open ... No such file or directory".)

If you omit the `{ minimal_init = ... }` table, plenary spawns the child nvim
with its own default init, NOT `full_init.lua`. In that degraded child the
config's treesitter `FileType` autocmd never runs and the host
`~/.local/share/nvim/site/parser` dir is effectively off the runtimepath, so
**only Neovim's bundled parsers attach** (lua, c, markdown, query, vim, vimdoc).
Tests that open `.ts`/`.py`/`.html`/etc. then fail with
"treesitter highlighter never attached" / `wait_for timed out`, while the same
test passes under `make test-e2e` (which does pass `minimal_init=full_init`).

Symptom that pinpoints this: a `lua` fixture attaches but `python`/`html`/`ts`
ones time out in the same run. It is a harness-invocation artifact, not a bug in
the code under test. Related: [[nvim-tests-need-sandbox-disabled]] (e2e/smoke
also need the sandbox off).
