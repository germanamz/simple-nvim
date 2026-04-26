# Phase 4: Smoke tests

**Prerequisites:** Phase 2 complete.
**Can run in parallel with:** Phase 3 (unit), Phase 5 (e2e). Different `tests/spec/*` dirs, different placeholder removals; no shared file edits.
**Estimated tasks:** 3 — intentionally narrow. Boot validation and `:checkhealth` are a self-contained concern that doesn't naturally absorb more work without losing focus.

## Inherits From

After Phase 2, the codebase has:
- `tests/full_init.lua` — loads the real `init.lua` against the warm cache, force-loads lazy specs without installing.
- `tests/helpers/{nvim_env,wait,keymap_probe}.lua`.
- `Makefile` with `test-smoke` invoking `PlenaryBustedDirectory tests/spec/smoke`.
- `tests/spec/smoke/_placeholder_spec.lua` — passing placeholder.
- `~/.local/share/nvim` warmed via `make warm`.

## Goal

Cover the structural integrity of the config: it loads with no errors, every plugin reports loaded (not failed), every documented globally-registered keymap is present, and `:checkhealth` reports no errors for the stack we depend on.

These tests fail loudly when something declarative breaks (typo in a `lazy.nvim` spec, missing `config = function`, renamed plugin entrypoint), which is the version-upgrade safety net half of the design's goal.

## Context

- Design spec section "Smoke" under "Smoke + e2e design".
- `tests/helpers/keymap_probe.lua` resolves a leader-mapping to its callback.
- LSP-attach and gitsigns-on-attach mappings are *not* tested here — they're exercised in Phase 5 via real file flows.

## Tasks

### Task 1: `tests/spec/smoke/boot_spec.lua`

Use `nvim_env.setup_isolated_env()` in `before_each` (or once-only `before_all` if specs in this file are read-only — boot is a one-shot observation).

Cover:

1. **Init loads with no errors.** Capture `:messages` content via `vim.api.nvim_exec2("messages", { output = true }).output`. Assert no line matches `^E%d+:` (Vim error-message convention).

2. **All `lua/config/*` modules require cleanly.** Iterate over `{ "config.options", "config.lsp_refs", "config.review_base", "config.telescope_smart" }`; assert `pcall(require, name)` returns `true`.

3. **All plugins reported by `:Lazy` are loaded or lazy.** Use `require("lazy").plugins()`; for each plugin, assert it's not in a failed state. The exact attribute depends on the SHA pinned in `lazy-lock.json` — inspect `require("lazy.core.config").plugins[name]._.loaded` or equivalent at the pinned version. The contract: no plugin reports failure.

4. **Every canonical globally-registered keymap is registered.** Match by description rather than literal `lhs` — `nvim_get_keymap` returns lhs in vim-notation (e.g., `<Space>`), and trying to hard-code that encoding is brittle. Define the canonical list as descriptions:

   ```lua
   local expected_descriptions = {
     "Find files",
     "Live grep",
     "Buffers",
     "Help tags",
     "Recent files",
     "Grep word under cursor",
     "Diagnostics",
     "Keymaps",
     "Keymaps reference",
     "Commands",
     "Fuzzy find in buffer",
     "Git changed files",
     "Review base: pick branch (auto-opens files)",
     "Review base: clear",
     "Diffview: open working tree vs index",
     "Diffview: close",
     "Diffview: repo file history",
     "Diffview: current file history",
     "Diffview: branch vs origin/main",
     "Diffview: toggle file panel",
     "Files (changed first)",
     "All keymaps (which-key)",
   }

   local function find_normal_keymap_by_desc(desc)
     for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
       if m.desc == desc then return m end
     end
     return nil
   end

   for _, desc in ipairs(expected_descriptions) do
     it("registers keymap: " .. desc, function()
       assert.is_not_nil(find_normal_keymap_by_desc(desc),
         "no normal-mode keymap with desc=" .. vim.inspect(desc))
     end)
   end
   ```

   The descriptions are copied from the existing `desc = ...` strings in `lua/plugins/{telescope,diffview,which-key}.lua`. If a future change renames a description, this test will fail — add or update the expected list in the same change.

   **Buffer-local mappings** (set in `LspAttach` or `gitsigns.on_attach`) are intentionally excluded: `]c`, `[c`, `]r`, `[r`, `gd` (LSP), `<leader>e`, `<leader>h*`. They're verified in Phase 5's e2e tests where real files trigger the attach paths.

   Note on lazy-loaded keys: telescope's `keys` field registers a lazy stub eagerly via lazy.nvim — the stub has the configured `desc` and resolves the real callback on first use. Diffview is the same. So `nvim_get_keymap` reports them after `tests/full_init.lua` finishes loading lazy specs.

**Acceptance:** Spec passes against a freshly-warmed cache. Adding an unregistered global leader keymap to `global_keymaps` causes a clear failure.

### Task 2: `tests/spec/smoke/checkhealth_spec.lua`

Use `nvim_env.setup_isolated_env()` in `before_each`.

For each of `nvim-treesitter`, `telescope`, `vim.lsp`:

1. Run `vim.cmd("checkhealth " .. name)`.
2. `wait_for(function() return vim.bo.filetype == "checkhealth" end)`.
3. Read the output buffer: `vim.api.nvim_buf_get_lines(0, 0, -1, false)`.
4. Assert no line starts with `ERROR:` or contains `ERROR ` (treesitter healthcheck format). `WARNING:` is permitted (e.g., LSP "no clients attached" is normal headless).

**Acceptance:** All three checkhealth runs report no errors.

### Task 3: remove smoke placeholder

Delete `tests/spec/smoke/_placeholder_spec.lua`.

**Acceptance:** `make test-smoke` runs only `boot_spec.lua` and `checkhealth_spec.lua` and passes.

## User-visible behaviors that must still work

- All Phase 1 + Phase 2 behaviors.
- Daily `nvim` use unchanged.
- `:checkhealth` works as expected interactively.

## Verification

```bash
make test-smoke
make test                                          # all targets still green
test ! -f tests/spec/smoke/_placeholder_spec.lua
make lint
```

## Changes Introduced

**New files:**
- `tests/spec/smoke/boot_spec.lua`
- `tests/spec/smoke/checkhealth_spec.lua`

**Removed files:**
- `tests/spec/smoke/_placeholder_spec.lua` (bridge from Phase 2).

**No modified files, no new env vars, no new dependencies, no bridge code introduced.**
