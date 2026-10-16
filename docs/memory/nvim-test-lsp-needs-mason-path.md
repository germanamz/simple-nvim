---
type: memory
title: "Nvim test-lsp needs mason PATH"
kind: project
description: "make test-lsp silently self-skips (pending, exit 0) unless mason's bin dir is prepended to PATH"
---

# Nvim test-lsp needs mason PATH

A plain `make test-lsp` exits 0 but the real-server spec self-skips as
`pending` — the isolated test env never sees mason's bin dir, so
`lua-language-server` isn't on PATH and the lane passes vacuously. To actually
exercise the server:

```bash
PATH="$HOME/.local/share/nvim/mason/bin:$PATH" make test-lsp
```

Run with sandbox off like all nvim test lanes ([[nvim-tests-need-sandbox-disabled]]).
Verified green (real attach + initialize) on 2026-07-04.
