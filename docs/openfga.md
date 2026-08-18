# OpenFGA models (`.fga`, `fga.mod`)

Editor support for [OpenFGA](https://openfga.dev/docs/configuration-language)
authorization models: treesitter highlighting, folding, indentation and a
model-aware completion source. No language server is involved (see the last
section for why).

## What you get

| Feature | How |
| --- | --- |
| Filetype | `*.fga` and the `fga.mod` module manifest → `filetype=fga` (`init.lua`). The runtime's `ftplugin/fga.vim` sets `commentstring=# %s`. |
| Highlighting | The [`matoous/tree-sitter-fga`](https://github.com/matoous/tree-sitter-fga) grammar, pinned in `parser-revisions.lua` and installed by `make warm` like every other parser, with queries vendored in `queries/fga/`. |
| Folds | `type … relations …` blocks and `condition … { … }` bodies (`queries/fga/folds.scm`). |
| Indent | `relations` under `type`, `define` under `relations`, CEL under `condition`, `}` back out, `- file` entries under `contents:` in `fga.mod` (`queries/fga/indents.scm`); comment lines and the line under one keep the previous indent (`config.fga_indent`, see below). Not covered: `schema` under `model` — they are siblings in the tree and nvim-treesitter has no sibling-relative indent, so `model<CR>` lands at 0 and `gg=G` pulls `  schema 1.1` to column 0. |
| Context header | `type …` / `condition …` stays visible while scrolled inside it (treesitter-context, `queries/fga/context.scm`). |
| Completion | `config.blink_fga`, a blink.cmp source fronting the filetype (`lua/plugins/completion.lua`). |

## Completion

The source scans the current buffer plus every other loaded `fga` buffer (a
modular model spreads one type across files) for `type` / `extend type`,
`define` and `condition` lines, then decides what to offer from the text before
the cursor:

| You are typing… | It offers |
| --- | --- |
| a line start | `type`, `extend type`, `relations`, `define`, `condition`, `model`, `schema`, `module` — `model`, `schema`, `relations`, `define` and `condition` as snippets with tabstops (`relations` expands to `relations` + `define …: `) |
| `schema ` | `1.1`, `1.2` |
| `extend type ` | known type names |
| inside `[…]` | types, `type:*` wildcards, `type#relation` usersets |
| `[… group#` | `group`'s relations (the `#` reopens the menu) |
| `[… with ` | conditions, with their parameter list as detail |
| `define x: …` (outside brackets) | the current type's relations first, then the rest of the model's (declaring type as detail), then `or` / `and` / `but not` / `from`; right after `but ` only `not` |
| `… from ` | the current type's relations |
| `condition c(p: ` | `string`, `int`, `uint`, `bool`, `double`, `duration`, `timestamp`, `ipaddress`, `map<…>`, `list<…>` |
| inside a condition body | that condition's parameters |

Buffer words are the source's *fallback*: they only show when the model-aware
source has nothing to say (a fresh type name, a comment).

Two things worth knowing:

- mini.pairs auto-closes `[`, and blink does not reopen the menu after the
  cursor is moved back inside the pair — type the first letter of the type or
  press `<C-space>`.
- Comments are `#` at line start or after whitespace; `group#member` with no
  space is a userset and `"a #b"` inside a CEL string is text. The scanner and
  the highlighter agree on that rule.
- Type names may contain `.`, `/` and `-`; a `condition` header may spread its
  parameter list over several lines — both are scanned as the grammar reads
  them.

## Indent and comments

`queries/fga/indents.scm` drives nvim-treesitter's indent, with one shim on
top: `config.fga_indent` is the buffer's `indentexpr` (wired from the
treesitter FileType autocmd, the only per-filetype override there). It hands
comment lines, and the blank line opened under one, back to autoindent. Reason:
a `#` comment after the last define of a block is a *trailing extra*, and
tree-sitter hangs trailing extras off `source_file`, not off the block — so the
plain treesitter indent would drop the comment (and your next `define`) to
column 0. A bare `relations` with no define yet is likewise an ERROR node
*beside* the type; the query aligns the next line one level right of the
keyword (`indent.increment 2`, i.e. it assumes the config's `shiftwidth=2`).

## How the parser is registered

nvim-treesitter's registry does not carry `fga`, so `lua/plugins/treesitter.lua`
passes an `out_of_tree` table to `config.ts_pinned.setup(revisions, out_of_tree)`.
On the same `User TSUpdate` event it already uses for pinning, `ts_pinned`
creates the registry entry (url from that table, revision from
`parser-revisions.lua`) when nvim-treesitter has none — so `install()`,
`update()`, `make warm`, `make check` and `make update` all see a normal parser.
A url with no pin registers nothing: the pin file stays the single source of
truth for what gets installed.

The grammar's own `queries/highlights.scm` uses `(#is-not? local)`, a
nvim-treesitter/master predicate core Neovim has no handler for (the highlighter
throws and the buffer loses all highlighting), so `queries/fga/highlights.scm`
is an adapted copy. Because the config directory is first on the runtimepath,
those files are the *base* queries; nothing is copied into `site/queries/fga`.

To move the grammar to a newer commit: edit `fga = "…"` in
`parser-revisions.lua`, run `make warm`, and re-check `queries/fga/*.scm`
against the new `grammar.js` (node names are the contract).

## Why no language server

OpenFGA's language server lives inside the VS Code extension
(`openfga/vscode-ext`, `server/`). It provides pull diagnostics, hover and code
actions — no completion — and it is neither on npm nor in mason's registry, so
nothing here can pin it. Adding it later means:

1. building `server/out/server.node.js` from the extension repo (webpack),
2. `vim.lsp.config("openfga", { cmd = { "node", ".../server.node.js", "--stdio" }, filetypes = { "fga" } })`,
3. a client-side handler for its custom `getFileContents` request, which it
   uses to read sibling files for modular models.

Until then, `fga model validate` (the OpenFGA CLI) is the way to validate.
