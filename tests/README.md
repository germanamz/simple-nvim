# Tests

Test harness for this Neovim configuration. Specs run via [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-style runner against a deterministic, pre-warmed plugin cache.

## One-time setup

```sh
make warm
```

Populates `~/.local/share/nvim/lazy/` with all plugins at the revisions pinned in `lazy-lock.json`, plus Mason tools (`mason-tool-versions.lock`) and treesitter parsers (`tests/parser-revisions.lua`). Re-run after pulling in pin changes.

## Running tests

| Command          | What it runs                                         |
| ---------------- | ---------------------------------------------------- |
| `make test`      | unit + smoke + e2e (the default fast lane)           |
| `make test-unit` | unit tests against the plenary-only minimal harness  |
| `make test-smoke`| smoke tests against the full init (no real LSP)      |
| `make test-e2e`  | end-to-end tests against the full init               |
| `make test-lsp`  | slow LSP end-to-end tests (excluded from `make test`)|

### Running a single spec file

```sh
nvim --headless -u tests/full_init.lua \
  -c "PlenaryBustedFile tests/spec/<dir>/<file>_spec.lua"
```

Use `tests/minimal_init.lua` instead for files under `tests/spec/unit/`.

## Updating pins

```sh
make update
```

Bumps `lazy-lock.json`, `mason-tool-versions.lock`, and `tests/parser-revisions.lua` to current versions. Review the diff and commit.

## Layout

```
tests/
├── README.md             — this file
├── minimal_init.lua      — plenary-only harness (unit tests)
├── full_init.lua         — real init.lua + lazy-resolved plugin specs (smoke, e2e, e2e-lsp)
├── parser-revisions.lua  — pinned treesitter parser commits
├── helpers/
│   ├── nvim_env.lua      — isolated XDG dirs; symlinks the host's lazy cache
│   ├── wait.lua          — vim.wait wrappers (wait_for, wait_for_buffer, wait_for_event)
│   ├── keymap_probe.lua  — resolve a keymap to its callback/rhs without firing it
│   └── git_fixture.lua   — build deterministic temp git repos for gitsigns/diffview tests
└── spec/
    ├── unit/             — pure-lua unit tests; no plugin loading
    ├── smoke/            — full init loads cleanly; commands and keymaps registered
    ├── e2e/              — user-visible behaviors end-to-end (no real LSP)
    └── e2e-lsp/          — slow lane: real language servers
```

`_placeholder_spec.lua` files in each `spec/` directory are bridge code: they keep `PlenaryBustedDirectory` happy until real specs land. They are removed by phases 3–6 of the testing plan (`docs/superpowers/plans/2026-04-26-testing/`).
