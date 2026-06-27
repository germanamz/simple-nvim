-- Per-repo "review base" ref used by other modules to diff vs a chosen branch
-- (e.g. origin/main) instead of the index. Persisted in stdpath("data") as a
-- JSON map keyed by absolute repo toplevel path. Changes are broadcast via a
-- `User ReviewBaseChanged` autocmd whose `data` is `{ root, ref }`. Consumers
-- read state via `M.get(root)` or listen to the autocmd.
local M = {}

local git = require("util.git")
local Overlay = require("util.overlay")
local palette = require("config.palette")

-- Resolved per call, not at require time: stdpath("data") follows
-- $XDG_DATA_HOME at call time, and the test harness swaps that per test for
-- isolation. Baking the path at first require made state reads/writes land in
-- whichever (possibly since-deleted) environment happened to load this module
-- first.
local function state_path()
  return vim.fn.stdpath("data") .. "/nvim-review-base.json"
end

-- Decoded state, memoized. The disk read below does io.open+read+json.decode,
-- which is hit on every gitsigns attach and statusline refresh through M.get;
-- caching the decoded table keeps those hot paths in memory. Populated lazily on
-- the first read, written through on every write_state(), and invalidated by the
-- autocmds below. Module-local, so the test harness's package.loaded reset
-- reloads this file with a fresh (empty) cache per test.
local cache

-- The actual disk read; read_state() wraps it with memoization.
local function decode_state()
  local f = io.open(state_path(), "r")
  if not f then
    return {}
  end
  local raw = f:read("*a")
  f:close()
  if raw == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function read_state()
  if not cache then
    cache = decode_state()
  end
  return cache
end

-- Shallow copy of the live state for mutators to edit a throwaway table: if
-- write_state's atomic rename fails (it throws), the cache stays consistent with
-- disk instead of holding the never-persisted edit.
local function copy_state()
  local out = {}
  for k, v in pairs(read_state()) do
    out[k] = v
  end
  return out
end

local function write_state(state)
  local tmp = state_path() .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(state))
  f:close()
  os.rename(tmp, state_path())
  -- Write-through: disk now equals `state`, so adopt it as the cache rather than
  -- forcing the next read to re-decode. A failed rename above throws before
  -- here, leaving the cache (and disk) untouched.
  cache = state
end

local function fire(root, ref)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ReviewBaseChanged",
    data = { root = root, ref = ref },
  })
end

-- Invalidate the cache when the shared JSON can change without passing through
-- write_state: `User ReviewBaseChanged` for any in-instance broadcast (defensive
-- — our own set/clear already wrote through), and `FocusGained` for another nvim
-- instance editing the same file while this one was unfocused. An augroup with
-- clear=true so a module reload in tests replaces these rather than stacking
-- them; the next read_state() then re-decodes from disk.
local cache_group = vim.api.nvim_create_augroup("ReviewBaseCache", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = cache_group,
  pattern = "ReviewBaseChanged",
  callback = function()
    cache = nil
  end,
})
vim.api.nvim_create_autocmd("FocusGained", {
  group = cache_group,
  callback = function()
    cache = nil
  end,
})

function M.get(root)
  if not root then
    return nil
  end
  return read_state()[root]
end

function M.set(root, ref)
  if not root or not ref then
    return
  end
  local state = read_state()
  -- Persist + broadcast only on an actual change (mirrors git_head.lua, which
  -- re-broadcasts HEAD only when the branch truly moved). apply_selection's
  -- notify/on_done live outside M.set, so re-picking the active base still
  -- re-confirms even though this returns early.
  if state[root] == ref then
    return
  end
  state = copy_state()
  state[root] = ref
  write_state(state)
  fire(root, ref)
end

function M.clear(root)
  if not root then
    return
  end
  local state = read_state()
  -- Same actual-change guard as M.set: clearing an already-absent base is a
  -- no-op, so skip the rewrite and don't broadcast a phantom change.
  if state[root] == nil then
    return
  end
  state = copy_state()
  state[root] = nil
  write_state(state)
  fire(root, nil)
end

function M.bootstrap()
  -- Edit a copy so a failed write can't leave the cache out of sync with disk.
  local state = copy_state()
  local changed = false
  for root, ref in pairs(state) do
    if vim.fn.isdirectory(root) == 0 or not git.resolve(root, ref) then
      state[root] = nil
      changed = true
    end
  end
  if changed then
    write_state(state)
  end
end

local CLEAR_SENTINEL = "__CLEAR__"

local legend = Overlay.new()

local function close_legend()
  legend:close()
end

local function open_legend()
  -- Purple, matching SmartFilesBase in config.git_status_codes: the "base"
  -- concept reads as one hue across the legend, the pickers, and the tree.
  -- (The old blue duplicated SmartFilesModified and muddied that mapping.)
  vim.api.nvim_set_hl(0, "ReviewBaseActive", { fg = "#d896ff", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewBaseLegend", { fg = palette.muted, default = true })
  local text = " ● active base "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("review_base_legend")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = 4, hl_group = "ReviewBaseActive" })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 4, { end_col = #text, hl_group = "ReviewBaseLegend" })
  local width = vim.api.nvim_strwidth(text)
  -- Borderless to match the prevailing float style (telescope strip, LSP hover,
  -- diagnostic float are all borderless); the rounded badge was the lone accent.
  legend:mount(buf, {
    relative = "editor",
    row = vim.o.lines - 4,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
end

local function list_branches(root)
  local entries, seen = {}, {}
  local function push(ref)
    if not ref or ref == "" or seen[ref] then
      return
    end
    seen[ref] = true
    table.insert(entries, ref)
  end
  -- A failed listing (e.g. no branches yet) yields no entries rather than
  -- iterating git's error output.
  local function branch_list(args)
    local lines, ok = git.run(args, { cwd = root })
    return ok and lines or {}
  end
  -- Most-relevant first: the remote's default branch, then this branch's
  -- upstream, then all local and remote branches (skipping the origin/HEAD
  -- symref). push() dedupes, keeping the first occurrence.
  push(git.first_line({ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { cwd = root }))
  push(git.first_line({ "rev-parse", "--abbrev-ref", "@{upstream}" }, { cwd = root }))
  for _, b in ipairs(branch_list({ "branch", "--format=%(refname:short)" })) do
    push(b)
  end
  for _, b in ipairs(branch_list({ "branch", "-r", "--format=%(refname:short)" })) do
    if not b:match("/HEAD$") then
      push(b)
    end
  end
  return entries
end

-- Build a telescope entry for a review-base candidate: the clear sentinel, the
-- active base (● + highlight), or a plain branch.
local function build_branch_entry(val, active)
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
    display = hl_ranges and function()
      return display, hl_ranges
    end or display,
  }
end

-- Apply a chosen review-base value: clear, set a valid ref, or reject an
-- invalid one. Notifies and calls on_done with the resulting ref (or nil for a
-- clear / invalid / empty selection). Separated from the picker so the decision
-- logic is testable without telescope.
local function apply_selection(root, value, on_done)
  local function done(ref)
    if on_done then
      on_done(ref)
    end
  end
  if not value then
    return done(nil)
  end
  if value == CLEAR_SENTINEL then
    M.clear(root)
    vim.notify("Review base cleared")
    return done(nil)
  end
  if not git.resolve(root, value) then
    vim.notify("Ref does not exist: " .. value, vim.log.levels.ERROR)
    return done(nil)
  end
  M.set(root, value)
  vim.notify("Review base set to " .. value)
  return done(value)
end

M._CLEAR_SENTINEL = CLEAR_SENTINEL
M._build_branch_entry = build_branch_entry
M._apply_selection = apply_selection

-- One shared message so the "outside a repo" warning reads identically wherever
-- it surfaces (here, the smart picker).
M.MSG_NOT_A_REPO = "Not a git repo"

-- Interactive "clear the active base" entry point. M.clear is the silent
-- programmatic setter; this is the user-facing flow (resolve the repo, warn if
-- outside one, else clear + confirm), routed through apply_selection so the
-- "Review base cleared" notice lives in exactly one place. `<leader>gX` delegates
-- here instead of re-implementing the whole flow.
function M.clear_active(start_path)
  local root = git.root(start_path)
  if not root then
    vim.notify(M.MSG_NOT_A_REPO, vim.log.levels.WARN)
    return
  end
  apply_selection(root, CLEAR_SENTINEL)
end

function M.pick(root, on_done)
  if not root then
    vim.notify(M.MSG_NOT_A_REPO, vim.log.levels.WARN)
    if on_done then
      on_done(nil)
    end
    return
  end

  local active = M.get(root)
  local results = { CLEAR_SENTINEL }
  for _, b in ipairs(list_branches(root)) do
    table.insert(results, b)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers
    .new({}, {
      prompt_title = "Review base (current: " .. (active or "none") .. ")",
      finder = finders.new_table({
        results = results,
        entry_maker = function(val)
          return build_branch_entry(val, active)
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_termopen_previewer({
        get_command = function(entry)
          if entry.value == CLEAR_SENTINEL then
            return { "echo", "Clears the saved review base for this repo." }
          end
          return {
            "git",
            "-C",
            root,
            "log",
            "--oneline",
            "--decorate",
            "-n",
            "200",
            entry.value .. "..HEAD",
          }
        end,
      }),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          apply_selection(root, selection and selection.value or nil, on_done)
        end)
        vim.api.nvim_create_autocmd({ "BufWipeout", "BufLeave" }, {
          buffer = prompt_bufnr,
          once = true,
          callback = close_legend,
        })
        return true
      end,
    })
    :find()

  open_legend()
end

return M
