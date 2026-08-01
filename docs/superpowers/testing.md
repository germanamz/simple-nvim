# Testing and determinism

Two goals, equally weighted:

1. **Confidence to refactor.** The logic-heavy `lua/config/` modules can be
   restructured without silently breaking behavior.
2. **Version-upgrade safety net.** When Neovim, a plugin, a treesitter parser or
   a mason tool changes, a test run says so before you hit it interactively.

The suite is what made the [refactoring](refactoring.md) and
[multi-submodule](git-at-scale.md) work safe to do at all.

## The determinism layer

Same `nvim` boot, same behavior, every machine. Five things can drift; each has
exactly one pin file, so "what pins X?" is grep-answerable.

| Layer | Pin file | Enforced by |
| --- | --- | --- |
| Neovim binary | `.tool-versions` (`neovim 0.12.1`) | `mise` / `asdf` on the machine |
| Plugin sources | `lazy-lock.json` | `init.lua` runs `lazy.restore()` on a fresh install; `config.lock_drift` warns 1 s after startup when an installed clone's commit differs from the lock |
| Mason tools (LSPs, formatters, linters) | `mason-tool-versions.lock` — 27 tools | `lua/plugins/lsp.lua` registers `mason-tool-installer.nvim` from the lockfile; `scripts/mason-sync.lua` drives the install |
| Treesitter parsers | `parser-revisions.lua` at the repo root — 33 parsers | `config.ts_pinned.apply()` rewrites each parser's `install_info.revision` before `nvim-treesitter`'s `install()` runs |
| Test runtime | `NVIM_BOOTSTRAP=0` + scrubbed `$HOME`/`$XDG_*` via `tests/helpers/nvim_env.lua` | `init.lua` skips `lazy.setup` when the env var is `"0"`; specs run against the pre-warmed cache, symlinked in. No downloads during a test run |

The consequence is that plugin and server updates stop being automatic.
`make update` is the deliberate ritual: it bumps all three lock files at once and
leaves the diff staged for review. `make warm` (alias `make sync`) makes a
machine match the committed pins. `make check` verifies without installing
anything and exits non-zero on the first drift.

### Where the design was wrong about parser pinning

The plan assumed one of two mechanisms would work. Neither does at the
`nvim-treesitter` SHA this config pins:

- `install()`'s options are `{ force, generate, max_jobs, summary }`. There is no
  `revision`.
- Parsers are not git checkouts. They are tarball downloads that get built, so
  the fallback "`git checkout <rev>` per parser repo" has nothing to check out.

What actually works — and what `lua/config/ts_pinned.lua` does — is to overwrite
`parser_config[lang].install_info.revision` in memory before calling `install()`.
The installer reads that field when it downloads.

**This only affects parsers that are not yet installed.** `install()` early-returns
for an already-installed parser without consulting the revision, so editing a pin
and restarting Neovim does nothing: the in-memory override is discarded and the
old parser stays. Re-pinning an installed parser requires `make update` or
`make warm`. `:TSUpdate` compares the *bundled* revision, not ours, so it will not
do it either.

`ts_pinned.lua` lives under `lua/config/` rather than `lua/plugins/` only because
lazy.nvim treats every file in `lua/plugins/` as a plugin spec.

Related: `parser-revisions.lua` sits at the repo root, not under `tests/` where the
original layout put it. It is read by production code (`lua/plugins/treesitter.lua`),
not just by specs, and `make lint` covers it explicitly.

### Where the design was wrong about mason

`nvim --headless +"MasonToolsInstallSync" +qa` was a silent no-op twice over:
`mason-tool-installer` is lazy-loaded so the command did not exist yet, and
headless Neovim exits 0 even when a command errors. `scripts/mason-sync.lua`
loads the plugin first and propagates failure; `warm-cache.sh` deliberately keeps
that step's stderr instead of discarding it like the others.

## The suite

Four tiers. `make test` runs the first three; the LSP lane is excluded because it
needs real language servers on `PATH`.

| Tier | Harness | Files | Examples | What it proves |
| --- | --- | --- | --- | --- |
| `make test-unit` | `tests/minimal_init.lua` — plenary + this repo's `lua/` on the rtp | 47 | 742 | Module logic against a real `vim.api`, no plugins loaded |
| `make test-smoke` | `tests/full_init.lua` — the real `init.lua` | 10 | 85 | Structural integrity: init loads clean, no plugin failed, `:checkhealth` reports no errors, and the declarative wiring (keymaps, which-key groups, LSP filetypes, formatter and linter registration) is present |
| `make test-e2e` | `tests/full_init.lua` | 18 | 87 | User-visible flows end to end against real plugins, parsers and synthetic git repos |
| `make test-lsp` | `tests/full_init.lua` | 1 | self-skipping | A real `lua_ls` attaches and completes the initialize handshake |

Green as of 2026-07-31: 76 spec files, 914 examples, `make lint` clean.

Every target goes through `scripts/run-plenary.sh` rather than invoking
`PlenaryBustedDirectory` directly. Plenary spawns one child `nvim` per spec file
and never reaps children that outlive the parent, so a hung spec leaks an orphan.
The script runs the parent in its own process group and `SIGKILL`s whatever
survives.

### The slow lane

`tests/spec/e2e-lsp/_placeholder_spec.lua` kept its placeholder filename but is a
real spec: it drives `lua_ls` end to end and marks itself *pending* when
`lua-language-server` is not on `PATH`, so the lane never fails merely because a
machine lacks the server. It asserts attach plus populated `server_capabilities`
rather than round-tripping a live hover, which keeps it deterministic once the
server is up. There is no `ts_ls` spec.

To exercise the real server rather than self-skip, put mason's bin directory on
`PATH` — the isolated test environment never sees it:

```sh
PATH="$HOME/.local/share/nvim/mason/bin:$PATH" make test-lsp
```

### CI was never built

The design specified a composite `setup-nvim` action, a `test.yml` push/PR
workflow, a nightly `e2e-lsp.yml`, a README badge and a Development section.
**None of it exists** — there is no `.github/` directory in the repo. The pin
checks those workflows would have run are implemented and working
(`make check`), but running them is manual. The README has no CI badge and no
Development section; `tests/README.md` covers the same ground for anyone who
finds it.

## Harness constraints

These cost real time to rediscover.

- **Run `make test-*` with the agent command sandbox disabled.** The smoke and
  e2e tiers spawn headless Neovim that writes swap files, parsers and git state
  outside a sandbox allowlist. Failures under a sandbox are environment errors
  (`E303`, "not writable", git-status mismatches), not logic errors. The unit
  tier is pure enough to survive but disable it for all of them anyway.
- **ShaDa is off on purpose.** Both init scripts set `shadafile = "NONE"` so
  buffer-loading specs never touch the real ShaDa. Do not "fix" it.
- **Running one e2e spec directly needs the full init**, or only bundled parsers
  attach and the Python/HTML/TypeScript cases time out:
  `-c "PlenaryBustedFile <spec> { minimal_init = 'tests/full_init.lua' }"`.
- **Headless Neovim cannot enter insert mode in a telescope prompt**, and
  `CursorMoved` never fires in a `-c luafile` script context because input is
  never drained. Call `nvim_exec_autocmds`, or the module function directly,
  instead of `feedkeys`. Driving mini.surround / mini.ai operator+textobject
  keystrokes this way hangs outright — call `find_textobject` instead.
- **Headless windows are about 43 rows.** A scroll-dependent spec must shrink
  `vim.o.lines` or `winrestview`'s `topline` silently clamps.
- **Do not `:edit` a file with an LSP filetype after the first isolated env.** It
  errors on a stale cached `lsp.log` path and contaminates the next spec. Create
  buffers through the API instead.
- **Float positions lie in headless.** `nvim_win_get_position` and `screenpos`
  report a `relative = "win"` float's position relative to the window *frame*, so
  a headless comparison "proves" a `+1` winbar offset that the renderer does not
  actually apply. See [nvim-tree-context.md](nvim-tree-context.md).
- **A historical exit-2 flake.** In 2026-06 `make test-e2e` occasionally exited 2
  with every example passing — a child `nvim` exiting nonzero on a deliberate
  `:bdelete` `E89` or a shutdown error. The 2026-07-31 sweep exited 0. Confirm a
  real failure by the totals, not the exit code:

  ```sh
  make test-e2e 2>&1 | grep -E "Failed : |Errors : " | grep -vE ": .0[[:space:]]*$"
  # empty output = no real failures
  ```

## Helpers

| File | Surface |
| --- | --- |
| `tests/helpers/nvim_env.lua` | `setup_isolated_env()` / `teardown()`. Fresh `$HOME` and `$XDG_*` under `$TMPDIR`, the host's lazy cache symlinked in, `NVIM_BOOTSTRAP=0`, `TZ=UTC` |
| `tests/helpers/git_fixture.lua` | `repo({ commits, staged, modified, untracked, base_branch })` → path, with pinned author/committer dates so commit SHAs are reproducible; `with_remote(repo, name)`; `superproject({ children, grandchild, worktree, unborn })`; `superproject_pinned_submodule()` for a submodule checked out behind its own branch tip |
| `tests/helpers/keymap_probe.lua` | `resolve(mode, lhs)` → `{ callback, rhs, buffer }`, buffer-local maps before global |
| `tests/helpers/wait.lua` | `wait_for`, `wait_for_buffer`, `wait_for_event` — all `vim.wait` wrappers with explicit failure messages. No `sleep` anywhere in the suite |
