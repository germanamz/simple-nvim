# OpenFGA `.fga` support — design

Date: 2026-08-17. Goal: syntax highlighting and completion suggestions for
OpenFGA authorization models (`.fga`, plus the `fga.mod` module manifest).

## What exists upstream (findings)

- Neovim 0.12's runtime already maps `*.fga` → `filetype=fga` and ships
  `ftplugin/fga.vim` (`comments=:# commentstring=#\ %s`). There is no syntax
  file, no parser, no indent script.
- [`matoous/tree-sitter-fga`](https://github.com/matoous/tree-sitter-fga)
  (MIT, last commit `ce72d1c` 2026-03-19) is a complete grammar for the DSL:
  `model/schema`, `type`/`extend type`, `relations`/`define`, direct
  relationships (`[user, user:*, group#member with cond]`), `or`/`and`/`but
  not`, `X from Y`, `condition name(p: type) { CEL }`, `module` files, and the
  `fga.mod` manifest form (`schema: '1.2'` + `contents:`). `src/parser.c` is
  committed, so a plain `cc` build works. It is NOT in nvim-treesitter's
  registry, and its `queries/highlights.scm` uses `(#is-not? local)`, a legacy
  nvim-treesitter/master predicate core Neovim has no handler for — loading it
  as-is throws `No handler for is-not?` from the highlighter.
- OpenFGA's official language server lives inside `openfga/vscode-ext`
  (`server/`): pull diagnostics, hover, code actions — **no completion**. It
  is not published to npm nor in mason's registry (checked 2026-08-15 snapshot),
  and it calls a custom `getFileContents` client request for modular models.
  Out of scope here; see "Follow-ups".

## Decisions

1. **Highlighting = tree-sitter, out-of-tree parser, vendored queries.**
   `config.ts_pinned` gains a second argument: a table of out-of-tree parsers
   (`{ fga = { url = "https://github.com/matoous/tree-sitter-fga" } }`). On
   the same `User TSUpdate` seam it already uses, it creates the registry
   entry when nvim-treesitter has none, then applies the pin from
   `parser-revisions.lua` as for every other parser. Nothing else in the
   pin/sync/check machinery changes: `make warm` installs it, `make check`
   verifies the stamp + `.so`, `make update` re-snapshots it.
   Queries live in `queries/fga/` in this config (the config dir is first on
   the runtimepath, so they are the *base* queries): `highlights.scm` (adapted
   from upstream, nvim captures only), `folds.scm`, `indents.scm`,
   `context.scm` (treesitter-context). No `install_info.queries`, so the
   installer never copies the incompatible upstream queries into
   `site/queries/fga`.
2. **`fga.mod` → `filetype=fga`.** The grammar parses the manifest form, and
   the module manifest is part of the same workflow. `.fga` is also pinned by
   extension so detection does not depend on the runtime's filetype table.
3. **Suggestions = a blink.cmp source, `config.blink_fga`.** Pure-Lua line
   scanner (the DSL is line-oriented) over the current buffer plus every other
   loaded `fga` buffer (modular models spread types across files). No
   treesitter dependency, so it works before the parser is built and is unit
   testable with the minimal harness. Context is decided from the text before
   the cursor on the current line, and the "current type" is the nearest
   `type …` line above.

   | Cursor context | Items |
   | --- | --- |
   | line start (only whitespace before the keyword) | keywords, snippet bodies for `model`, `schema`, `relations`, `define`, `condition` |
   | `schema ` | `1.1`, `1.2` |
   | `extend type ` | known type names |
   | inside an unclosed `[` | types, `type:*`, `type#relation`; after `with` → conditions; after `type#` → that type's relations |
   | `define x: …` value (outside brackets) | relations (current type first, then the rest of the model, with the declaring type as detail) + `or` `and` `but not` `from` |
   | after `from ` | relations of the current type |
   | `condition name(… :` | CEL param types (`string`, `int`, `uint`, `bool`, `double`, `duration`, `timestamp`, `ipaddress`, `map<…>`, `list<…>`) |
   | inside a condition body | that condition's parameter names |
   | in a `#` comment | nothing |

   Wired as `sources.per_filetype.fga = { "fga", "path", "buffer" }` with the
   buffer source as the fallback of `fga`, so buffer words only appear when
   the fga source has nothing to say.
4. **No LSP.** Documented as a follow-up with the exact obstacles.

## Files

- `parser-revisions.lua` — `fga = "ce72d1c484ba133a18e966d67be66bce85695451"`
- `lua/config/ts_pinned.lua` — `apply(revs, out_of_tree)` / `setup(revs, out_of_tree)`
- `lua/plugins/treesitter.lua` — out-of-tree table, `fga` in the FileType list
- `queries/fga/{highlights,folds,indents,context}.scm`
- `lua/config/fga_indent.lua` — indentexpr shim (comment lines → autoindent), wired as the fga override in `lua/plugins/treesitter.lua`
- `init.lua` — `vim.filetype.add({ extension = { fga = "fga" }, filename = { ["fga.mod"] = "fga" } })`
- `lua/config/blink_fga.lua` — scanner + context + items + blink source
- `lua/plugins/completion.lua` — provider + per_filetype
- tests: `tests/spec/unit/ts_pinned_spec.lua`, `tests/spec/unit/blink_fga_spec.lua`,
  `tests/spec/e2e/treesitter_spec.lua` (fga case), `tests/spec/smoke/completion_spec.lua`
- docs: `docs/openfga.md`, `docs/README.md` index, `docs/superpowers/testing.md` parser count

## Follow-ups (not in this change)

- Diagnostics/hover via OpenFGA's language server: needs a build of
  `openfga/vscode-ext`'s `server/out/server.node.js` (webpack) outside mason,
  a `cmd = { "node", …, "--stdio" }` `vim.lsp.config`, and a client-side
  handler for its `getFileContents` request. Nothing in mason pins it, which
  is why it is left out of a config whose tools are all lockfile-pinned.
- CEL injection inside condition bodies (no CEL parser pinned).
