# Zig (`.zig`, `.zon`)

Editor support for [Zig](https://ziglang.org/): treesitter highlighting, `zls`
for completion and diagnostics, and `zig fmt` on save.

## What you get

| Feature | How |
| --- | --- |
| Filetype | Neovim detects both `.zig` and `.zon` as `filetype=zig` on its own; nothing in `init.lua` overrides it. See [below](#zon-is-filetype-zig) — that one mapping decides the behaviour of every other row in this table. |
| Comments, shiftwidth | `$VIMRUNTIME/ftplugin/zig.vim`, which the runtime ships: `commentstring=// %s` (so `gcc` works), plus `sw=4 sts=4 ts=8 expandtab` — Zig's own style, over this config's global 2. Unlike Tiltfiles, there is nothing to add in `ftplugin/`. |
| Highlighting | The `zig` parser (`tree-sitter-grammars/tree-sitter-zig`, in nvim-treesitter's registry, pinned in `parser-revisions.lua`, installed by `make warm`) with nvim-treesitter's own queries. Filetype and parser share a name, so `lua/plugins/treesitter.lua` needs no `language.register` alias — only the `ft_pattern` entry. |
| Folds / indent | nvim-treesitter's zig queries, via the shared FileType handler. |
| Language server | `zls` in `lua/plugins/lsp.lua`, mason-pinned in `mason-tool-versions.lock`. Completion, hover, `gd`, references, document symbols, inlay hints (`<leader>uh`), and **diagnostics** — see [below](#why-there-is-no-lint-pass). Roots at `zls.json` / `build.zig` / `.git`. |
| Formatting | conform's `zigfmt` (`zig fmt --stdin`) in `lua/config/formatters.lua`: on save, on `<leader>F`, and on `gq`. A toolchain formatter off `PATH` like `gofmt` and `rustfmt`, not a mason tool. |
| Linting | Nothing separate. `zls` is the linter. |

## `.zon` is filetype `zig`

Neovim maps `.zon` to `filetype=zig` (core's own extension table). There is no
`zon` grammar and no `zon` filetype, so `build.zig.zon` is handled by the Zig
machinery throughout — and the four tools involved do not agree about whether
that is a good idea.

| Tool | On a `build.zig.zon` |
| --- | --- |
| `zls` | Serves it. ZON is a format it understands. |
| `zig fmt --stdin` | Formats it correctly, and idempotently: a canonical manifest round-trips byte-for-byte, an over-indented one is normalised. |
| The `zig` treesitter grammar | **Mis-parses it.** The grammar's root expects container members, not a top-level `.{ ... }` tuple, so the tree comes back with `has_error()` true and the file is read as a single `container_field` holding a `range_expression`. |
| `zig ast-check` | **Rejects it**, with `error: file cannot be a tuple`. |

The grammar row looks worse than it is, and the obvious fixes for it are traps.
The error node lands on the closing brace and nowhere else; every token that
matters still gets the capture it should — field names highlight as
`variable.member`, values as `string`, brackets and operators as themselves.
Giving `.zon` its own filetype, or skipping treesitter for it, would trade
correct highlighting with an invisible error node for no highlighting at all —
and, because `zls` and `zigfmt` are both keyed on `filetype=zig`, it would
silently take the language server and the formatter away from the manifest too.
`tests/spec/e2e/treesitter_spec.lua` pins the captures so a grammar bump that
turns "mostly right" into garbage gets noticed.

The `ast-check` row is the one with teeth, and it is the reason the next section
exists.

## Why there is no lint pass

`nvim-lint` ships a `zig` linter — `zig ast-check`, read from stdin — and this
config deliberately does not wire it.

`zls` already runs `ast-check` internally and publishes the result, so a second
pass would put two identical diagnostics on every line. That is the same rule
that narrows `biome` off `json`/`css` in `lua/plugins/lsp.lua`: no buffer gets
two tools claiming it. `tests/spec/e2e-lsp/zls_spec.lua` asserts the server
really is the thing reporting errors, rather than merely attaching, so this
stays a decision rather than a gap.

Anyone reconsidering should know what the duplication would cost on top of
being redundant: `ast-check` rejects `build.zig.zon` outright, and `.zon` is
`filetype=zig`, so a linter wired on that filetype fires `error: file cannot be
a tuple` on every manifest in the project. It would need excluding by filename,
not by filetype.

The one real cost of this choice: with no `zls` installed, Zig buffers get **no
diagnostics at all**, where a standalone `ast-check` pass would still have
caught syntax errors and undeclared identifiers. `make sync` installs `zls`, so
this only bites on a machine that never ran it.

## What `zls` does not diagnose

`ast-check` is per-file. It catches syntax errors and undeclared identifiers,
but it does not resolve imports or check types across files — a call that
type-checks locally and breaks the build is invisible in the editor.

`zls` can close that gap with `enable_build_on_save`, which runs `zig build` on
each write and reports what the compiler says. It is off here because it runs
the project's own build steps on every save: fine against a `build.zig` with a
dedicated no-emit `check` step, slow or side-effecty against one without.
Turning it on is per-project, in a `zls.json` beside `build.zig`, so it costs
nothing here to leave off:

```json
{
  "enable_build_on_save": true,
  "build_on_save_args": ["check"]
}
```

`zig build` from a terminal remains the answer everywhere else.

## Keeping `zls` and `zig` in step

`zls` links the Zig compiler frontend it was built against, so `zls` 0.16.x
expects `zig` 0.16.x. That makes its pin unlike the others in
`mason-tool-versions.lock`, because the two halves of the toolchain come from
different places:

- `zls` is mason's, pinned in `mason-tool-versions.lock`, installed by `make sync`.
- `zig` is whatever is on `PATH` (Homebrew here). conform's `zigfmt` runs *that*
  binary, and so does `zls` when build-on-save is enabled.

So a `brew upgrade zig` to a new minor version is not self-contained: it leaves
the editor parsing one language version while the toolchain builds another, with
no error to say so. Bump the `zls` line in `mason-tool-versions.lock` in the same
change and run `make sync`.

If `zig` is missing from `PATH` the degradation is graceful and nearly
invisible: conform skips `zigfmt`, and the global `lsp_format = "fallback"`
hands the buffer to `zls`, which formats through the same `zig fmt` internally.

## Tests

- `tests/spec/smoke/lsp_filetypes_spec.lua` (`make test-smoke`): `zls` is
  enabled, claims exactly `zig`, and is the only server that claims it. The
  narrowing is asserted because lspconfig's own list is `{ "zig", "zir" }` and
  Neovim has no `zir` filetype at all.
- `tests/spec/e2e/treesitter_spec.lua` (`make test-e2e`): the highlighter
  attaches to a `.zig` buffer, and a `build.zig.zon` still highlights correctly
  through the mis-parsing described above.
- `tests/spec/e2e/format_on_save_spec.lua` (`make test-e2e`): a `.zig` buffer is
  reformatted by `zigfmt` on write — asserted both as the resulting bytes and as
  conform's own list of formatters to run, so an LSP fallback cannot fake a pass
  — and a `build.zig.zon` survives the same path intact.
- `tests/spec/e2e-lsp/zls_spec.lua` (`make test-lsp`): a real `zls` attaches to
  a Zig buffer and reports an undeclared identifier. Self-skips when there is no
  `zls` on `PATH` (mason's bin dir is not on the shell `PATH` by default).
