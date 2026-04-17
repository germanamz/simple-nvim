# Review Base — Phase 1: State module, branch picker, gitsigns wiring, keymaps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a per-repo review base ref. User can set/clear it via keymaps; gitsigns applies it as the `change_base` so in-buffer hunks highlight vs the selected ref. Setting persists across sessions. `smart_files` is **not** changed in this phase — it continues to use its current index-based bucketing.

**Spec:** `docs/superpowers/specs/2026-04-17-review-base-design.md`

**Prerequisites:** Base codebase at current `main`. No other phases required.

**Shippable outcome:** After this phase, `<leader>gB` opens a branch picker; selection sets the base for the current repo and triggers gitsigns to re-diff all buffers against it. `<leader>gX` clears it. Restart persists the setting. `<leader><space>` still behaves exactly as today.

---

## File Structure

**Create:**
- `lua/config/review_base.lua` — state, JSON persistence, branch picker, `ReviewBaseChanged` autocmd.

**Modify:**
- `lua/plugins/gitsigns.lua` — call `apply_base()` from `on_attach`, listen for `User ReviewBaseChanged`, call `review_base.bootstrap()` at `config` time.
- `lua/plugins/telescope.lua` — add `<leader>gB` and `<leader>gX` keymaps to the existing `keys` list.

**Bridge code introduced this phase:**
- The `<leader>gB` keymap calls `review_base.pick(root, nil)` (no `on_done` callback). **Removal target:** Phase 2 replaces `nil` with a callback that runs `smart_files` on successful selection.

**Testing note:** This is Neovim configuration; no unit test framework. Every task ends with manual verification steps that must pass before commit.

---

### Task 1: Create `review_base.lua` with state, persistence, and autocmd

**Files:**
- Create: `lua/config/review_base.lua`

- [ ] **Step 1: Write the module skeleton**

Create `lua/config/review_base.lua`:

```lua
-- Per-repo "review base" ref used by other modules to diff vs a chosen branch
-- (e.g. origin/main) instead of the index. Persisted in stdpath("data") as a
-- JSON map keyed by absolute repo toplevel path. Changes are broadcast via a
-- `User ReviewBaseChanged` autocmd whose `data` is `{ root, ref }`. Consumers
-- read state via `M.get(root)` or listen to the autocmd.
local M = {}

local STATE_PATH = vim.fn.stdpath("data") .. "/nvim-review-base.json"

local function read_state()
  local f = io.open(STATE_PATH, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then return data end
  return {}
end

local function write_state(state)
  local tmp = STATE_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(vim.json.encode(state))
  f:close()
  os.rename(tmp, STATE_PATH)
end

local function fire(root, ref)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ReviewBaseChanged",
    data = { root = root, ref = ref },
  })
end

function M.git_root(start_path)
  local args = { "git" }
  if start_path and start_path ~= "" then
    table.insert(args, "-C")
    table.insert(args, start_path)
  end
  table.insert(args, "rev-parse")
  table.insert(args, "--show-toplevel")
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  return out[1]
end

function M.resolve(root, ref)
  if not root or not ref or ref == "" then return false end
  vim.fn.system({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref })
  return vim.v.shell_error == 0
end

function M.get(root)
  if not root then return nil end
  return read_state()[root]
end

function M.set(root, ref)
  if not root or not ref then return end
  local state = read_state()
  state[root] = ref
  write_state(state)
  fire(root, ref)
end

function M.clear(root)
  if not root then return end
  local state = read_state()
  state[root] = nil
  write_state(state)
  fire(root, nil)
end

function M.bootstrap()
  local state = read_state()
  local changed = false
  for root, ref in pairs(state) do
    if vim.fn.isdirectory(root) == 0 or not M.resolve(root, ref) then
      state[root] = nil
      changed = true
    end
  end
  if changed then write_state(state) end
end

-- M.pick is added in Task 2.

return M
```

- [ ] **Step 2: Verify the module loads and round-trips state**

Run in nvim interactively:

```
:lua local rb = require("config.review_base"); rb.set(rb.git_root(), "HEAD"); print(rb.get(rb.git_root()))
```

Expected: prints `HEAD`.

Then:

```
:lua print(vim.fn.filereadable(vim.fn.stdpath("data") .. "/nvim-review-base.json"))
```

Expected: prints `1`.

Then:

```
:lua require("config.review_base").clear(require("config.review_base").git_root()); print(require("config.review_base").get(require("config.review_base").git_root()))
```

Expected: prints `nil`.

- [ ] **Step 3: Verify `resolve()` and `bootstrap()`**

Run:

```
:lua local rb = require("config.review_base"); print(rb.resolve(rb.git_root(), "HEAD"))
```

Expected: prints `true`.

Then:

```
:lua local rb = require("config.review_base"); print(rb.resolve(rb.git_root(), "definitely-not-a-ref"))
```

Expected: prints `false`.

Simulate a stale entry and confirm bootstrap prunes it:

```
:lua local rb = require("config.review_base"); rb.set(rb.git_root(), "HEAD"); local p = vim.fn.stdpath("data") .. "/nvim-review-base.json"; local f = io.open(p, "r"); local raw = f:read("*a"); f:close(); local data = vim.json.decode(raw); data[rb.git_root()] = "definitely-not-a-ref"; f = io.open(p, "w"); f:write(vim.json.encode(data)); f:close(); rb.bootstrap(); print(rb.get(rb.git_root()))
```

Expected: prints `nil` (stale entry removed).

- [ ] **Step 4: Commit**

```bash
git add lua/config/review_base.lua
git commit -m "Add review_base module with per-repo persistence"
```

---

### Task 2: Add the branch picker (`M.pick`)

**Files:**
- Modify: `lua/config/review_base.lua`

- [ ] **Step 1: Add picker helpers and `M.pick`**

Insert the following **above** the final `return M` line in `lua/config/review_base.lua`:

```lua
local CLEAR_SENTINEL = "__CLEAR__"

local legend_win, legend_buf

local function close_legend()
  if legend_win and vim.api.nvim_win_is_valid(legend_win) then
    vim.api.nvim_win_close(legend_win, true)
  end
  if legend_buf and vim.api.nvim_buf_is_valid(legend_buf) then
    vim.api.nvim_buf_delete(legend_buf, { force = true })
  end
  legend_win, legend_buf = nil, nil
end

local function open_legend()
  close_legend()
  vim.api.nvim_set_hl(0, "ReviewBaseActive", { fg = "#5aa0d4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewBaseLegend", { fg = "#888888", default = true })
  local text = " ● active base "
  legend_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(legend_buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("review_base_legend")
  vim.api.nvim_buf_add_highlight(legend_buf, ns, "ReviewBaseActive", 0, 1, 4)
  vim.api.nvim_buf_add_highlight(legend_buf, ns, "ReviewBaseLegend", 0, 4, #text)
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

local function list_branches(root)
  local function run(args)
    local out = vim.fn.systemlist(args)
    if vim.v.shell_error ~= 0 then return {} end
    return out
  end
  local entries, seen = {}, {}
  local function push(ref)
    if not ref or ref == "" or seen[ref] then return end
    seen[ref] = true
    table.insert(entries, ref)
  end
  local head = run({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  push(head[1])
  local up = run({ "git", "-C", root, "rev-parse", "--abbrev-ref", "@{upstream}" })
  push(up[1])
  for _, b in ipairs(run({ "git", "-C", root, "branch", "--format=%(refname:short)" })) do push(b) end
  for _, b in ipairs(run({ "git", "-C", root, "branch", "-r", "--format=%(refname:short)" })) do
    if not b:match("/HEAD$") then push(b) end
  end
  return entries
end

function M.pick(root, on_done)
  if not root then
    vim.notify("Not a git repo", vim.log.levels.WARN)
    if on_done then on_done(nil) end
    return
  end

  local active = M.get(root)
  local results = { CLEAR_SENTINEL }
  for _, b in ipairs(list_branches(root)) do table.insert(results, b) end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "Review base (current: " .. (active or "none") .. ")",
    finder = finders.new_table({
      results = results,
      entry_maker = function(val)
        local display, hl_ranges
        if val == CLEAR_SENTINEL then
          display = "[ clear base ]"
        elseif val == active then
          display = "● " .. val
          hl_ranges = { { { 0, 3 }, "ReviewBaseActive" } }
        else
          display = "  " .. val
        end
        return {
          value = val,
          ordinal = val == CLEAR_SENTINEL and "clear base" or val,
          display = hl_ranges and function() return display, hl_ranges end or display,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_termopen_previewer({
      get_command = function(entry)
        if entry.value == CLEAR_SENTINEL then
          return { "echo", "Clears the saved review base for this repo." }
        end
        return {
          "git", "-C", root, "log", "--oneline", "--decorate",
          "-n", "200", entry.value .. "..HEAD",
        }
      end,
    }),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not selection then
          if on_done then on_done(nil) end
          return
        end
        if selection.value == CLEAR_SENTINEL then
          M.clear(root)
          vim.notify("Review base cleared")
          if on_done then on_done(nil) end
          return
        end
        if not M.resolve(root, selection.value) then
          vim.notify("Ref does not exist: " .. selection.value, vim.log.levels.ERROR)
          if on_done then on_done(nil) end
          return
        end
        M.set(root, selection.value)
        vim.notify("Review base set to " .. selection.value)
        if on_done then on_done(selection.value) end
      end)
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufLeave" }, {
        buffer = prompt_bufnr,
        once = true,
        callback = close_legend,
      })
      return true
    end,
  }):find()

  open_legend()
end
```

- [ ] **Step 2: Verify the picker opens and can set/clear base**

Run in nvim (from any git repo that has at least `origin/main` or similar):

```
:lua require("config.review_base").pick(require("config.review_base").git_root(), function(r) print("picked:", tostring(r)) end)
```

Expected:
- Telescope picker opens with title `Review base (current: <none or ref>)`
- First entry is `[ clear base ]`
- Below it: `origin/HEAD` resolved, then local branches, then remote branches
- A small floating card appears at the bottom center showing ` ● active base `
- Previewer on a branch entry runs `git log --oneline` between that ref and HEAD
- Pressing `<cr>` on a branch prints `picked: <ref>` and closes the legend
- Re-running the command now shows the newly-set ref with a `●` prefix in the display

Then select `[ clear base ]`:

Expected: picker closes, legend closes, `:lua print(require("config.review_base").get(require("config.review_base").git_root()))` prints `nil`.

- [ ] **Step 3: Commit**

```bash
git add lua/config/review_base.lua
git commit -m "Add review_base branch picker with legend and preview"
```

---

### Task 3: Wire gitsigns to honor the review base

**Files:**
- Modify: `lua/plugins/gitsigns.lua`

- [ ] **Step 1: Add the `apply_base` helper and listeners**

Open `lua/plugins/gitsigns.lua`. Make the following changes:

1. Add a `local review_base = require("config.review_base")` at the top of the returned spec's `opts`/`config` scope — since this file already uses a `config = function(_, opts)` block, put it inside that block.

2. Inside `on_attach(bufnr)` (currently lives inside `opts`), add a call to a shared `apply_base(bufnr)` helper at the **top** of the function. The helper lives in the `config` function (see step 3); expose it to `on_attach` by lifting it to a file-local `local apply_base`.

3. In the `config = function(_, opts)` block:
   - Call `review_base.bootstrap()` once, before `require("gitsigns").setup(opts)`.
   - Create a `User ReviewBaseChanged` autocmd that calls `require("gitsigns").change_base(ref, true)` with the incoming ref (or `nil`).

Concretely, the `lua/plugins/gitsigns.lua` file should look like this after editing (only the differences below are new; the rest is unchanged):

```lua
return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = function()
    local review_base = require("config.review_base")

    local function apply_base(bufnr)
      local fname = vim.api.nvim_buf_get_name(bufnr)
      local start = (fname ~= "" and vim.fn.fnamemodify(fname, ":h")) or vim.fn.getcwd()
      local root = review_base.git_root(start)
      local ref = root and review_base.get(root) or nil
      require("gitsigns").change_base(ref, true)
    end

    return {
      signcolumn = false,
      numhl = true,
      linehl = false,
      word_diff = true,
      diff_opts = { internal = true, linematch = 60 },
      on_attach = function(bufnr)
        apply_base(bufnr)
        local gs = require("gitsigns")
        local map = function(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end
        map("n", "]c", function() gs.nav_hunk("next") end, "Next hunk")
        map("n", "[c", function() gs.nav_hunk("prev") end, "Prev hunk")
        map("n", "<leader>hp", gs.preview_hunk, "Preview hunk")
        map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
        map("n", "<leader>hr", gs.reset_hunk, "Reset hunk")
        map("n", "<leader>hb", function() gs.blame_line({ full = true }) end, "Blame line")
        map("n", "<leader>hd", gs.diffthis, "Diff against index")
        map("n", "<leader>ht", gs.toggle_deleted, "Toggle deleted lines inline")
        map("n", "<leader>hi", gs.preview_hunk_inline, "Inline preview hunk")
      end,
    }
  end,
  config = function(_, opts)
    local review_base = require("config.review_base")
    review_base.bootstrap()

    require("gitsigns").setup(opts)

    vim.api.nvim_create_autocmd("User", {
      pattern = "ReviewBaseChanged",
      callback = function(args)
        local ref = args.data and args.data.ref or nil
        require("gitsigns").change_base(ref, true)
      end,
    })

    -- (existing paint/mark_hunks/statusline/autocmd code below is unchanged)
    local function paint()
      vim.api.nvim_set_hl(0, "GitSignsAddNr",    { fg = "#ffffff", bg = "#4ea862" })
      -- ... (rest unchanged from current file)
    end
    -- ... (keep everything else exactly as-is)
  end,
}
```

**Important:** Keep the entire existing body of the current `config` function (the `paint()` / `mark_hunks()` / `_G.gitsigns_below_status` / `vim.o.statusline` / `GitSignsUpdate` autocmd) unchanged. Only add the `review_base.bootstrap()` call, the `User ReviewBaseChanged` autocmd, and convert `opts` from a table to a `function` wrapper so `apply_base` can be defined in its scope and referenced by `on_attach`.

- [ ] **Step 2: Verify gitsigns responds to base changes**

Open a file that has at least one commit between `HEAD` and `origin/main` differing from the working tree (or create one: edit any tracked file, commit the change, then set up the scenario below).

In nvim:

```
:lua require("config.review_base").set(require("config.review_base").git_root(), "origin/main")
```

Expected:
- `:lua =require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()].base` prints `origin/main`.
- Sign column / numhl shows hunks consistent with `git diff origin/main` (committed-on-branch lines show as changed/added in gitsigns).

Then:

```
:lua require("config.review_base").clear(require("config.review_base").git_root())
```

Expected:
- `:lua =require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()].base` prints `nil` or `""`.
- Hunks revert to working-tree-vs-index.

- [ ] **Step 3: Verify persistence across restart**

Re-set the base, quit nvim, reopen the same file, and verify that gitsigns still diffs against the saved base:

```
:lua require("config.review_base").set(require("config.review_base").git_root(), "origin/main")
:qa
```

Then `nvim <same-file>` and run:

```
:lua print(require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()].base)
```

Expected: prints `origin/main`.

Clean up:

```
:lua require("config.review_base").clear(require("config.review_base").git_root())
```

- [ ] **Step 4: Commit**

```bash
git add lua/plugins/gitsigns.lua
git commit -m "Wire gitsigns to review_base for per-repo diff anchoring"
```

---

### Task 4: Add `<leader>gB` and `<leader>gX` keymaps

**Files:**
- Modify: `lua/plugins/telescope.lua`

- [ ] **Step 1: Append the keymaps**

In `lua/plugins/telescope.lua`, add the following two entries to the `keys = { ... }` table, after the existing `{ "<leader>gs", ... }` entry:

```lua
      {
        "<leader>gB",
        function()
          local rb = require("config.review_base")
          -- BRIDGE (removed in Phase 2): on_done is nil here so setting the base
          -- only persists and fires the autocmd; Phase 2 replaces nil with a
          -- callback that auto-opens smart_files when a ref was selected.
          rb.pick(rb.git_root(), nil)
        end,
        desc = "Review base: pick branch",
      },
      {
        "<leader>gX",
        function()
          local rb = require("config.review_base")
          local root = rb.git_root()
          if not root then
            vim.notify("Not a git repo", vim.log.levels.WARN)
            return
          end
          rb.clear(root)
          vim.notify("Review base cleared")
        end,
        desc = "Review base: clear",
      },
```

- [ ] **Step 2: Verify both keymaps work end-to-end**

Launch nvim in a git repo. Press `<leader>gB`.

Expected:
- The branch picker opens with `[ clear base ]` and branch entries as in Task 2.
- Selecting a branch closes the picker, prints `Review base set to <ref>`, and triggers the gitsigns autocmd (visible hunks now vs that ref in any open buffer).

Press `<leader>gX`.

Expected: prints `Review base cleared`; gitsigns reverts hunks to index.

Press `<leader>gX` in a non-git directory (e.g. `cd /tmp && nvim`).

Expected: prints `Not a git repo`, no crash.

- [ ] **Step 3: Commit**

```bash
git add lua/plugins/telescope.lua
git commit -m "Add <leader>gB and <leader>gX for review base control"
```

---

## Post-phase verification

Run from a git repo with an `origin/main` remote tracking branch:

1. Restart nvim fresh. Press `<leader>gB`. Pick `origin/main`. Confirm notification and that open buffers' gitsigns now reflect `origin/main`.
2. Quit nvim, relaunch, open the same file. Confirm `:lua print(require("gitsigns.cache").cache[vim.api.nvim_get_current_buf()].base)` still prints `origin/main`.
3. In another terminal, delete the locally-saved ref (e.g. `git branch -D some-stale-branch` that you had set as base) — or pick a different branch, delete it, then restart nvim. Confirm bootstrap silently clears it: `:lua print(require("config.review_base").get(require("config.review_base").git_root()))` prints `nil` with no error.
4. `<leader>gX`. Confirm hunks revert.
5. `<leader><space>` still runs `smart_files` with the current markers (staged/modified/untracked). No `◈` marker yet — that is Phase 2.

---

## Changes Introduced

**New files:**
- `lua/config/review_base.lua` — state module, persistence, branch picker, `User ReviewBaseChanged` autocmd.

**Modified interfaces:**
- `lua/plugins/gitsigns.lua` — `opts` is now a function (previously a table); `config` calls `review_base.bootstrap()` before `gitsigns.setup()`; new `User ReviewBaseChanged` autocmd drives `change_base(ref, true)` globally; `on_attach` calls `apply_base(bufnr)` first.
- `lua/plugins/telescope.lua` — two new keymaps: `<leader>gB` (pick) and `<leader>gX` (clear).

**New persisted state:**
- `vim.fn.stdpath("data") .. "/nvim-review-base.json"` — repo-root → ref map.

**New autocmd event:**
- `User ReviewBaseChanged` with `data = { root, ref }`. Consumers listen to this event.

**New dependencies:** none.

**Bridge code introduced:**
- `<leader>gB` passes `nil` for `on_done`. **Removal target: Phase 2, Task 4** (replaces `nil` with a callback invoking `require("config.telescope_smart").smart_files()` when a ref is selected).

**User-visible behaviors preserved after this phase:**
- `<leader>ff`, `<leader>fg`, `<leader>fb`, `<leader>fh`, `<leader>fr`, `<leader>fs`, `<leader>fd`, `<leader>fk`, `<leader>fc`, `<leader>f/`, `<leader>gs`, `<leader><space>` all behave identically to before.
- Diffview keymaps (`<leader>gd`, `<leader>gD`, `<leader>gh`, `<leader>gf`, `<leader>gm`, `<leader>gt`) unchanged.
- Gitsigns hunks default to working-tree-vs-index when no review base is set (same as before).
- LSP keymaps unchanged.
