-- Per-repo "review base" ref used by other modules to diff vs a chosen branch
-- (e.g. origin/main) instead of the index. Persisted in stdpath("data") as a
-- JSON map keyed by absolute repo toplevel path. Changes are broadcast via a
-- `User ReviewBaseChanged` autocmd whose `data` is `{ root, ref }`. Consumers
-- read state via `M.get(root)` or listen to the autocmd.
local M = {}

local git = require("util.git")
local Overlay = require("util.overlay")

-- Resolved per call, not at require time: stdpath("data") follows
-- $XDG_DATA_HOME at call time, and the test harness swaps that per test for
-- isolation. Baking the path at first require made state reads/writes land in
-- whichever (possibly since-deleted) environment happened to load this module
-- first.
local function state_path()
  return vim.fn.stdpath("data") .. "/nvim-review-base.json"
end

local function read_state()
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

local function write_state(state)
  local tmp = state_path() .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(state))
  f:close()
  os.rename(tmp, state_path())
end

local function fire(root, ref)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ReviewBaseChanged",
    data = { root = root, ref = ref },
  })
end

function M.git_root(start_path)
  return git.root(start_path)
end

function M.resolve(root, ref)
  return git.resolve(root, ref)
end

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
  state[root] = ref
  write_state(state)
  fire(root, ref)
end

function M.clear(root)
  if not root then
    return
  end
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
  vim.api.nvim_set_hl(0, "ReviewBaseActive", { fg = "#5aa0d4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewBaseLegend", { fg = "#888888", default = true })
  local text = " ● active base "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("review_base_legend")
  vim.api.nvim_buf_add_highlight(buf, ns, "ReviewBaseActive", 0, 1, 4)
  vim.api.nvim_buf_add_highlight(buf, ns, "ReviewBaseLegend", 0, 4, #text)
  local width = vim.api.nvim_strwidth(text)
  legend:mount(buf, {
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
    if vim.v.shell_error ~= 0 then
      return {}
    end
    return out
  end
  local entries, seen = {}, {}
  local function push(ref)
    if not ref or ref == "" or seen[ref] then
      return
    end
    seen[ref] = true
    table.insert(entries, ref)
  end
  local head = run({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  push(head[1])
  local up = run({ "git", "-C", root, "rev-parse", "--abbrev-ref", "@{upstream}" })
  push(up[1])
  for _, b in ipairs(run({ "git", "-C", root, "branch", "--format=%(refname:short)" })) do
    push(b)
  end
  for _, b in ipairs(run({ "git", "-C", root, "branch", "-r", "--format=%(refname:short)" })) do
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
  if not M.resolve(root, value) then
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

function M.pick(root, on_done)
  if not root then
    vim.notify("Not a git repo", vim.log.levels.WARN)
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
