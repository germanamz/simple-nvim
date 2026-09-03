# Comments: continuation and reflow

Doc comments are typed one line at a time, and the runtime helps only in some
languages. This config makes every code buffer behave the same way, and gives
`gq` a way to reflow a comment, which the project formatter never touches. The
code is `lua/config/comments.lua`; the wiring is in `lua/config/options.lua`
(the `FileType` policy and the two keys) and `lua/plugins/conform.lua` (the
`formatexpr` sites).

## What you get

| Feature | How |
| --- | --- |
| Enter continues the comment | `formatoptions` flag `r`, forced on for every code buffer by a catch-all `FileType` autocmd that runs after the runtime ftplugin. `$VIMRUNTIME/ftplugin/go.vim` only does `formatoptions-=t` and never adds `r`, so Go sat at `cqj`; python and fga sat on Neovim's bare `tcqj`; lua, c, typescript, sh, yaml and zig already had `croql`. The config's own starlark/tiltfile ftplugins had the same gap. |
| `o` / `O` never continue a comment | flag `o` removed everywhere, including where the runtime added it. A normal-mode `o` is a plain line in every language. |
| Enter on the empty leader ends the comment | the insert-mode `<CR>` map (`comments.cr`) sees a line that is only the leader Neovim just inserted, leader plus trailing space, and clears it back to the indent with `<C-w>`. A bare `//` you typed has no trailing space and keeps continuing: it is Go's paragraph separator. The line after it gets a fresh `// ` (Neovim alone would copy the leader bare). |
| Comments wrap while you type | flag `c`, which every filetype already had, plus the buffer's `textwidth`. No default width is set: only a project's `.editorconfig` `max_line_length` turns this on (Neovim's builtin editorconfig support sets `textwidth` after `FileType`, so it wins). Flag `t` is removed so code never wraps; `l` leaves lines that were already long alone. |
| `gqc` reflows the comment under the cursor | `comments.reflow` finds the block (`comments.block`) and formats exactly those lines with Neovim's internal formatter (`{count}gww`) at `textwidth`, or 79 when it is 0: the internal formatter's own cap, pinned so a narrow split does not change the result. |
| `gq` over comment lines reflows them too | `formatexpr` is `comments.formatexpr`, a wrapper around conform's. A range that is only comment lines returns 1, which makes Neovim use its internal, `'comments'`-aware formatter; anything else goes to conform as before. `gqgc` (Neovim's builtin comment textobject) and a visual selection of comment lines both work. |
| gofmt bullets survive a reflow | flag `n` plus a `formatlistpat` that also matches `-`, `*` and `+` items, so `//   - item` lists keep one item per line with a hanging indent. |

Markdown and the prose filetypes (`text`, `gitcommit`, `mail`) are left alone;
their ftplugins want `t`.

## What a comment block is

`comments.block(buf, row)` returns the 0-indexed inclusive row range, or nil:

- consecutive comment-only lines: treesitter comment nodes, or a
  `commentstring` prefix match when the buffer has no parser or is past
  `util.largefile`'s bound (a fresh whole-buffer parse would stall);
- sharing one leader, the punctuation the line starts with, so `//`, `///`,
  `//!` and `---@` are different blocks;
- directives, a leader glued to a word (`//go:build`, `//nolint`, `#!/bin/sh`,
  `---@param`), are boundaries and never a block themselves;
- bare-leader lines (`//`) belong to the block; the internal formatter keeps
  them as paragraph breaks;
- a multi-line comment node (`/* … */`, `--[[ … ]]`) is one block;
- a trailing comment (`x := 1 // note`) is not comment-only.

## Why not `gqip`

The internal formatter has no idea where a comment ends. `gwip` on a doc
comment directly above a `func` pulls the function's lines into the comment,
verified in a real terminal:

```go
// requests func (s *Server)
// ListenAndServe() error { return nil }
```

Only a range scoped to the block is safe. That is what `gqc` computes, and what
the `formatexpr` wrapper insists on before choosing the internal formatter.

## Why `gq` alone could not do it

conform's `formatexpr` returns 0 unconditionally in normal mode, so Neovim never
falls back to its own formatter, and for Go it runs gofmt over the whole buffer
applying only the hunks in range. gofmt, stylua, rustfmt and shfmt never rewrap
a comment, so `gq` on one was a silent no-op. In insert mode conform does
return 1, which is why typing-time wrapping needed nothing beyond `textwidth`.

## Decisions

| Question | Decision |
| --- | --- |
| Continue on `o` / `O` too? | No. VS Code, Zed and JetBrains continue on Enter only; Helix and Neovim's own ftplugins also on `o`. Enter only, removed everywhere so every language matches. |
| Default comment width? | None. Editorconfig `max_line_length` only; `gqc` uses 79 without one. |
| Which empty lines end the comment? | The fresh leader only (leader plus trailing space). A bare `//` is a paragraph separator and continues, with a fresh `// ` on the next line. |
| Reflow key | `gqc`, mirroring `gcc`. |

**Rejected:** a mini.ai `c` textobject (the builtin `gc` operator-pending
textobject already selects a comment block: `vgc`, `gqgc`); a default
`textwidth` of 80 (hands line-length authority away from editorconfig, which
the markdown handler and its test say this config does not do); clearing a
stray leader on `<Esc>` (Vim leaves `//` behind when you `o` then `<Esc>`;
`<C-u>` clears it); a `<CR>` map that inserts the newline through the API
(blink's fallback schedules a non-expr callback and gets no newline from it,
and multicursor replays the redo record, which an API edit never enters);
`<C-u>` to clear the fresh leader (it deletes only the characters typed since
insert started, which after a bare-leader continuation is just the space).

## Known limits

- blink.cmp strips `c` (and `t`, `a`) from `formatoptions` while its menu is
  open and restores them on close, so typing-time wrapping pauses while the
  popup is up.
- A second `<CR>` already queued behind the first (a macro, a pasted burst) on
  a bare `//` line is resolved while the space is still in typeahead, sees the
  bare leader again and continues instead of ending the comment. Typed keys
  never queue that way.
- `r` also continues `//go:build` directives; `<C-u>` clears the leader.
- Accepting an AI suggestion inserts through the API, so a multi-line accept
  carries no leaders.
- A `gq` range spanning two blocks with different leaders (`//` then `///` in
  Go, whose `'comments'` knows only `//`) is all comment lines, so the internal
  formatter gets it and merges them. `gqc` never does.

## Tests

- `tests/spec/unit/comments_spec.lua` (`make test-unit`): the fresh and bare
  leader predicates, the policy per filetype, block finding (treesitter and
  fallback), reflow width and bullets, the `<CR>` map driven by feedkeys, and
  `formatexpr` routing against a stubbed conform.
- `tests/spec/unit/options_spec.lua`: the `FileType` wiring and both maps.
- `tests/spec/e2e/comments_spec.lua` (`make test-e2e`): the live `<CR>` path
  through blink's buffer-local map, `gqc`, and `gq` with conform force-loaded.
  conform is lazy; without loading it an API-built buffer has an empty
  `formatexpr` and a `gq` test passes for the wrong reason.
