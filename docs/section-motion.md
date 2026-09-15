# `]]` and `[[` as a section motion

`]]` and `[[` step between function definitions in every buffer that has a
treesitter parser. This document covers why the stock motion did not, and how
the replacement decides what counts as a section.

## Why the built-in motion skipped C functions

`:h ]]` defines the built-in motion as "[count] sections forward **or to the
next `{` in the first column**". That is the whole heuristic: a literal search
for an opening brace in column 1.

It dates from a time when C was written with the brace on its own line:

```c
int alpha(int x)
{               /* column 1 — the motion finds this */
  return x + 1;
}
```

Written the way almost everyone writes C and C++ now, there is no column-1 brace
anywhere in the file:

```c
int alpha(int x) {   /* column 18 — invisible to the motion */
  return x + 1;
}
```

So `]]` found nothing and ran to the end of the file, silently skipping every
function on the way. It looked like a broken keybinding; it was the motion doing
exactly what it was documented to do against a brace style it predates.

Neovim's runtime papers over this per filetype — `ftplugin/go.vim`,
`python.vim`, `rust.vim`, `vim.vim`, `markdown.lua` and about fifteen others map
`]]` to something language-aware. `ftplugin/c.vim` and `cpp.vim` map nothing, so
C and C++ fell through to the column-1 search. Neither the config nor any plugin
was involved: `verbose nmap ]]` in a C buffer reported *No mapping found* under
`nvim --clean` too.

## What replaced it

`lua/config/ts_sections.lua` derives targets from the syntax tree and maps `]]` /
`[[` buffer-locally from the treesitter `FileType` handler in
`lua/plugins/treesitter.lua`. Wiring it there means it inherits that handler's
large-file guard and only attaches where a parser actually started. It also runs
after core's `filetypeplugin` autocmd, which is what lets these maps replace the
runtime's own `]]` in go, python, rust, vim, markdown and sql — the motion
behaves identically everywhere rather than differently in six filetypes.

Targets are resolved in tiers, so there is no per-language table of node types
to maintain as grammars change.

### Tier 1 — the language's own `locals` query

`@local.definition.function` and `@local.definition.method` captures. These land
on the definition's **name identifier**, which is what makes anonymous inline
closures fall out for free — `xs.map(x => x + 1)` has no name to capture, so `]]`
does not stop inside it.

Covers c, cpp, lua, javascript, typescript and tsx (via `; inherits: ecma`),
python, go, rust, zig, bash, vim and starlark.

The captures alone are not enough. `cpp/locals.scm` has no pattern for a method
*defined* inline in a class — those parse as `function_definition`, while its
only method pattern matches `field_declaration`, a declaration without a body —
so a class body would contribute nothing. Rather than hardcode definition node
types, the tier learns them: each capture is resolved to its enclosing
definition, and the tree is then swept for every other node of the same type. One
out-of-class `void Widget::other()` teaches it `function_definition`, and the
inline methods come along.

Learning the types beats matching them by name (`type:match("function")`)
because it inherits the captures' own exclusion of anonymous functions: in
javascript it learns `function_declaration` and leaves `arrow_function` alone.

### Tier 1 seed — files with no captures at all

A C++ header holding nothing but a class of inline methods has no capture to
learn from. For those, a definition is any node whose type mentions `function`
or `method` *and* that has both a `body` and something naming it.

Those two field tests are what keep this from needing a per-grammar list:
`function_call` (lua) has a name but no body, `arrow_function` (javascript) has a
body but no name, and `function_declarator` (c) has neither. All three drop out
on their own.

### Tier 2 — languages with no function captures

hcl, terraform, sql, css, json, yaml, graphql, fga, toml, html, git_config and
markdown have no function captures, so they fall back to structural nodes: each
terraform block, each css rule, each sql statement, each top-level json key, each
markdown heading.

Two rules make that work across grammars:

**Descend through wrapper levels.** Grammars wrap the real top level in
single-child nodes — json is `document` > `object` > the pairs, terraform is
`config_file` > `body` > the blocks. Taking the root's children literally would
yield one useless target covering the whole file.

**Stop at a node that nests its own type.** A markdown `section` holds its
sub-sections, which means the node itself is the section unit and its children
are its contents, not a list of siblings. Descending past one turns `]]` in a
single-`# Heading` file into a paragraph motion. Same-type nesting is also
collected rather than swallowed, so nested headings are targets alongside
top-level ones.

## Behavior

The jump lands on the **first non-blank column of the row** a target starts on,
so `]]` on `int alpha(int x) {` stops at `int` rather than at `alpha`. That reads
as a section motion and avoids ancestor-walking guesswork to find the
definition's true start.

- Counts work: `3]]`.
- Normal, visual and operator-pending modes, so `d]]` and `y]]` work.
- The jump list is pushed, so `<C-o>` returns. Only in normal mode — `m'` during
  an operator or a visual selection would abort the one and collapse the other.
- Running out of targets lands on the last / first line, matching what stock `]]`
  and `[[` do at the ends of a buffer.
- Targets are cached per buffer against `changedtick`.

Buffers with no parser, and files past the large-file threshold
(`util.largefile`), keep the built-in motion.

## Tests

`tests/spec/e2e/ts_sections_spec.lua` covers both tiers and the motion itself.
Buffers are built through the API rather than `:edit`, because the e2e lane
cannot re-edit files of an LSP-attached filetype without dragging a stale
`lsp.log` path into the next spec.
