# Phase 1: Determinism foundations

**Prerequisites:** none — clean codebase as of commit `0ee05de` (testing design spec committed).
**Can run in parallel with:** nothing. Phase 2 depends on this.
**Estimated tasks:** 6

## Goal

Establish the determinism layer documented in the design spec (`docs/superpowers/specs/2026-04-26-testing-design.md`, section "Determinism layer"): pin Neovim, Mason tools, and treesitter parsers; gate `init.lua`'s plugin bootstrap on an env var so tests can run against a pre-warmed cache; provide `make warm` and `make update` so the user has a ritual for both populating and bumping pins.

After this phase the repo can be cloned to a fresh machine, `make warm` populates a deterministic cache, and `nvim` launches behaving identically to before. Daily `nvim` use is unchanged because `NVIM_BOOTSTRAP` defaults to enabled.

## Context

- Design spec sections: "Determinism layer" (the table), "Edits to existing files".
- `init.lua` (current state) bootstraps lazy.nvim and calls `require("lazy").setup("plugins")` at the bottom.
- `lua/plugins/lsp.lua` declares servers in the `servers` table at top, sets `ensure_installed = vim.tbl_keys(servers)` in `mason-lspconfig`'s `config` function. The current installed-version map of those servers is what the new `mason-tool-versions.lock` records.
- `lua/plugins/treesitter.lua` calls `require("nvim-treesitter").install(parsers)` with a list of parser names and no revisions.
- `lazy-lock.json` already exists and is committed; do not edit it manually in this phase.

## Tasks

### Task 1: pin Neovim version + gate `init.lua` bootstrap

1. Create `.tool-versions` at repo root, single line:
   ```
   neovim 0.11.X
   ```
   where `X` is the latest stable 0.11 patch release at implementation time. Verify with `nvim --version` that the locally-running binary matches; if it doesn't, prefer the locally-running version (matching the user's working state).

2. Modify `init.lua`: wrap the final `require("lazy").setup("plugins")` line in a conditional:
   ```lua
   if vim.env.NVIM_BOOTSTRAP ~= "0" then
     require("lazy").setup("plugins")
   end
   ```
   The bootstrap-of-lazy itself (the `git clone` block at the top of `init.lua`) stays unconditional — that just adds lazy to the runtimepath; it doesn't install plugins.

**Acceptance:** `NVIM_BOOTSTRAP=0 nvim --headless +qa` exits 0 with no plugin install. Plain `nvim --headless +qa` triggers the regular bootstrap as before.

### Task 2: pin Mason tool versions

1. Add `WhoIsSethDaniel/mason-tool-installer.nvim` as a new lazy.nvim spec inside `lua/plugins/lsp.lua`'s returned table (after the existing three plugin specs).

2. Create `mason-tool-versions.lock` at repo root: a JSON object mapping each tool from the `servers` table in `lua/plugins/lsp.lua` to its currently-installed version. To get current versions, read `~/.local/share/nvim/mason/packages/<name>/.mason-package.json` (the `version` field) for each installed tool. If a tool is not installed locally, omit it from the lockfile and note this in the implementation message — do not guess versions. Sort keys alphabetically so future diffs are stable.

3. In `lua/plugins/lsp.lua`, configure `mason-tool-installer` to read the lockfile and pass `ensure_installed = { { name, version = "..." }, ... }`. Set `mason-lspconfig.setup({ ensure_installed = {} })` to avoid races (keep `mason-lspconfig` for `vim.lsp.config` integration).

   **Fallback path** (use only if `mason-tool-installer` cannot express per-tool versions at the SHA pinned in `lazy-lock.json`): create `lua/plugins/_mason_pinned.lua` exporting `setup(versions_table)` that uses `require("mason-registry")` to install each tool at its pinned version. Wire it into `lua/plugins/lsp.lua` instead of `mason-tool-installer`. Document the fallback choice in a top-of-file comment in `_mason_pinned.lua`.

**Acceptance:** `nvim --headless +"MasonToolsCheck" +qa` (or fallback equivalent) reports no missing/outdated tools when run against the warm cache. Lockfile keys sorted alphabetically.

### Task 3: pin treesitter parser revisions

1. Create `tests/parser-revisions.lua` returning a table mapping each parser in `lua/plugins/treesitter.lua`'s `parsers` list to its currently-installed git revision. Read each parser's revision from the local nvim-treesitter install (the `main` branch records the per-parser revision under `~/.local/share/nvim/site/pack/*/start/nvim-treesitter/parser-info/<name>.revision` or via the registry — find the actual location at the pinned SHA). Omit parsers not currently installed locally.

   ```lua
   -- tests/parser-revisions.lua
   return {
     lua        = "abcdef0123...",
     typescript = "...",
     -- ...
   }
   ```

2. Modify `lua/plugins/treesitter.lua`'s `config` function: replace `require("nvim-treesitter").install(parsers)` with a per-parser loop that passes `{ revision = revs[name] }` when an entry exists:
   ```lua
   local revs = require("tests.parser-revisions")
   local nts = require("nvim-treesitter")
   for _, name in ipairs(parsers) do
     if revs[name] then
       nts.install({ name }, { revision = revs[name] })
     else
       nts.install({ name })
     end
   end
   ```

   **Fallback path** (use only if `nvim-treesitter`'s `main`-branch `install()` doesn't accept `{ revision = ... }` at the SHA in `lazy-lock.json`): write `lua/plugins/_ts_pinned.lua` that, after parsers install, runs `git -C <parser-repo> checkout <revision>` per pinned parser then re-builds. Document the fallback in a top-of-file comment.

**Acceptance:** After `make warm`, every parser in `tests/parser-revisions.lua` has `git rev-parse HEAD` in its repo equal to the recorded SHA.

### Task 4: `scripts/warm-cache.sh`

Create `scripts/warm-cache.sh` (chmod 755) — POSIX sh, `set -eu`. Accepts an optional `--check-only` flag.

**Without flag** (default — full warm):

1. `nvim --headless +"Lazy! restore" +qa` — installs plugins at lockfile SHAs.
2. `nvim --headless +"TSUpdate sync" +qa` (or whatever the chosen treesitter pinning approach exposes) — installs parsers at pinned revisions.
3. `nvim --headless +"MasonToolsInstall" +qa` (or fallback equivalent).
4. Run the check block (below).

**With `--check-only` flag** (CI composite action calls this on every run, including cache hits):

Only run the check block. Skip install steps.

**Check block** (defined as a shell function inside the script so both modes share it):

1. **Lockfile honored:** `nvim --headless +"Lazy! restore" +qa && git diff --exit-code lazy-lock.json` — fails if `Lazy! restore` perturbed the lockfile.
2. **Parser revisions match:** for each `name = "<sha>"` entry in `tests/parser-revisions.lua`, locate the parser's installed git repo (the path layout depends on `nvim-treesitter`'s pinning approach chosen in Task 3 — document it in this script), run `git -C <path> rev-parse HEAD`, compare to the expected SHA. Fail with the parser name and both SHAs on mismatch.
3. **Mason tools match:** `nvim --headless +"MasonToolsCheck" +qa` (or fallback equivalent), capture stdout, fail if it reports any tool as `to install` or `outdated`.

Each step exits non-zero with a clear stderr message ("Lazy restore failed", "parser <name> revision mismatch: expected X got Y", etc.).

**Acceptance:**
- `bash scripts/warm-cache.sh` against an empty `~/.local/share/nvim/lazy` populates a fresh cache and exits 0.
- `bash scripts/warm-cache.sh --check-only` against the warm cache exits 0.
- With `tests/parser-revisions.lua` deliberately edited to a wrong SHA, `bash scripts/warm-cache.sh --check-only` exits non-zero with a clear message.

### Task 5: `scripts/update-pins.sh`

Create `scripts/update-pins.sh` (chmod 755) — POSIX sh, `set -eu`. Steps:

1. `nvim --headless +"Lazy! sync" +qa` — pulls latest plugins, rewrites `lazy-lock.json`.
2. Refresh `mason-tool-versions.lock` from the now-installed mason packages (same source-of-truth logic Task 2 used).
3. Refresh `tests/parser-revisions.lua` from the now-installed treesitter parsers.
4. `git status --short` to show the diff. **Do not auto-commit** — the user reviews and commits manually.

**Acceptance:** Running `make update` after a deliberate plugin update produces a diff that, once committed, leaves the repo in a state where `make warm` reproduces the same cache.

### Task 6: `Makefile` (warm/update/lint/fmt)

Create `Makefile` at repo root with these targets (test targets are added in Phase 2):

```makefile
.DEFAULT_GOAL := help
.PHONY: help warm update lint fmt

help:
	@echo "Targets:"
	@echo "  warm    Populate the deterministic plugin cache (run once after clone)"
	@echo "  update  Bump all pin files (lazy-lock, mason-tool-versions, parser-revisions)"
	@echo "  lint    Run stylua --check"
	@echo "  fmt     Run stylua --write"

warm:
	@./scripts/warm-cache.sh

update:
	@./scripts/update-pins.sh

lint:
	@stylua --check lua init.lua

fmt:
	@stylua lua init.lua
```

Note: `lint`/`fmt` use stylua's defaults this phase (no `stylua.toml` yet). Phase 2 widens the targets to include `tests/` and adds `stylua.toml`.

**Acceptance:** `make warm`, `make update`, `make lint`, `make fmt` all exit 0 against the user's working state. Bare `make` prints the help text.

## User-visible behaviors that must still work

- `nvim` (no env vars) launches and bootstraps plugins exactly as before.
- `:Mason` opens, lists installed servers.
- `:checkhealth nvim-treesitter` reports no errors.
- Every keymap documented in `README.md` continues to work.

## Verification

```bash
# 1. NVIM_BOOTSTRAP gate
NVIM_BOOTSTRAP=0 nvim --headless +qa             # exits 0, no install
nvim --headless +qa                              # normal bootstrap

# 2. Determinism scripts
rm -rf ~/.local/share/nvim/lazy
make warm
test -d ~/.local/share/nvim/lazy/lazy.nvim

# 3. Lockfile invariants
nvim --headless +"Lazy! restore" +qa
git diff --exit-code lazy-lock.json              # clean
nvim --headless +"MasonToolsCheck" +qa           # no missing/outdated

# 4. Lint
make lint
```

## Changes Introduced

**New files:**
- `.tool-versions`
- `mason-tool-versions.lock`
- `tests/parser-revisions.lua`
- `scripts/warm-cache.sh`, `scripts/update-pins.sh`
- `Makefile`
- (conditional) `lua/plugins/_mason_pinned.lua` if mason fallback used.
- (conditional) `lua/plugins/_ts_pinned.lua` if treesitter fallback used.

**Modified files:**
- `init.lua` — `lazy.setup` gated on `NVIM_BOOTSTRAP ~= "0"`.
- `lua/plugins/lsp.lua` — adds `mason-tool-installer.nvim` (or fallback) reading `mason-tool-versions.lock`; `mason-lspconfig`'s `ensure_installed` set to `{}`.
- `lua/plugins/treesitter.lua` — `install` loop with per-parser `revision`.
- `lazy-lock.json` — auto-updated by `Lazy! restore` to record the new `mason-tool-installer.nvim` entry.

**New env vars:**
- `NVIM_BOOTSTRAP` — `"0"` skips lazy plugin install. Default behavior unchanged.

**New dependencies (lazy.nvim):**
- `WhoIsSethDaniel/mason-tool-installer.nvim` (or fallback: no new dep, custom shim).

**Bridge code:** none.
