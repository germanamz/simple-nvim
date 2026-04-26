# Phase 3: Unit tests

**Prerequisites:** Phase 2 complete.
**Can run in parallel with:** Phase 4 (smoke), Phase 5 (e2e). Different `tests/spec/*` dirs, different placeholder removals; no shared file edits except for Phase 3's small refactor of `lua/config/telescope_smart.lua`, which neither Phase 4 nor 5 touches.
**Estimated tasks:** 5

## Inherits From

After Phase 2, the codebase has:
- `tests/minimal_init.lua` — loads plenary + the project's `lua/` on rtp.
- `tests/helpers/{nvim_env,wait,keymap_probe,git_fixture}.lua`.
- `Makefile` with `test-unit` invoking `PlenaryBustedDirectory tests/spec/unit`.
- `tests/spec/unit/_placeholder_spec.lua` — passing placeholder.
- `stylua.toml` at repo root.
- `~/.local/share/nvim` warmed via `make warm` (Phase 1).

## Goal

Cover every branch of the four `lua/config/` modules with unit tests run against a real Neovim API (no stubbing of `vim.api`/`vim.fn`/autocommands). Includes a small refactor in `telescope_smart.lua` to expose `_git_changes` and `_merge_results` for direct testing. After this phase, `make test-unit` runs four real spec files and the unit placeholder is gone.

## Context

- Design spec section "Unit-test design" describes the per-module assertions.
- Targets: `lua/config/review_base.lua`, `lua/config/lsp_refs.lua`, `lua/config/telescope_smart.lua`, `lua/config/options.lua`.
- `tests/helpers/git_fixture.lua` builds synthetic repos with deterministic commits.
- `tests/helpers/nvim_env.lua` provides isolated `$HOME`/`$XDG_*`.

## Tasks

### Task 1: refactor `telescope_smart.lua`

Edit `lua/config/telescope_smart.lua`:

1. Promote the local `git_changes(root, base)` to `M._git_changes`. Same body; just attach to the module table with an underscore prefix.

2. Extract the result-merging logic from inside `M.smart_files()` (the block beginning `local seen, results = {}, {}` through the `for _, f in ipairs(all)` loop) into `M._merge_results(staged, modified, untracked, committed, all_files)` returning a single ordered, deduped list. `M.smart_files()` calls it.

The underscore prefix signals "internal but exposed for tests".

**Acceptance:** `lua/config/telescope_smart.lua` exposes `M._git_changes` and `M._merge_results`. `M.smart_files()` still works (manual smoke: `nvim --headless -u tests/full_init.lua +"lua require('config.telescope_smart').smart_files()" +qa` runs without error in a git repo).

### Task 2: `tests/spec/unit/options_spec.lua`

Cover:
- After `require("config.options")`, assert representative options:
  - `vim.opt.expandtab:get() == true`
  - `vim.opt.shiftwidth:get() == 2`
  - `vim.opt.ignorecase:get() == true`
  - `vim.opt.termguicolors:get() == true`
  - `vim.opt.clipboard:get()` contains `"unnamedplus"`
  - `vim.opt.listchars:get().lead == "·"`
- OSC52 path: with `vim.env.REMOTE_CONTAINERS = "true"` set *before* `require("config.options")`, assert `vim.g.clipboard.name == "OSC 52"`. Without the env var (default branch), assert `vim.g.clipboard` is nil or not the OSC 52 entry.
- Diff-mode wrap autocmd: open a window, set `vim.opt.diff = true` (fires `OptionSet`); assert `vim.opt_local.wrap:get() == true` afterward.

`PlenaryBustedDirectory` runs each `_spec.lua` file in its own nvim process, but `it` blocks share state within a file. Reset state explicitly between cases:

```lua
describe("config.options", function()
  before_each(function()
    -- Force re-evaluation of config.options on each it block.
    package.loaded["config.options"] = nil
    -- Reset state the module mutates so cases are order-independent.
    vim.env.REMOTE_CONTAINERS = nil
    vim.env.CODESPACES = nil
    vim.env.SSH_TTY = nil
    vim.g.clipboard = nil
  end)

  it("sets indentation to 2-space expandtab", function()
    require("config.options")
    assert.are.equal(2, vim.opt.shiftwidth:get())
    assert.is_true(vim.opt.expandtab:get())
  end)

  it("enables OSC 52 clipboard inside a container", function()
    vim.env.REMOTE_CONTAINERS = "true"
    require("config.options")
    assert.are.equal("OSC 52", vim.g.clipboard.name)
  end)

  it("does not set OSC 52 clipboard outside containers/SSH", function()
    require("config.options")
    -- Either clipboard untouched, or set to something other than OSC 52.
    if vim.g.clipboard then
      assert.are_not.equal("OSC 52", vim.g.clipboard.name)
    end
  end)
  -- ...
end)
```

**Acceptance:** All cases pass under `make test-unit`. Cases are order-independent (running one in isolation produces the same result as running all).

### Task 3: `tests/spec/unit/review_base_spec.lua`

Use `nvim_env.setup_isolated_env()` in `before_each` so `STATE_PATH` (`stdpath("data") .. "/nvim-review-base.json"`) is in `$TMPDIR`.

Cover one `describe` block per public function:

- `read_state` (private — call via `M.get`): missing file → nil for any key; malformed JSON file → nil for any key; empty file → nil.
- `git_root`: returns toplevel for a `git_fixture.repo({ commits = {{}} })`; `nil` for a non-git temp dir; `nil` for `"/nonexistent"`.
- `resolve`: true for `HEAD`, true for a created branch/tag; false for `"deadbeef"`, `""`, `nil`.
- `set` then `get`: round-trips. `set` fires `User ReviewBaseChanged` exactly once with `{ root, ref }` (capture via an autocmd registered before the call).
- `clear`: removes the entry, fires the autocmd with `nil` ref.
- `bootstrap`: with state pointing at one nonexistent dir and one valid repo, drops the bad entry, writes back, preserves the good one.
- Atomic write: monkey-patch `os.rename` to error; verify state file is not corrupted (still contains pre-write content).

**Acceptance:** All branches covered, all pass.

### Task 4: `tests/spec/unit/lsp_refs_spec.lua`

Use `nvim_env.setup_isolated_env()` in `before_each`. `require("config.lsp_refs").setup()` to register autocommands.

Cover:

- `M.status()` returns `""` when no state for current buffer; returns `" ⇄N "` when state set and cursor matches recorded position; returns `""` after cursor moves off.
- `M.next() / M.prev()`: pre-seed extmarks at known ranges directly into the namespace `vim.api.nvim_create_namespace("lsp_refs_status")`. Place cursor, call `next()`, assert `vim.api.nvim_win_get_cursor(0)` equals expected. Cover wrap-forward (cursor past last mark → wraps to first), wrap-backward, "cursor on a mark" (jump still moves to next mark).
- Reference-request callback: monkey-patch `vim.lsp.buf_request` with a stub capturing the handler arg, invoke the handler synchronously with canned `result` values:
  - 3 same-buffer references → 3 extmarks placed, status reports `⇄3`.
  - 1 reference (count < 2) → no extmarks placed.
  - Result with duplicates by `line:character` → deduped count.
  - Result arriving after `nvim_win_set_cursor` to a different position → no extmarks (stale-response drop).

**Acceptance:** All branches covered, all pass.

### Task 5: `tests/spec/unit/telescope_smart_spec.lua` + remove placeholder

Use `nvim_env.setup_isolated_env()` in `before_each`.

Cover:

- `_git_changes`: build via `git_fixture.repo({ commits = {{ files = { ["a.lua"]="x", ["b.lua"]="y" } }}, modified = { ["a.lua"]="x2" }, staged = { ["s.lua"]="..." }, untracked = { ["u.lua"]="..." } })`. With `base = "main"` (= HEAD), assert exact tables: `staged = { ["s.lua"] = true }`, `modified = { ["a.lua"] = true }`, `untracked = { ["u.lua"] = true }`, `committed = {}`.
- For `committed`: build a repo with two commits on `main`, then a feature branch with two more commits adding files `c.lua` and `d.lua`, checkout the feature branch; with `base = "main"`, assert `committed = { ["c.lua"] = true, ["d.lua"] = true }`.
- `_merge_results`: construct sets with overlap (`a.lua` in staged AND committed) and an `all_files` list with overlap; assert returned list is deduped and ordered staged → modified → untracked → committed → others.
- `list_all` fallback: monkey-patch `vim.fn.executable` to return 1 only for `"rg"`, then for `"fd"`, then for neither; replace `vim.fn.systemlist` with a capture-stub; assert each branch invokes the right command.

After all cases pass, delete `tests/spec/unit/_placeholder_spec.lua`.

**Acceptance:** `make test-unit` passes against the four real spec files only. `tests/spec/unit/_placeholder_spec.lua` does not exist.

## User-visible behaviors that must still work

- All Phase 1 + Phase 2 behaviors.
- `<Space><Space>` (smart_files) opens the picker with the same legend and same ordering as before the refactor.
- `<Space>gB` (review_base picker), `<Space>e` (LSP diagnostic float), and every documented keymap unchanged.
- The `_git_changes` / `_merge_results` refactor must not change `smart_files`'s observable behavior.

## Verification

```bash
make test-unit                                    # 4 real specs pass
make test                                         # smoke + e2e still pass on placeholders
make lint                                         # passes
test ! -f tests/spec/unit/_placeholder_spec.lua   # placeholder gone
```

## Changes Introduced

**New files:**
- `tests/spec/unit/options_spec.lua`
- `tests/spec/unit/review_base_spec.lua`
- `tests/spec/unit/lsp_refs_spec.lua`
- `tests/spec/unit/telescope_smart_spec.lua`

**Modified files:**
- `lua/config/telescope_smart.lua` — `M._git_changes` and `M._merge_results` exposed; `M.smart_files()` calls `_merge_results`.

**Removed files:**
- `tests/spec/unit/_placeholder_spec.lua` (bridge from Phase 2).

**No new env vars, no new dependencies, no bridge code introduced.**
