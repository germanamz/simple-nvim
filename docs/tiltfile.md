# Tiltfiles (`Tiltfile`, `Tiltfile.local`, `*.tiltfile`)

Editor support for [Tilt](https://docs.tilt.dev/) configuration: treesitter
highlighting, folding and indentation through the Starlark grammar, and Tilt's
own language server for completion and docs.

## What you get

| Feature | How |
| --- | --- |
| Filetype | Neovim detects `Tiltfile`, `Tiltfile.local` and `*.tiltfile` as `filetype=tiltfile` on its own; nothing to add. |
| Highlighting | The `starlark` parser (`tree-sitter-grammars/tree-sitter-starlark`, in nvim-treesitter's registry, pinned in `parser-revisions.lua`, installed by `make warm`), with nvim-treesitter's own starlark queries. `lua/plugins/treesitter.lua` registers it for the `tiltfile` filetype — there is no `tiltfile` grammar. `.star` files (`filetype=starlark`) get the same parser and are in the same FileType list. |
| Folds / indent | nvim-treesitter's starlark queries: `def`, `if`/`for`, brackets and strings fold; bodies and continued argument lists indent. |
| Comments, shiftwidth | `ftplugin/starlark.lua`, sourced from `ftplugin/tiltfile.lua`: `commentstring=# %s` (so `gcc` works — the runtime has no ftplugin for either filetype) and a 4-space indent, Starlark's Python convention (what buildifier emits, and what the runtime's python ftplugin gives python buffers here), over the config's global 2. |
| Language server | `tilt_ls` in `lua/plugins/lsp.lua`: `tilt lsp start`, the [starlark-lsp](https://github.com/tilt-dev/starlark-lsp) built into the tilt binary. Completion of builtins and your own defs, hover with Tilt's API docs (`K`), signature help, `gd`, document symbols. It publishes **no diagnostics** and does not format. |

## Which `tilt` runs the server

The row uses the `tilt` on `PATH`, deliberately not a mason-installed one
(mason does carry a `tilt` package). The server knows the builtins of the tilt
it ships in, so the binary that runs your `tilt up` is the one that should
complete and document your Tiltfile. A mason copy would also sit ahead of the
real one on nvim's `PATH` — mason prepends its bin dir — and so shadow it in
every `:terminal`. Without tilt on `PATH` core just skips the server (a line in
`lsp.log`, no notification): the Tiltfile still highlights, it just has no
completion.

## Tests

- `tests/spec/e2e/treesitter_spec.lua` (`make test-e2e`): the parser
  registration, captures on a representative Tiltfile, the ftplugin's options,
  indent and folds.
- `tests/spec/smoke/lsp_filetypes_spec.lua` (`make test-smoke`): `tilt_ls` is
  enabled and is the only server claiming `tiltfile`.
- `tests/spec/e2e-lsp/tilt_ls_spec.lua` (`make test-lsp`): a real
  `tilt lsp start` attaches to a Tiltfile and answers a hover on `docker_build`
  with its docs. Self-skips when there is no `tilt` on `PATH`.
