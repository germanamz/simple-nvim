-- A cmux terminal in the directory you are looking at.
--
-- This Neovim runs inside cmux (see util.cmux), so "a terminal here" means a cmux
-- surface, not a `:terminal` buffer: a tab in Neovim's own pane (`<leader>tt`),
-- or a split beside it (`<leader>tv`, right) or under it (`<leader>th`, down) --
-- Vim's own sense of vertical and horizontal. The new terminal takes focus; you
-- asked for it to type in it.
--
-- "Here" is the current buffer's folder, or, on the nvim-tree buffer, the node
-- under the cursor: a folder opens in itself, a file in its parent -- the same
-- pair of entry points as `<leader>mp` (config.markdown_preview).
--
-- ## Why the splits go through `cmux rpc`
--
-- `new-surface` takes `--working-directory`, but `new-split` has no such flag.
-- The socket method under it, `surface.split`, does take `working_directory`
-- (verified on cmux 0.64.25), so the splits call it raw. Typing a `cd` into the
-- new shell instead is not a fallback: the new shell's first keystrokes are not
-- reliably its own -- oh-my-zsh's "update? [Y/n]" prompt ate the first
-- character in testing.
--
-- Everything is async: every cmux call is a socket round-trip, and none may
-- block the keypress that asked for it.

local cmux = require("util.cmux")

local M = {}

-- "not a cmux session" is a property of the session, so say it once.
local notified = false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "cmux terminal" })
end

local function notify_no_cmux()
  if notified then
    return
  end
  notified = true
  notify(
    "cmux terminal needs cmux: no cmux session detected.\n"
      .. "`<leader>tt` / `<leader>tv` / `<leader>th` open cmux tabs and splits.",
    vim.log.levels.WARN
  )
end

-- Test seam: every cmux invocation funnels through here, so a spec can assert
-- the exact argv with no cmux socket in sight. nil in normal use.
---@type nil|fun(args: string[], on_done: fun(code: integer, stdout: string, stderr: string))
M._run = nil

---@param bin string
---@param args string[]
---@param on_done fun(code: integer, stdout: string, stderr: string)
local function run(bin, args, on_done)
  if M._run then
    return M._run(args, on_done)
  end
  local cmd = { bin }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    -- vim.system's callback lands in a luv context; hop to the main loop so
    -- the handler can notify.
    vim.schedule(function()
      on_done(res.code, res.stdout or "", res.stderr or "")
    end)
  end)
end

-- The folder a terminal for `path` should start in: `path` itself when it is a
-- folder, else its parent -- walking further up past anything that does not
-- exist yet (a buffer for a file you have not saved, in a folder you have not
-- made), since cmux cannot start a shell in a folder that is not there.
local function nearest_dir(path)
  local dir = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  while true do
    local stat = vim.uv.fs_stat(dir)
    if stat and stat.type == "directory" then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      return vim.fn.getcwd()
    end
    dir = parent
  end
end

-- The folder the current buffer stands for. A buffer that is not a file on disk
-- -- unnamed, URL-named (fugitive://, oil://, term://), or special (help,
-- quickfix, a scratch buffer that borrows a real file's name) -- stands for no
-- folder of its own, so it gets Neovim's cwd.
local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%a[%w+.-]*://") or vim.bo.buftype ~= "" then
    return vim.fn.getcwd()
  end
  return nearest_dir(name)
end

-- The folder the nvim-tree node under the cursor stands for. nvim-tree hands out
-- field-only CLONES of its nodes (see config.nvim_tree_hl_decorator), so read
-- absolute_path and ask the filesystem rather than calling node:is_dir(). The
-- root row resolves to the root folder; no node at all means the tree is not
-- really on screen, and Neovim's cwd is the best remaining guess.
local function tree_dir()
  local ok, api = pcall(require, "nvim-tree.api")
  local node = ok and api.tree.get_node_under_cursor() or nil
  local path = type(node) == "table" and node.absolute_path or nil
  if type(path) ~= "string" or path == "" then
    return vim.fn.getcwd()
  end
  return nearest_dir(path)
end

-- The cmux argv that opens a terminal of `kind` in `dir`.
---@param kind "tab"|"right"|"down"
---@param dir string
---@return string[]
local function args_for(kind, dir)
  if kind == "tab" then
    -- No --pane: cmux defaults to the focused pane of the caller's workspace,
    -- which is Neovim's own at the moment of the keypress.
    return { "new-surface", "--working-directory", dir, "--focus", "true" }
  end
  return {
    "rpc",
    "surface.split",
    vim.json.encode({
      direction = kind,
      -- Split Neovim's surface, not whichever one cmux thinks is focused.
      surface_id = vim.env.CMUX_SURFACE_ID,
      working_directory = dir,
      focus = true,
    }),
  }
end

--- Open a cmux terminal of `kind` in `dir`.
---@param kind "tab"|"right"|"down"
---@param dir string
function M.open(kind, dir)
  local bin = cmux.bin()
  if not bin then
    return notify_no_cmux()
  end
  run(bin, args_for(kind, dir), function(code, _, stderr)
    if code ~= 0 then
      local why = vim.trim(stderr)
      notify(
        "cmux could not open a terminal in " .. dir .. (why ~= "" and (":\n" .. why) or ""),
        vim.log.levels.WARN
      )
    end
  end)
end

-- lhs -> the kind of terminal it opens, and its desc.
local KEYS = {
  { "<leader>tt", "tab", "Terminal tab here (cmux)" },
  { "<leader>tv", "right", "Terminal split right here (cmux)" },
  { "<leader>th", "down", "Terminal split below here (cmux)" },
}

--- Install the global `<leader>t*` maps, which open in the current buffer's
--- folder. Called once from init.lua.
function M.setup()
  for _, key in ipairs(KEYS) do
    local lhs, kind, desc = key[1], key[2], key[3]
    vim.keymap.set("n", lhs, function()
      M.open(kind, buffer_dir())
    end, { desc = desc })
  end
end

--- Install the same maps on the nvim-tree buffer, opening in the folder of the
--- node under the cursor instead. Called from nvim-tree's on_attach (see
--- lua/plugins/nvim-tree.lua).
function M.set_tree_keymaps(buf)
  for _, key in ipairs(KEYS) do
    local lhs, kind, desc = key[1], key[2], key[3]
    vim.keymap.set("n", lhs, function()
      M.open(kind, tree_dir())
    end, { buffer = buf, nowait = true, desc = desc })
  end
end

--- Test seam: forget the one-shot "no cmux" notice, so each spec starts from a
--- clean session.
function M._reset()
  notified = false
end

return M
