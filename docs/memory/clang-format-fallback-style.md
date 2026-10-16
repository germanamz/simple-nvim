---
type: memory
title: "Clang-format fallback style"
kind: project
description: "clang-format's --fallback-style rejects inline YAML, so the no-project-config style has to be a gated --style; plus the conform override mechanics it rides on."
---

# Clang-format fallback style

Shipped 2026-09-21 on main: C/C++ buffers in a project with no `.clang-format`
now keep short enums and one-statement function bodies expanded
(`config.formatters.clang_format_args` + a `prepend_args` override in
`plugins/conform.lua`).

The tool facts that forced that shape, verified against clang-format 22.1.5:

- Bare LLVM style folds exactly two things in C: `AllowShortEnumsOnASingleLine:
  true` and `AllowShortFunctionsOnASingleLine: All`. Short ifs/loops/blocks/case
  labels are already `Never`/`false` — do not add them to the style string.
- `--fallback-style` is the semantically right flag (it applies *only* when no
  config is found) but takes **named styles only**: inline YAML there exits 1
  with "Invalid fallback style". Only `--style` accepts inline YAML — and
  `--style` overrides a project `.clang-format` outright. Hence the gate in Lua:
  search upward first, pass `--style` only when nothing is found.
- clang-format's own config search runs to the filesystem root, so the upward
  search must NOT stop at `.git` the way `js_toolchain` does, or we'd override a
  config clang-format would have honoured. It looks for `.clang-format` *and*
  `_clang-format`.

conform mechanics worth not re-deriving (see [[js-toolchain-detection-plan]] for
the sibling per-project dispatch):

- `conform.formatters.<name>` may be a **function of bufnr**; it is re-evaluated
  on every `get_formatter_config` (conform/init.lua:697), so per-buffer decisions
  work. A plain table would freeze at setup.
- `prepend_args` extends `range_args` as well as `args`
  (conform/util.lua:158-161), so a visual-selection `<leader>F` gets it too.
- `conform.formatters.clang_format` is now a `meta.deprecated` shim; the real
  name is `clang-format`. The `by_ft` name and the override key must match.

**Why:** the obvious-looking `--fallback-style` fix does not work, and the
obvious `--style` fix silently hijacks projects that ship their own config.

**How to apply:** when adding another "our defaults unless the project says
otherwise" formatter, copy this gate shape, and check whether the tool's own
config search has a boundary before adding one to the Lua search.

Testing note: these e2e cases self-skip as *pending* unless mason's bin dir is on
PATH (`PATH=~/.local/share/nvim/mason/bin:$PATH make test-e2e`) — the same trap
as [[nvim-test-lsp-needs-mason-path]], and it applies to any mason-only tool, not
just LSP specs. e2e also needs the sandbox off
([[nvim-tests-need-sandbox-disabled]]).
