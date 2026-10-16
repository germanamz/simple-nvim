---
type: memory
title: "Pyright per-project dead ends"
kind: project
description: "Approaches for per-project LSP settings that were verified DEAD for this nvim config — do not re-propose neoconf, exrc, typeCheckingMode=basic, or publishDiagnostics hooks."
---

# Pyright per-project dead ends

Shipped 2026-08-25 as `lua/config/pyright_rules.lua` + `docs/python-diagnostics.md`
(the `<leader>ld` picker). The doc covers what works; these are the alternatives
that were measured and REFUTED, which the repo does not record.

- **`typeCheckingMode = "basic"`** — the universal internet advice, and inert.
  `reportCallIssue` / `reportArgumentType` / `reportAttributeAccessIssue` /
  `reportAssignmentType` / `reportIndexIssue` are `"error"` in basic, standard AND
  strict alike (12 errors in all three on the same file, pyright 1.1.409). Only
  `off` silences them. Per-rule `diagnosticSeverityOverrides` is the only lever.
- **`"hint"` severity** — a basedpyright extension. Pyright silently discards it
  and leaves the rule at its default, i.e. still red.
- **`vim.lsp.handlers["textDocument/publishDiagnostics"]` hooks** — pyright
  dynamically registers `textDocument/diagnostic`, so Neovim PULLS. Push hooks
  fired 0 times while 6 diagnostics landed. Every "downgrade LSP severity in
  Neovim" blog recipe is built on this and is a silent no-op. (`init_options =
  { disablePullDiagnostics = true }` forces push back if ever needed.) Do not
  test push-vs-pull with `server_capabilities.diagnosticProvider == nil` — ruff
  is pull with a non-nil STATIC provider; use `client:supports_method`.
- **neoconf.nvim** — structurally inert under native `vim.lsp.config`: it injects
  via `lspconfig.util.on_setup` → `on_new_config`, neither of which
  `vim.lsp.config`/`vim.lsp.enable` ever calls. Effectively unmaintained;
  AstroNvim v6 dropped it.
- **`.nvim.lua` (exrc) calling `vim.lsp.config`** — there is no protective merge
  priority: priority 4 is one bucket merged in CALL ORDER, last wins. This repo
  registers inside mason-lspconfig's `BufReadPre` config(), i.e. AFTER exrc, so
  the repo wins every overlapping key. Appears to work only for keys the repo
  never sets.
- **Reassigning `config.settings` in `before_init`** — `client.settings` is bound
  by reference at `Client.create`, BEFORE before_init. Reassigning breaks the
  aliasing and the server never learns. This is the pattern in Neovim's OWN
  `client.lua` docstring. Mutate in place.

Two live constraints, not dead ends: pyright's config-file precedence is
WHOLESALE (any `pyrightconfig.json` or even an empty `[tool.pyright]` discards
the entire client settings group), and Neovim ignores `workspace/configuration`'s
`scopeUri`, so per-subtree severities are unreachable from the editor.

Also surfaced and NOT fixed: `mason-lspconfig`'s `automatic_enable` defaults true
and `lua/plugins/lsp.lua` never disables it, so `ruff` and `dprint` attach to
Python buffers undeclared. Related: [[nvim-tests-need-sandbox-disabled]],
[[nvim-e2e-no-edit-lsp-filetypes]].
