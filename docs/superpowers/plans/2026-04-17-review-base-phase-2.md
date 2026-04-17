# Review Base — Phase 2: `smart_files` integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `smart_files` to show a fourth bucket — files changed in commits between the saved review base and `HEAD` — with a `◈` marker. Update the legend dynamically. Update the `<leader>gB` keymap to auto-open `smart_files` after a successful branch pick (replaces the Phase 1 bridge).

**Spec:** `docs/superpowers/specs/2026-04-17-review-base-design.md`

**Prerequisites:** Phase 1 (`docs/superpowers/plans/2026-04-17-review-base-phase-1.md`) completed and merged.

**Shippable outcome:** After this phase, setting a review base also changes `smart_files` to list `<base>..HEAD` commits on top of the regular staged/modified/untracked bucketing, with a distinct marker and an updated legend. `<leader>gB` now picks a branch *and* opens `smart_files` in one flow.

---

## Inherits From

The codebase already contains (from Phase 1):

- `lua/config/review_base.lua` with `M.get`, `M.set`, `M.clear`, `M.resolve`, `M.pick(root, on_done)`, `M.bootstrap`, `M.git_root`. The `User ReviewBaseChanged` autocmd fires on set/clear.
- `lua/plugins/gitsigns.lua` wires `change_base` from the saved ref on attach and on `ReviewBaseChanged`.
- `lua/plugins/telescope.lua` has `<leader>gB` (calls `rb.pick(rb.git_root(), nil)`) and `<leader>gX` (calls `rb.clear`).
- `lua/config/telescope_smart.lua` is **unchanged from pre-Phase-1**: it shows staged (◆), modified (●), untracked (○), then all files, with a fixed legend `◆ staged   ● modified   ○ untracked`.

This phase modifies `telescope_smart.lua` to consume the review base, and modifies the `<leader>gB` keymap in `telescope.lua` to pass a callback that opens `smart_files`.

---

## File Structure

**Modify:**
- `lua/config/telescope_smart.lua` — add committed-vs-base bucket, `◈` marker, dynamic legend, dynamic prompt title.
- `lua/plugins/telescope.lua` — replace Phase 1 bridge (nil callback) with a callback that runs `smart_files` on successful selection.

**Create:** none.

**Bridge code introduced this phase:** none.

**Bridge code removed this phase:**
- `<leader>gB`'s `nil` `on_done` argument (Phase 1 bridge) is replaced with the final callback.

**Testing note:** Same as Phase 1 — manual verification per task.

---

### Task 1: Add committed-vs-base bucket to `smart_files`

**Files:**
- Modify: `lua/config/telescope_smart.lua`

- [ ] **Step 1: Extend `git_changes` to accept and return a `committed` bucket**

At the top of `lua/config/telescope_smart.lua`, add the require:

```lua
local review_base = require("config.review_base")
```

Modify `git_changes(root)` to `git_changes(root, base)` and compute a fourth bucket. The updated function must look like:

```lua
local function git_changes(root, base)
  local staged, modified, untracked, committed = {}, {}, {}, {}
  local st = vim.fn.systemlist({ "git", "-C", root, "diff", "--cached", "--name-only" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(st) do if f ~= "" then staged[f] = true end end
  end
  local md = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(md) do if f ~= "" then modified[f] = true end end
  end
  local ut = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(ut) do if f ~= "" then untracked[f] = true end end
  end
  if base and review_base.resolve(root, base) then
    local cm = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", base .. "..HEAD" })
    if vim.v.shell_error == 0 then
      for _, f in ipairs(cm) do if f ~= "" then committed[f] = true end end
    end
  end
  return staged, modified, untracked, committed
end
```

- [ ] **Step 2: Add the `SmartFilesCommitted` highlight**

Inside `set_legend_highlights()`, add one more highlight definition:

```lua
vim.api.nvim_set_hl(0, "SmartFilesCommitted", { fg = "#b58fd4", bold = true, default = true })
```

Place it directly below the existing `SmartFilesUntracked` line so the four SmartFiles highlights are grouped.

- [ ] **Step 3: Verify compilation and existing behavior still works**

Run in nvim:

```
:source %
```

(from the modified file). Then press `<leader><space>`.

Expected: `smart_files` opens and behaves exactly as before — no change visible yet because `smart_files()` has not been updated to use the new bucket.

- [ ] **Step 4: Commit**

```bash
git add lua/config/telescope_smart.lua
git commit -m "Extend git_changes with committed-vs-base bucket"
```

---

### Task 2: Fold committed bucket into `smart_files` results and entries

**Files:**
- Modify: `lua/config/telescope_smart.lua`

- [ ] **Step 1: Read the base and thread it through**

Inside `M.smart_files()`, replace the block that currently reads:

```lua
  local root = git_root()
  local staged, modified, untracked = {}, {}, {}
  if root then staged, modified, untracked = git_changes(root) end
```

with:

```lua
  local root = git_root()
  local base = root and review_base.get(root) or nil
  local staged, modified, untracked, committed = {}, {}, {}, {}
  if root then staged, modified, untracked, committed = git_changes(root, base) end
```

- [ ] **Step 2: Add `committed` to the results list before the `list_all` fallback**

In the existing results-building block, after the three existing `for` loops that push `staged`, `modified`, and `untracked`, insert a fourth loop:

```lua
  for f, _ in pairs(committed) do if not seen[f] then seen[f] = true; table.insert(results, f) end end
```

so the final order is staged → modified → untracked → committed → rest.

- [ ] **Step 3: Add the `◈` marker in the `entry_maker`**

In the `entry_maker` inside the picker, extend the icon/hl decision chain. Replace:

```lua
        if staged[line] then icon, hl = "◆ ", "SmartFilesStaged"
        elseif modified[line] then icon, hl = "● ", "SmartFilesModified"
        elseif untracked[line] then icon, hl = "○ ", "SmartFilesUntracked"
        end
```

with:

```lua
        if staged[line] then icon, hl = "◆ ", "SmartFilesStaged"
        elseif modified[line] then icon, hl = "● ", "SmartFilesModified"
        elseif untracked[line] then icon, hl = "○ ", "SmartFilesUntracked"
        elseif committed[line] then icon, hl = "◈ ", "SmartFilesCommitted"
        end
```

The marker priority (staged > modified > untracked > committed) must match the design spec.

- [ ] **Step 4: Set a dynamic prompt title**

Replace the line:

```lua
    prompt_title = "Files",
```

with:

```lua
    prompt_title = base and ("Files (base: " .. base .. ")") or "Files",
```

- [ ] **Step 5: Verify committed-vs-base files appear with the new marker**

In a repo where `HEAD` contains at least one commit not in `origin/main`:

```
:lua require("config.review_base").set(require("config.review_base").git_root(), "origin/main")
```

Then `<leader><space>`.

Expected:
- Prompt title reads `Files (base: origin/main)`.
- Files changed in commits on this branch appear near the top (below any uncommitted changes) prefixed with `◈ `.
- Highlighting on `◈` uses `SmartFilesCommitted` (purple-ish).
- Files not changed on this branch still appear below, unmarked.

Clear it:

```
:lua require("config.review_base").clear(require("config.review_base").git_root())
```

Then `<leader><space>`.

Expected: prompt title reverts to `Files`; no `◈` markers; behavior identical to pre-phase.

- [ ] **Step 6: Commit**

```bash
git add lua/config/telescope_smart.lua
git commit -m "Show committed-vs-base files with ◈ marker in smart_files"
```

---

### Task 3: Extend the `smart_files` legend card

**Files:**
- Modify: `lua/config/telescope_smart.lua`

- [ ] **Step 1: Make `open_legend` accept and render the base ref**

Change the signature `local function open_legend()` to `local function open_legend(base)`. Replace the body so the card text and highlight ranges are built dynamically by appending to a string and capturing byte offsets as we go — all offsets are 0-based to match `nvim_buf_add_highlight`.

Replace the existing `open_legend` implementation with:

```lua
local function open_legend(base)
  close_legend()
  set_legend_highlights()

  local segments = {
    { icon = "◆", label = "staged",    hl = "SmartFilesStaged" },
    { icon = "●", label = "modified",  hl = "SmartFilesModified" },
    { icon = "○", label = "untracked", hl = "SmartFilesUntracked" },
  }
  if base then
    table.insert(segments, { icon = "◈", label = "vs " .. base, hl = "SmartFilesCommitted" })
  end

  local text = " "
  local ranges = {}
  for i, seg in ipairs(segments) do
    if i > 1 then text = text .. "   " end
    local icon_start = #text
    text = text .. seg.icon
    table.insert(ranges, { seg.hl, icon_start, #text })
    text = text .. " "
    local label_start = #text
    text = text .. seg.label
    table.insert(ranges, { "SmartFilesLegend", label_start, #text })
  end
  text = text .. " "

  legend_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(legend_buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("smart_files_legend")
  for _, r in ipairs(ranges) do
    vim.api.nvim_buf_add_highlight(legend_buf, ns, r[1], 0, r[2], r[3])
  end

  local width = vim.api.nvim_strwidth(text)
  legend_win = vim.api.nvim_open_win(legend_buf, false, {
    relative = "editor",
    row = vim.o.lines - 4,
    col = math.floor((vim.o.columns - width - 2) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
end
```

- [ ] **Step 2: Pass `base` into `open_legend` from `smart_files`**

At the bottom of `M.smart_files()`, change the final call:

```lua
  open_legend()
```

to:

```lua
  open_legend(base)
```

- [ ] **Step 3: Verify the legend shows the active ref**

With a base set (`origin/main`), press `<leader><space>`.

Expected: the legend floating card reads ` ◆ staged   ● modified   ○ untracked   ◈ vs origin/main `, with `◈` highlighted in the committed color and `vs origin/main` in the legend-grey color.

Clear base and reopen. Expected: legend shrinks to the original three-icon version.

- [ ] **Step 4: Commit**

```bash
git add lua/config/telescope_smart.lua
git commit -m "Render review base in smart_files legend and add ◈ segment"
```

---

### Task 4: Replace `<leader>gB` bridge with `smart_files` callback

**Files:**
- Modify: `lua/plugins/telescope.lua`

- [ ] **Step 1: Replace the Phase 1 bridge**

In `lua/plugins/telescope.lua`, find the `<leader>gB` keymap (added in Phase 1 Task 4). Replace its entire entry with:

```lua
      {
        "<leader>gB",
        function()
          local rb = require("config.review_base")
          rb.pick(rb.git_root(), function(ref)
            if ref then
              require("config.telescope_smart").smart_files()
            end
          end)
        end,
        desc = "Review base: pick branch (auto-opens files)",
      },
```

The callback is only invoked for successful ref selection. If the user picked `[ clear base ]` or dismissed the picker, `ref` is `nil` and `smart_files` does not auto-open (clearing the base should not force a picker rerun).

- [ ] **Step 2: Verify end-to-end flow**

In a repo with commits on the current branch vs `origin/main`:

1. `<leader>gX` to start clean. `<leader>gB`. Pick `origin/main`.
   Expected: branch picker closes, `Review base set to origin/main` notification, then `smart_files` opens immediately with the `◈` bucket visible and the updated legend. Gitsigns in any open buffers also reflects the new base.

2. `<leader>gB`. Select `[ clear base ]`.
   Expected: `Review base cleared` notification. `smart_files` does **not** auto-open. Gitsigns reverts to index.

3. `<leader>gB`. Press `<esc>` to dismiss.
   Expected: no notification, nothing changes, `smart_files` does not open.

- [ ] **Step 3: Commit**

```bash
git add lua/plugins/telescope.lua
git commit -m "Auto-open smart_files after review base pick"
```

---

## Post-phase verification

Run from a git repo with an `origin/main` and at least one local commit ahead:

1. Fresh nvim session. `<leader>gB` → `origin/main`. Confirm:
   - `smart_files` opens with prompt title `Files (base: origin/main)`.
   - At least one file has the `◈` marker.
   - Legend shows four icons including `◈ vs origin/main`.
   - Any open buffer's gitsigns hunks are vs `origin/main`.

2. Quit and relaunch. `<leader><space>`. Confirm the `◈` bucket and extended legend still appear (persistence).

3. `<leader>gX`. Confirm `smart_files` (via `<leader><space>`) reverts to the pre-phase view (three-icon legend, no `◈` marker, title `Files`).

4. In a non-git directory, `<leader>gB` and `<leader>gX` both echo `Not a git repo`; `<leader><space>` still opens `smart_files` and falls back to `list_all` (no git bucketing).

5. Smoke the other features to confirm nothing else regressed: `<leader>ff`, `<leader>fg`, `<leader>gs`, `<leader>gm`, `gd` (LSP), `]c`/`[c` (gitsigns hunks).

---

## Changes Introduced

**New files:** none.

**Modified interfaces:**
- `lua/config/telescope_smart.lua`:
  - `git_changes` signature changed from `(root)` to `(root, base)` and returns four buckets instead of three.
  - `open_legend` signature changed from `()` to `(base)`.
  - New highlight group `SmartFilesCommitted`.
  - `smart_files` prompt title is dynamic when a base is set.
- `lua/plugins/telescope.lua`:
  - `<leader>gB` keymap replaced: `on_done` is now a callback that opens `smart_files` on successful selection (bridge from Phase 1 removed).

**New persisted state:** none beyond Phase 1.

**New autocmd event:** none beyond Phase 1.

**New dependencies:** none.

**Bridge code removed this phase:**
- Phase 1 `<leader>gB` bridge (`on_done = nil`) — replaced with the final callback per the design spec.

**Bridge code remaining:** none.

**User-visible behaviors preserved after this phase:**
- All keymaps from Phase 1 (and pre-feature) still work.
- When no review base is set, `smart_files` is byte-identical in behavior to the original — three buckets, three-icon legend, prompt title `Files`.
- Gitsigns behavior from Phase 1 is unchanged.
- Diffview, LSP, and every other feature unchanged.
