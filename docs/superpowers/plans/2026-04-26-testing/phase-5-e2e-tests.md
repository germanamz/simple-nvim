# Phase 5: E2e tests

**Prerequisites:** Phase 2 complete.
**Can run in parallel with:** Phase 3 (unit), Phase 4 (smoke). Different `tests/spec/*` dirs, different placeholder removals; no shared file edits.
**Estimated tasks:** 5

## Inherits From

After Phase 2, the codebase has:
- `tests/full_init.lua` — loads the real `init.lua` against the warm cache, force-loads lazy specs without installing.
- `tests/helpers/{nvim_env,wait,keymap_probe,git_fixture}.lua`.
- `Makefile` with `test-e2e` invoking `PlenaryBustedDirectory tests/spec/e2e`.
- `tests/spec/e2e/_placeholder_spec.lua` — passing placeholder.
- `~/.local/share/nvim` warmed via `make warm`.

## Goal

Drive the integrated plugin flows that smoke tests can't verify: Telescope pickers actually open with expected entries, gitsigns hunks navigate as configured, Diffview opens with correct windows, treesitter highlight is active. Tests run against synthetic git repos for behavioral determinism.

LSP-driven flows (`gd`, `]r`, `<leader>e`) are explicitly **not** in this phase — they're Phase 6's e2e-lsp slow lane.

## Context

- Design spec section "E2e" under "Smoke + e2e design".
- `tests/helpers/git_fixture.lua` builds synthetic repos with deterministic commits.
- `tests/helpers/wait.lua` provides `wait_for_buffer` and `wait_for_event`.
- `lua/plugins/telescope.lua` registers `<leader>ff`, `<leader>fg`, `<leader><space>` (smart_files), `<leader>gB` (review_base picker).
- `lua/plugins/gitsigns.lua` registers `]c` / `[c` / `<leader>h*` in `on_attach`.
- `lua/plugins/diffview.lua` registers `<leader>gd` / `<leader>gm` / `<leader>gD` etc.
- `lua/plugins/treesitter.lua` runs `vim.treesitter.start` from a `FileType` autocmd.

## Tasks

### Task 1: `tests/spec/e2e/telescope_spec.lua`

Two helpers inside the spec:

```lua
-- Press a key sequence using vim notation (e.g., "<Space>ff", "<Esc>").
local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "m", false)
  vim.wait(0)  -- let the event loop drain queued input
end

local function is_telescope_open()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then return true end
  end
  return false
end
```

`before_each`: `nvim_env.setup_isolated_env()`. Build a fixture per `describe` block.

Four `describe` blocks. The mapleader is `<Space>`, so:

| Picker | Press call |
|---|---|
| `<leader>ff` (Find files) | `press("<Space>ff")` |
| `<leader>fg` (Live grep) | `press("<Space>fg")` |
| `<leader><space>` (Smart files) | `press("<Space><Space>")` |
| `<leader>gB` (Review base) | `press("<Space>gB")` |

For each block:
1. Build appropriate fixture — for smart_files, include staged/modified/untracked/committed via `git_fixture.repo`. For `<leader>gB`, set up two branches (`main` + a feature branch).
2. `vim.fn.chdir(repo)`.
3. Call `press(...)` with the matching key sequence.
4. `wait_for_buffer({ filetype = "TelescopePrompt" })`.
5. Inspect:
   - **Smart files (`<leader><space>`):** use `require("telescope.actions.state").get_current_picker(prompt_buf)` to access the picker. Read result lines via `vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)`. Assert ordering — staged ◆ first, then modified ●, then untracked ○, then committed ◈, then others.
   - **`<leader>gB` (review_base picker):** assert prompt title contains `"Review base"`. Assert results contain `"[ clear base ]"` as the first entry, then both branch names.
   - **`<leader>ff` and `<leader>fg`:** assert prompt buffer exists and the picker's `prompt_title` (read from `picker.prompt_title`) matches the configured value (`"Find files"` / `"Live grep"`).
6. `press("<Esc>")`. `wait_for(function() return not is_telescope_open() end)`. Assert closed.

**Acceptance:** All four picker flows pass; smart_files ordering assertion is exact.

### Task 2: `tests/spec/e2e/gitsigns_spec.lua`

`before_each`: `nvim_env.setup_isolated_env()`.

Build a repo with `a.lua` containing 40 lines (numbered comments). `commit`. Then via `modified` in a fresh recipe, replace its content so three hunks land at known lines — for example:
- Change line 5 (single-line edit).
- Insert two new lines after line 12.
- Delete a block at line 30.

Verify by inspection that `git diff a.lua` produces exactly three hunks at those line numbers.

Open the file: `vim.cmd("edit " .. repo .. "/a.lua")`. `wait_for(function() return vim.b.gitsigns_status ~= nil end)` (gitsigns sets buffer-local var on attach).

Use the same `press` helper from Task 1 (define it locally in this spec too):

```lua
local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "m", false)
  vim.wait(0)
end
```

Sequence:
1. `vim.api.nvim_win_set_cursor(0, { 1, 0 })`. `press("]c")`. Assert cursor on line 5.
2. `press("]c")`. Assert line 12 (or the line of the second hunk after the inserts shift).
3. `press("]c")`. Assert line 30.
4. `press("]c")`. Assert wraps to line 5.
5. From line 30, `press("[c")`. Assert line 12.

Then for the review-base integration:
1. `require("config.review_base").set(repo, "main")`.
2. `wait_for_event("GitSignsUpdate")`.
3. Verify gitsigns is now diffing against `main` — inspect `vim.b.gitsigns_head` or call `require("gitsigns").get_hunks()` and assert hunk count corresponds to "vs main" rather than "vs index". The exact API depends on the gitsigns SHA in `lazy-lock.json`; choose whichever observable changes.

**Acceptance:** Hunk navigation lands on expected lines; review-base reattach observable.

### Task 3: `tests/spec/e2e/diffview_spec.lua`

`before_each`: `nvim_env.setup_isolated_env()`.

Build a fixture: two commits on `main`, then `git_fixture.with_remote(repo, "origin")` to add a synthetic origin. Modify a file in the working tree (uncommitted) so `working tree vs index` is meaningful.

Helper:
```lua
local function diffview_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("^diffview://") or vim.bo[buf].filetype == "DiffviewFiles" then
      table.insert(out, buf)
    end
  end
  return out
end
```

Use the same `press` helper from Task 1 (define it locally in this spec too).

Sequence:
1. `vim.fn.chdir(repo)`.
2. `press("<Space>gd")`. `wait_for(function() return #diffview_buffers() > 0 end)`. Assert at least two diffview-related buffers (file panel + diff content).
3. `press("q")`. `wait_for(function() return #diffview_buffers() == 0 end)`. Assert window count returns to baseline.
4. `press("<Space>gm")`. `wait_for(function() return #diffview_buffers() > 0 end)`. Assert any visible buffer name or window title contains `origin/main` (use `vim.api.nvim_buf_get_name` across listed buffers).
5. `press("q")`. Assert closed.

**Acceptance:** Both diffview flows open and close cleanly. The `<leader>gm` flow involves the synthetic remote.

### Task 4: `tests/spec/e2e/treesitter_spec.lua`

`before_each`: `nvim_env.setup_isolated_env()`.

For each language fixture (Lua and TypeScript):

1. `git_fixture.repo({ commits = { { files = { ["sample.lua"] = "local x = 1\n" } } } })` (and a TS variant: `["sample.ts"] = "const x: number = 1;\n"`).
2. `vim.cmd("edit " .. repo .. "/sample.lua")` (or `.ts`).
3. The `FileType` autocmd in `lua/plugins/treesitter.lua` should run synchronously; if it doesn't on this nvim version, `wait_for(function() return vim.treesitter.highlighter.active[bufnr] ~= nil end)`.
4. Assert `vim.treesitter.highlighter.active[bufnr]` is non-nil.
5. Assert `vim.treesitter.get_captures_at_pos(bufnr, 0, 6)` (column 6 = on `x` for Lua) returns at least one capture.
6. Assert `vim.wo.foldexpr == "v:lua.vim.treesitter.foldexpr()"` (the FT autocmd sets this on success).

For TypeScript, use `ft_to_lang` (the `tsx` parser handles `typescript` filetype here, or `typescript` directly — check the table in the file).

**Acceptance:** Highlighter active for both languages; foldexpr set; captures non-empty.

### Task 5: remove e2e placeholder

Delete `tests/spec/e2e/_placeholder_spec.lua`.

**Acceptance:** `make test-e2e` runs the four real specs and passes.

## User-visible behaviors that must still work

- All Phase 1 + Phase 2 behaviors.
- Telescope pickers, gitsigns hunk nav, diffview, treesitter highlight all work in normal `nvim` use exactly as before — these tests *use* the real keybindings, so any regression breaks both.

## Verification

```bash
make test-e2e
make test                                          # all green
test ! -f tests/spec/e2e/_placeholder_spec.lua
make lint
```

## Changes Introduced

**New files:**
- `tests/spec/e2e/telescope_spec.lua`
- `tests/spec/e2e/gitsigns_spec.lua`
- `tests/spec/e2e/diffview_spec.lua`
- `tests/spec/e2e/treesitter_spec.lua`

**Removed files:**
- `tests/spec/e2e/_placeholder_spec.lua` (bridge from Phase 2).

**No modified files, no new env vars, no new dependencies, no bridge code introduced.**
