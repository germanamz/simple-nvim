# Phase 6: CI + LSP e2e + cleanup

**Prerequisites:** Phases 3, 4, 5 all complete.
**Can run in parallel with:** nothing — final phase.
**Estimated tasks:** 6

## Inherits From

After Phases 3–5:
- All four unit specs in `tests/spec/unit/` passing.
- Two smoke specs in `tests/spec/smoke/` passing.
- Four e2e specs in `tests/spec/e2e/` passing.
- All `_placeholder_spec.lua` bridges removed except `tests/spec/e2e-lsp/_placeholder_spec.lua`.
- `make test` (unit + smoke + e2e) green locally against `make warm`.

## Goal

Take the local-only suite and turn it into the always-on CI safety net described in the design spec. Add LSP e2e specs (slow lane). Update README. Clean up stray repo artifacts.

## Context

- Design spec section "CI workflow" — composite action, both workflows, cache key strategy.
- `tests/full_init.lua` already works in CI as-is — CI just calls the same `make test*` targets.
- `nvim.log` is in `.gitignore` already but currently tracked. `test.mdx` is a leftover scratch file with no clear purpose.

## Tasks

### Task 1: composite action `.github/actions/setup-nvim/action.yml`

Inputs: `install-lsp` (boolean string, default `"false"`).

Steps:

1. **Read `.tool-versions`** — extract the Neovim version into a step output. Use `id: read-version` and `echo "version=..." >> $GITHUB_OUTPUT`.

2. **Install Neovim** — `rhysd/action-setup-vim@v1` with `version: ${{ steps.read-version.outputs.version }}` and `neovim: true`.

3. **Restore cache** — `actions/cache/restore@v4`:
   - path: `~/.local/share/nvim`
   - key: `nvim-${{ runner.os }}-${{ hashFiles('lazy-lock.json', 'mason-tool-versions.lock', 'tests/parser-revisions.lua', '.tool-versions') }}`
   - restore-keys: progressive prefixes for partial restores.
   - Capture `cache-hit` output for branching.

4. **Cache miss path** — `if: steps.restore.outputs.cache-hit != 'true'`. Run `bash scripts/warm-cache.sh`. (`warm-cache.sh` already does plugin install, parser install, and pin checks.)

5. **(Conditional) Install LSP tools** — `if: inputs.install-lsp == 'true'`. Run `nvim --headless +"MasonToolsInstall" +qa` (or fallback equivalent if Phase 1 used the Mason fallback).

6. **Pin checks (always run, also on cache hit):**
   ```yaml
   - name: pin checks
     shell: bash
     run: bash scripts/warm-cache.sh --check-only
   ```
   Phase 1's `warm-cache.sh` accepts `--check-only` to run the lockfile-clean / parser-revision / Mason-tool checks without re-installing. The mason-tools check inside `--check-only` is gated on whether mason packages are present, so it's a no-op when `install-lsp` is `'false'` (and a real check when `'true'`).

7. **Save cache** — `actions/cache/save@v4` `if: steps.restore.outputs.cache-hit != 'true'`.

**Acceptance:** First push to a feature branch: cache miss → warm → pin checks pass → cache saved. Subsequent pushes within the same lockfile hash: cache hit, pin checks still run.

### Task 2: `.github/workflows/test.yml`

```yaml
name: test
on:
  push:
    branches: [main]
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
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: latest
          args: --check lua init.lua tests
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

**Acceptance:** A push to a feature branch triggers all four jobs; all pass.

### Task 3: `.github/workflows/e2e-lsp.yml`

```yaml
name: e2e-lsp
on:
  workflow_dispatch:
  schedule:
    - cron: "0 7 * * *"
jobs:
  e2e-lsp:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup-nvim
        with:
          install-lsp: "true"
      - run: make test-lsp
```

**Acceptance:** `gh workflow run e2e-lsp.yml` triggers the job; LSP tools install at pinned versions; `make test-lsp` runs and passes.

### Task 4: LSP e2e specs + remove placeholder

`tests/spec/e2e-lsp/lua_ls_spec.lua`:

`before_each`: `nvim_env.setup_isolated_env()`.

1. Build a fixture with `sample.lua` containing:
   ```lua
   local function add(a, b)
     return a + b
   end

   add(1, 2)
   ```
2. `vim.cmd("edit " .. repo .. "/sample.lua")`.
3. Wait for LSP attach. Use a real autocmd listener (User-pattern `wait_for_event` won't fire for `LspAttach`):
   ```lua
   local attached = false
   vim.api.nvim_create_autocmd("LspAttach", { once = true, callback = function() attached = true end })
   wait.wait_for(function() return attached end, 5000, "lua_ls did not attach")
   ```
4. Place cursor on `add` in the call site (line 5, column 0). Request definition:
   ```lua
   local params = vim.lsp.util.make_position_params(0, "utf-16")
   local result = vim.lsp.buf_request_sync(0, "textDocument/definition", params, 5000)
   ```
   Assert at least one client returned a non-empty result; the first location's `range.start.line == 0` (function definition).
5. Insert a syntax error: `vim.api.nvim_buf_set_lines(0, 0, 0, false, { "local x x = 1" })`. `vim.cmd("write")`. `wait.wait_for(function() return #vim.diagnostic.get(0) > 0 end, 5000)`. Assert at least one diagnostic with `severity == vim.diagnostic.severity.ERROR`.

`tests/spec/e2e-lsp/ts_ls_spec.lua`: same shape with TypeScript.

```ts
function add(a: number, b: number): number {
  return a + b;
}

add(1, 2);
```

Wait for `LspAttach` (ts_ls), request definition on `add` call site, expect line 0. Then insert syntax error (`const x x = 1;`), wait for diagnostic, assert ERROR.

After both pass, delete `tests/spec/e2e-lsp/_placeholder_spec.lua`.

**Acceptance:** `make test-lsp` passes locally (after `make warm` includes LSP install via `mason-tool-installer` running with the lockfile). Both spec files exist; placeholder removed.

### Task 5: README updates

Modify `README.md`:

1. **Add a CI badge** near the top (immediately after the `# Neovim Config` heading):
   ```markdown
   ![CI](https://github.com/<owner>/<repo>/actions/workflows/test.yml/badge.svg)
   ```
   Determine `<owner>/<repo>` from `git remote get-url origin`. If it's a GitHub URL (e.g., `git@github.com:foo/bar.git` or `https://github.com/foo/bar.git`), substitute the parsed `foo/bar`. If origin is missing or non-GitHub, leave the literal `<owner>/<repo>` and add an HTML comment immediately after the badge: `<!-- TODO: replace <owner>/<repo> when origin is set up -->`.

2. **Add a `## Development` section** between `## Setup` and `## What's included`:

   ```markdown
   ## Development

   ### One-time setup

   After cloning, populate the deterministic plugin cache:

   ```sh
   make warm
   ```

   ### Running tests

   ```sh
   make test         # unit + smoke + e2e
   make test-unit    # logic-module unit tests
   make test-smoke   # boot + checkhealth
   make test-e2e     # Telescope / gitsigns / Diffview / treesitter
   make test-lsp     # slow lane: lua_ls / ts_ls (manual)
   ```

   ### Updating pins

   Plugins, Mason tools, and treesitter parsers are pinned. To bump them:

   ```sh
   make update       # rewrites lazy-lock.json, mason-tool-versions.lock, tests/parser-revisions.lua
   git diff          # review
   git commit -am "Update plugin pins"
   ```

   ### Linting

   ```sh
   make lint         # stylua --check
   make fmt          # stylua --write
   ```
   ```

**Acceptance:** README renders correctly on GitHub. Badge resolves. Development section reads cleanly.

### Task 6: cleanup

Confirm and remove stray repo artifacts:

- **`nvim.log`** — matches the `*.log` pattern in `.gitignore`. Tracked but in-gitignore: almost certainly committed by accident. Action: `git rm nvim.log` (and check it's not load-bearing — `grep -r 'nvim.log' lua/ init.lua` should return nothing).
- **`test.mdx`** — 2.2KB at repo root, not in `.gitignore`, no clear purpose given the config's structure. Action: read its contents (`Read` tool); if it's a scratch/example file, `git rm test.mdx`. If it appears to be load-bearing (e.g., referenced by `lua/plugins/render-markdown.lua` or used as a test fixture for treesitter mdx parsing), keep it and document why in the implementation message.

Either way, in the implementation message note which decision was made for each file and the reason.

**Acceptance:** `nvim.log` removed (or kept with explicit reason). `test.mdx` removed (or kept with explicit reason).

## User-visible behaviors that must still work

- All Phase 1–5 behaviors.
- `git push` to a feature branch triggers CI; CI must be green for the work in this phase to be considered done.
- `nvim` daily use unchanged.

## Verification

```bash
# Local
make test                             # all green
make test-lsp                         # passes (after LSP tools installed via warm + tool-installer)
make lint                             # clean

# CI (verify on a real push)
git push --set-upstream origin <test-branch>
gh run watch                          # all four jobs (lint, unit, smoke, e2e) pass

# LSP slow-lane (manual)
gh workflow run e2e-lsp.yml
gh run watch                          # passes
```

## Changes Introduced

**New files:**
- `.github/actions/setup-nvim/action.yml`
- `.github/workflows/test.yml`
- `.github/workflows/e2e-lsp.yml`
- `tests/spec/e2e-lsp/lua_ls_spec.lua`
- `tests/spec/e2e-lsp/ts_ls_spec.lua`

**Modified files:**
- `README.md` — CI badge, new "Development" section.

**Removed files:**
- `tests/spec/e2e-lsp/_placeholder_spec.lua` (bridge from Phase 2).
- `nvim.log` (cleanup; conditional on confirmation).
- `test.mdx` (cleanup; conditional on confirmation).

**No new env vars, no new dependencies, no bridge code introduced.**
