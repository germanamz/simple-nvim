-- Per-repo "review base" ref used by other modules to diff vs a chosen branch
-- (e.g. origin/main) instead of the index. Persisted in stdpath("data") as a
-- JSON map keyed by absolute repo toplevel path. Changes are broadcast via a
-- `User ReviewBaseChanged` autocmd whose `data` is `{ root, ref }`. Consumers
-- read state via `M.get(root)` or listen to the autocmd.
local M = {}

local STATE_PATH = vim.fn.stdpath("data") .. "/nvim-review-base.json"

local function read_state()
  local f = io.open(STATE_PATH, "r")
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
  local tmp = STATE_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
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
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]
end

function M.resolve(root, ref)
  if not root or not ref or ref == "" then
    return false
  end
  vim.fn.system({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref })
  return vim.v.shell_error == 0
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
          if not selection then
            if on_done then
              on_done(nil)
            end
            return
          end
          if selection.value == CLEAR_SENTINEL then
            M.clear(root)
            vim.notify("Review base cleared")
            if on_done then
              on_done(nil)
            end
            return
          end
          if not M.resolve(root, selection.value) then
            vim.notify("Ref does not exist: " .. selection.value, vim.log.levels.ERROR)
            if on_done then
              on_done(nil)
            end
            return
          end
          M.set(root, selection.value)
          vim.notify("Review base set to " .. selection.value)
          if on_done then
            on_done(selection.value)
          end
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
