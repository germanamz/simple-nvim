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
