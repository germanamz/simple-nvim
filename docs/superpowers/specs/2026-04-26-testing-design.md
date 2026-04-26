# Testing & Determinism Design

**Date:** 2026-04-26
**Status:** Approved (pending implementation plan)
**Repo:** personal Neovim 0.11+ config (`~/.config/nvim`)

## Goal

Give this config a test suite (unit + smoke + e2e) and turn it into a reproducible artifact: the same `nvim` boot produces the same behavior on every machine and every CI run. "Confident and stable to be used consistently."

This means two things, equally weighted:

1. **Confidence to refactor** the four logic-heavy modules (`lsp_refs`, `review_base`, `telescope_smart`, `options`) without silently breaking behavior.
2. **Version-upgrade safety net** — when Neovim, a plugin, a treesitter parser, or a mason tool changes, CI tells us before we hit it interactively.

## Non-goals

- Coverage reporting (no `luacov`).
- Nightly Neovim matrix. Pinning Neovim is the determinism contract; testing against nightly is the opposite goal. Can live in a separate, failure-non-blocking workflow later.
- Cross-OS matrix. `ubuntu-latest` only. macOS support is implicit because the config already runs there; we don't owe CI proof of it.
- Release automation.

## Framework choice

`plenary.nvim`'s `busted` runner (`PlenaryBustedDirectory`).

- Already in the dependency graph (transitively via Telescope), so no new install cost.
- Real headless Neovim — every `vim.api` / `vim.fn` / `vim.lsp` / autocommand call is real, which matters for `lsp_refs.lua` (extmarks) and `review_base.lua` (autocommands + `vim.fn.systemlist`).
- Standard layout means future contributors / future-self can find their way in seconds.

Alternatives considered: `mini.test` (extra dep, marginal upside); `vusted` (stub'd `vim` API defeats the point of testing config that leans on real Neovim surface).

## Determinism layer

Five enforcement points; one named pin file each, so "what pins X?" is grep-answerable.

| Layer | Pin file | Enforced by |
|---|---|---|
| Neovim binary | `.tool-versions` | `mise`/`asdf` locally; `rhysd/action-setup-vim` in CI reads the same string. CI step asserts `nvim --version` matches. |
| Plugins (sources) | `lazy-lock.json` (already exists) | CI runs `nvim --headless +"Lazy! restore" +qa`, then `git diff --exit-code lazy-lock.json`. Drift = build fails. |
| Mason tools (LSPs, formatters) | `mason-tool-versions.lock` (new, JSON) | `lua/plugins/lsp.lua` registers `mason-tool-installer.nvim` with versions read from this file. Bootstrap step asserts `:MasonToolsCheck` reports no missing/outdated. |
| Treesitter parsers | `tests/parser-revisions.lua` (new; `{ lua = "<sha>", typescript = "<sha>", ... }`) | `lua/plugins/treesitter.lua` calls `require("nvim-treesitter").install(parsers, { revision = revisions[name] })`. CI step compares each installed parser's `git rev-parse HEAD` to the file. |
| Test runtime | `NVIM_BOOTSTRAP=0` env var + `XDG_*` overrides via `tests/helpers/nvim_env.lua` | `init.lua` skips `lazy.setup` when `NVIM_BOOTSTRAP=0`. Tests run against a pre-warmed, symlinked cache. No live downloads during test execution. Local: `make warm` once. |

### Consequences

- **No more automatic plugin/LSP updates.** `:Lazy update` becomes a deliberate ritual: update, then commit `lazy-lock.json` (and `mason-tool-versions.lock` / `parser-revisions.lua` if they changed). A `make update` target bumps all three at once and stages the diff.
- **CI cache is a speed optimization, not a correctness layer.** All five pins above must hold even on a cold-cache run. Cache key = hash of all four pin files; on miss CI does the full install, on hit it restores. Either way the post-install pin checks must pass.

### Caveats

- Not every mason package publishes stable version tags. For those (rare), pin to whatever version-like string the package supports, with a note in the lockfile.
- Treesitter parser revision pinning requires the `main`-branch API of `nvim-treesitter`, which this config already uses.

## Repo layout

```
.tool-versions                          # asdf/mise: neovim X.Y.Z
mason-tool-versions.lock                # JSON: pinned mason tool versions
.github/
  workflows/
    test.yml                            # unit + smoke + e2e on every push/PR
    e2e-lsp.yml                         # workflow_dispatch + nightly cron
  actions/
    setup-nvim/action.yml               # composite, shared by both workflows

tests/
  README.md                             # how to run tests locally
  minimal_init.lua                      # plenary + module-under-test (unit)
  full_init.lua                         # the real init.lua (smoke + e2e)
  parser-revisions.lua                  # { name = "<sha>", ... }
  helpers/
    git_fixture.lua                     # synthetic repos in $TMPDIR
    nvim_env.lua                        # scrub $HOME / $XDG_* / $TZ; symlink cache
    keymap_probe.lua                    # resolve a keymap to its callback
    wait.lua                            # vim.wait wrappers with assertion messages
  spec/
    unit/
      review_base_spec.lua
      lsp_refs_spec.lua
      telescope_smart_spec.lua
      options_spec.lua
    smoke/
      boot_spec.lua
      checkhealth_spec.lua
    e2e/
      telescope_spec.lua
      gitsigns_spec.lua
      diffview_spec.lua
      treesitter_spec.lua
    e2e-lsp/                            # only run by e2e-lsp.yml
      lua_ls_spec.lua
      ts_ls_spec.lua

scripts/
  warm-cache.sh                         # mirrors the composite-action bootstrap, for first-time local
  update-pins.sh                        # bump all four pin files and stage the diff

Makefile                                # test / test-unit / test-smoke / test-e2e / test-lsp / lint / fmt / warm / update
```

### Edits to existing files

- **`init.lua`** — wrap `require("lazy").setup("plugins")` in `if vim.env.NVIM_BOOTSTRAP ~= "0" then ... end`.
- **`lua/plugins/lsp.lua`** — add `mason-tool-installer.nvim`, read versions from `mason-tool-versions.lock`. Drop implicit "install latest".
- **`lua/plugins/treesitter.lua`** — read `tests/parser-revisions.lua`, pass `revision` to `require("nvim-treesitter").install()` per parser.
- **`lua/config/telescope_smart.lua`** — expose `M._git_changes` and `M._merge_results` (small, underscore-prefixed; signals "internal but exposed for tests").

### Cleanups

- Delete `nvim.log` from repo root (debug log artifact).
- Delete `test.mdx` from repo root (appears to be a leftover scratch file).

(Both are flagged for confirmation during implementation, not deleted blindly.)

## Unit-test design

One spec file per module. Every test runs in an isolated `$TMPDIR` with scrubbed `$HOME`/`$XDG_*` (helper handles this).

### `review_base_spec.lua`

- `read_state` returns `{}` for missing file, empty file, malformed JSON; round-trips a non-empty table.
- `write_state` writes atomically (tmp + rename); an interrupted write leaves prior state intact (simulated by mocking `os.rename`).
- `git_root` returns the toplevel for a synthetic repo; `nil` outside a repo and for nonexistent paths.
- `resolve` true for `HEAD`, a tag, a branch; false for `"deadbeef"`, empty string, nil ref.
- `set` / `clear` fire `User ReviewBaseChanged` exactly once with `{ root, ref }` data — listener registered before, asserted after.
- `bootstrap` drops entries whose root vanished or whose ref no longer resolves; preserves valid entries; writes back only when something changed.

### `lsp_refs_spec.lua`

- `M.status()` returns `""` when no state; ` ⇄N ` when state matches cursor; `""` when cursor moved off the recorded position.
- `M.next()` / `M.prev()`: pre-seed extmarks at known ranges, place cursor, assert resulting cursor row/col. Cover wrap forward/backward and the "cursor on a mark" case.
- Reference-request callback: stub `vim.lsp.buf_request` to invoke the registered handler synchronously with a canned `result`. Verify (a) extmarks placed only when count ≥ 2, (b) duplicates dedup'd by `line:character`, (c) responses arriving after cursor moved are dropped.

### `telescope_smart_spec.lua`

- Refactor: expose `M._git_changes` and `M._merge_results`. Keep `smart_files` as the only telescope-touching surface.
- `_git_changes` against a synthetic repo with one staged, one modified, one untracked, two committed-since-base files; assert exact returned tables.
- `_merge_results` covers ordering (staged → modified → untracked → committed → all) and dedup across categories.
- `list_all` fallback: monkey-patch `vim.fn.executable` to flip `rg`/`fd` availability; assert each branch picks the right command.

### `options_spec.lua`

- After `require("config.options")`, assert representative options: `expandtab`, `shiftwidth`, `ignorecase`, `termguicolors`, `clipboard`, `listchars.lead`.
- OSC52 path: with `REMOTE_CONTAINERS=true` set before require, assert `vim.g.clipboard.name == "OSC 52"`. Reset between cases via a child process per case.
- Diff-mode wrap autocmd: register, fire `OptionSet` for `diff` with new value `1`, assert `vim.opt_local.wrap` flipped on a window.

### Not unit-tested (deliberate)

`pick()` in `review_base.lua`, `smart_files()` in `telescope_smart.lua`, the legend floats. These depend on Telescope being loaded; covered by e2e.

## Smoke + e2e design

Each spec runs in an isolated nvim subprocess. `nvim_env.setup_isolated_env()` runs in `before_each`: scrubbed `$HOME`/`$XDG_*` pointed at fresh `$TMPDIR` paths, the pre-warmed `lazy` cache symlinked in, `NVIM_BOOTSTRAP=0`, `$TZ=UTC`. No test touches the real config or real `$HOME`.

### Smoke (cheap; runs on every push)

**`boot_spec.lua`**
- Real `init.lua` loads with no errors (capture `:messages`, assert no `E…:` lines).
- All `lua/config/*` modules `require` cleanly.
- `:Lazy` reports every plugin in `loaded` or `lazy` status — none `failed`.
- Every keymap from a canonical list resolves through `keymap_probe.resolve(mode, lhs)`. Adding a leader mapping that isn't in the list fails the build.

Canonical keymap list (initial; will grow with the config):
`<Space><Space>`, `<Space>ff`, `<Space>fg`, `<Space>gd`, `<Space>gm`, `<Space>gB`, `<Space>e`, `<Space>?`, `<Space>K`, `]c`, `[c`, `]r`, `[r`, `gd`.

**`checkhealth_spec.lua`**
- Runs `:checkhealth nvim-treesitter telescope vim.lsp`, captures buffer text, asserts no `ERROR:` lines. `WARNING:` permitted (e.g., LSP "no clients attached" is normal headless).

### E2e (every push; flows boot/keymaps + Telescope + gitsigns/Diffview + treesitter)

**`telescope_spec.lua`** — for each picker (`<Space>ff`, `<Space>fg`, `<Space><Space>`, `<Space>gB`):
- `cd` into a synthetic repo built by `git_fixture.repo({...})`.
- Send keys via `vim.api.nvim_input()`.
- `wait_for_buffer({ filetype = "TelescopePrompt" })` (default timeout 1500ms).
- Assert prompt title (e.g., `"Files (base: main)"` for smart_files when a base is set).
- Assert results entries — for smart_files, exact ordering: staged ◆ → modified ● → untracked ○ → committed ◈ → everything else.
- Send `<Esc>`, assert prompt buffer closed.

**`gitsigns_spec.lua`** — synthetic repo with a file modified to introduce three known hunks at lines 5, 12, 30:
- Open file, `wait_for(function() return vim.b.gitsigns_status ~= nil end)`.
- `]c` × 3, assert cursor on lines 5 → 12 → 30 → wrap to 5.
- `[c` from line 30 lands on 12.
- Set review base via `review_base.set(root, "main")`, assert gitsigns reattaches against the base (signs change from "vs index" to "vs main") — covers the User-autocmd integration.

**`diffview_spec.lua`** — synthetic repo with `origin/main` (via `git_fixture.with_remote`) and divergent working tree:
- `<Space>gd` opens; assert two windows with expected `diffview://*` buffer names.
- `q` closes; window count returns to baseline.
- `<Space>gm` opens vs `origin/main`; assert title strip mentions `origin/main`.

**`treesitter_spec.lua`** — open a fixture Lua file:
- Wait for `FileType` → `vim.treesitter.start` chain.
- Assert `vim.treesitter.highlighter.active[bufnr]` is non-nil.
- Assert `vim.treesitter.get_captures_at_pos(bufnr, 0, 0)` returns at least one capture.

### LSP e2e (separate workflow; dispatch + nightly cron)

**`lua_ls_spec.lua` / `ts_ls_spec.lua`** — open a fixture file, `wait_for_event("LspAttach")`, then:
- `vim.lsp.buf_request_sync(0, "textDocument/definition", ...)` to a known symbol; assert returned location.
- Edit the file to introduce a known diagnostic, `wait_for(function() return #vim.diagnostic.get(0) > 0 end)`, assert message text.

Pinned `lua_ls` and `ts_ls` are pre-installed by mason in the e2e-lsp workflow's setup step, frozen by `mason-tool-versions.lock`.

### Helpers

| File | Surface |
|---|---|
| `nvim_env.lua` | `setup_isolated_env()`, `teardown()`. Symlinks pre-warmed `lazy` cache. Sets `NVIM_BOOTSTRAP=0`, `$TZ=UTC`. |
| `git_fixture.lua` | `repo({ commits, staged, modified, untracked, base = "main" })` returns a path. Pinned `GIT_AUTHOR_DATE`, `GIT_COMMITTER_DATE`, `user.email`, `user.name`. `with_remote(repo, name)`. |
| `keymap_probe.lua` | `resolve(mode, lhs)` → `{ callback, rhs, buffer }` or `nil`. Walks buffer-local then global maps. |
| `wait.lua` | `wait_for(fn, timeout, msg)`, `wait_for_buffer(opts)`, `wait_for_event(pattern)`. All wrap `vim.wait`; explicit failure messages, no `sleep`. |

### Failure modes deliberately covered

- Plugin update breaks a flow we drive → fails on the next CI run; the `lazy-lock.json` SHA bump is the suspect.
- Treesitter parser ABI bump → caught by `checkhealth_spec.lua`.
- Mason server version drift → caught by `e2e-lsp`; doesn't block daily CI.
- Real wall clock or `$HOME` leakage → impossible by construction.

## CI workflow

### Composite action: `.github/actions/setup-nvim/action.yml`

Inputs: `install-lsp` (boolean, default `false`).

Steps:
1. Install Neovim via `rhysd/action-setup-vim@v1`, version string read from `.tool-versions`.
2. Restore cache for `~/.local/share/nvim` keyed on `hashFiles('lazy-lock.json', 'mason-tool-versions.lock', 'tests/parser-revisions.lua', '.tool-versions')`. Restore-keys fall back to the latest partial match.
3. **On cache miss** — `nvim --headless +"Lazy! restore" +qa`, then a bootstrap script that:
   - Installs treesitter parsers at revisions from `tests/parser-revisions.lua`.
   - If `install-lsp == true`: runs `:MasonToolsInstall` against `mason-tool-versions.lock`.
4. **Pin checks (always run)**:
   - `git diff --exit-code lazy-lock.json`.
   - For every installed parser: `git rev-parse HEAD` matches `tests/parser-revisions.lua`.
   - If `install-lsp == true`: `:MasonToolsCheck` reports clean.
5. Save cache on miss.

### `.github/workflows/test.yml` — push + PR

```yaml
on:
  push: { branches: [main] }
  pull_request:
concurrency:
  group: test-${{ github.ref }}
  cancel-in-progress: true
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: JohnnyMorganz/stylua-action@v4
        with: { args: --check lua init.lua tests }
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-nvim
      - run: make test-unit
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-nvim
      - run: make test-smoke
  e2e:
    needs: [smoke]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-nvim
      - run: make test-e2e
```

`unit`, `smoke`, `e2e` each restore the same shared cache. `e2e` depends on `smoke` so a broken boot doesn't waste the e2e budget. `unit` and `lint` run in parallel with `smoke`.

### `.github/workflows/e2e-lsp.yml` — slow lane

```yaml
on:
  workflow_dispatch:
  schedule:
    - cron: "0 7 * * *"   # 07:00 UTC daily
jobs:
  e2e-lsp:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-nvim
        with: { install-lsp: true }
      - run: make test-lsp
```

Failure here notifies via the default GitHub email on failed scheduled run; doesn't block PRs.

### `Makefile`

```makefile
test:        test-unit test-smoke test-e2e
test-unit:   ; @nvim --headless -u tests/minimal_init.lua \
                  -c "PlenaryBustedDirectory tests/spec/unit { minimal_init = 'tests/minimal_init.lua' }"
test-smoke:  ; @nvim --headless -u tests/full_init.lua \
                  -c "PlenaryBustedDirectory tests/spec/smoke { minimal_init = 'tests/full_init.lua' }"
test-e2e:    ; @nvim --headless -u tests/full_init.lua \
                  -c "PlenaryBustedDirectory tests/spec/e2e { minimal_init = 'tests/full_init.lua' }"
test-lsp:    ; @nvim --headless -u tests/full_init.lua \
                  -c "PlenaryBustedDirectory tests/spec/e2e-lsp { minimal_init = 'tests/full_init.lua' }"
warm:        ; @scripts/warm-cache.sh
update:      ; @scripts/update-pins.sh
lint:        ; @stylua --check lua init.lua tests
fmt:         ; @stylua lua init.lua tests
```

First-time local setup is `make warm`; subsequent `make test` is fast and offline.

## README updates

- CI badge: `![CI](https://github.com/<owner>/<repo>/actions/workflows/test.yml/badge.svg)`.
- New "Development" section: how to run tests (`make warm` once, then `make test`), how to update pins (`make update`).

## Open questions / risks

- **`test.mdx` and `nvim.log` in repo root.** Look like leftover scratch artifacts (`test.mdx` is in `.gitignore`'s spirit but tracked; `nvim.log` is in `.gitignore` already). Confirm before deleting.
- **`mason-tool-installer.nvim` vs vanilla `mason-lspconfig` `ensure_installed`.** The current `lua/plugins/lsp.lua` uses `ensure_installed` with names only — no version hook. We need `mason-tool-installer` (or equivalent) to express "install version X". Confirm the plugin choice during implementation; if there's a less-intrusive alternative we'll use it.
- **Treesitter parser pinning ergonomics.** `nvim-treesitter` (`main` branch) accepts `{ revision = ... }`, but the install command's per-parser revision support has been evolving. Verify against the version pinned in `lazy-lock.json` during implementation; fall back to a thin custom installer if the API doesn't expose it.
