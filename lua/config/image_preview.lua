-- Images opened from nvim-tree, shown in a cmux image viewer instead of a buffer.
--
-- Pressing <CR> on a png used to read it into a buffer as bytes. This Neovim
-- runs inside cmux (see util.cmux), whose `open` shows an image in a file-preview
-- tab, so the tree's open keys hand image files to cmux instead. Every other node
-- opens exactly as before.
--
-- ## A pane beside the editor
--
-- `open` can only tab a file into a pane that already exists, and left to itself
-- it picks Neovim's own, where the image would cover the editor. So the first
-- image goes to a pane beside it, and every later image tabs into that same
-- pane:
--
--   list-panes --workspace <Neovim's>                     (anything open beside us?)
--   open <file> --pane <the biggest other pane> --no-focus
--
-- Only when Neovim is alone in its workspace is a pane made for it, since a
-- split squeezes whatever is already on screen. The image is opened hidden in
-- Neovim's own pane and that tab split off:
--
--   open <file> --no-focus --surface <Neovim's surface>   (a hidden tab in our pane)
--   split-off --surface <that tab> right --focus false    (now a pane of its own)
--
-- None of these take focus (verified on cmux 0.64.25), so the cursor stays in
-- the tree and you can keep walking it, while each newly opened tab becomes the
-- one its pane shows. Closing the pane's last tab closes the pane; the next
-- open's "Pane not found" is the cue to look for a pane again.
--
-- cmux does not dedupe -- the same file opened twice is two tabs -- so each path
-- remembers its tab, and re-opening a file swaps the old tab for a new one: open
-- first, then close, since closing a pane's only tab would take the pane too.
--
-- Outside cmux, images go to the system viewer via `vim.ui.open`, which beats a
-- buffer of PNG bytes just the same.
--
-- Everything is async: every cmux call is a socket round-trip, and none may
-- block the keypress that asked for it.

local cmux = require("util.cmux")

local M = {}

-- Raster formats only. SVG is left out on purpose: it is markup you may well
-- want to edit, so <CR> keeps opening it as text (nvim-tree's `s` still shows it
-- rendered, in the system viewer).
local IMAGE_EXTS = {}
for _, ext in ipairs({
  "avif",
  "bmp",
  "gif",
  "heic",
  "heif",
  "icns",
  "ico",
  "jpeg",
  "jpg",
  "png",
  "tif",
  "tiff",
  "webp",
}) do
  IMAGE_EXTS[ext] = true
end

-- The cmux pane images tab into.
local pane = nil

-- Absolute file path -> the cmux surface (tab) showing it.
local surfaces = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "image preview" })
end

-- Test seam: every cmux invocation funnels through here, so a spec can drive the
-- whole flow -- split, tab, swap, and each failure branch -- with no cmux socket
-- in sight. nil in normal use.
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
    -- handlers can notify.
    vim.schedule(function()
      on_done(res.code, res.stdout or "", res.stderr or "")
    end)
  end)
end

---@return table|nil
local function decode(stdout)
  local ok, value = pcall(vim.json.decode, stdout)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

-- The tab an `open` made. cmux answers with one `opened` entry per path given,
-- and we only ever give one.
local function opened_tab(stdout)
  local res = decode(stdout)
  local first = res and type(res.opened) == "table" and res.opened[1]
  local payload = type(first) == "table" and first.payload or nil
  return type(payload) == "table" and payload.surface_id or nil
end

local function failed(path, stderr)
  local why = vim.trim(stderr or "")
  notify(
    "cmux could not show " .. vim.fn.fnamemodify(path, ":t") .. (why ~= "" and (":\n" .. why) or ""),
    vim.log.levels.WARN
  )
end

--- Is `path` an image, judged by its extension?
---@param path string|nil
---@return boolean
function M.is_image(path)
  local ext = type(path) == "string" and path:match("[^/]%.(%w+)$") or nil
  return ext ~= nil and IMAGE_EXTS[ext:lower()] == true
end

-- The pane to tab an image into when we have none: the biggest pane in Neovim's
-- workspace other than Neovim's own, or nil when Neovim is alone in it. Also nil
-- when cmux will not say which pane is Neovim's: any pick could then be the
-- editor itself, and a split is the safe answer.
--
-- Picking the biggest keeps an image off a short terminal strip when a full
-- height pane is open too. Panes from an earlier session count like any other,
-- so after a restart images tab back into the column they were using. Their old
-- tabs cannot be matched back to paths, though -- a surface's JSON names no file
-- -- so re-opening one of those images gives it a second tab.
local function pick_pane(bin, done)
  local args = { "--json", "--id-format", "both", "list-panes" }
  -- Neovim's workspace, not whichever one cmux thinks is focused.
  if vim.env.CMUX_WORKSPACE_ID then
    vim.list_extend(args, { "--workspace", vim.env.CMUX_WORKSPACE_ID })
  end
  run(bin, args, function(code, stdout)
    local res = code == 0 and decode(stdout) or nil
    local panes = res and type(res.panes) == "table" and res.panes or {}
    local own
    for _, p in ipairs(panes) do
      if vim.tbl_contains(p.surface_ids or {}, vim.env.CMUX_SURFACE_ID) then
        own = p.id
      end
    end
    if not own then
      return done(nil)
    end
    local best, best_area
    for _, p in ipairs(panes) do
      local frame = p.pixel_frame or {}
      local area = (frame.width or 0) * (frame.height or 0)
      if p.id ~= own and (not best or area > best_area) then
        best, best_area = p.id, area
      end
    end
    done(best)
  end)
end

-- Record `id` as the tab showing `path`, closing the tab it replaces.
local function remember(bin, path, id)
  local old = surfaces[path]
  surfaces[path] = id
  if old and old ~= id then
    -- Already gone if you closed it by hand, which is just as good.
    run(bin, { "close-surface", "--surface", old }, function() end)
  end
end

-- Open `path` hidden in Neovim's own pane and split that tab off to the right,
-- making the pane every later image tabs into.
local function open_split(bin, path)
  local args = { "--json", "--id-format", "both", "open", path, "--no-focus" }
  -- Neovim's pane, not whichever one cmux thinks is focused.
  if vim.env.CMUX_SURFACE_ID then
    vim.list_extend(args, { "--surface", vim.env.CMUX_SURFACE_ID })
  end
  run(bin, args, function(code, stdout, stderr)
    local tab = code == 0 and opened_tab(stdout) or nil
    if not tab then
      return failed(path, stderr)
    end
    local split = {
      "--json",
      "--id-format",
      "both",
      "split-off",
      "--surface",
      tab,
      "right",
      "--focus",
      "false",
    }
    run(bin, split, function(split_code, split_out, split_err)
      local res = split_code == 0 and decode(split_out) or nil
      if not (res and res.pane_id) then
        -- The tab is sitting unselected behind the editor; don't leave it there.
        run(bin, { "close-surface", "--surface", tab }, function() end)
        return failed(path, split_err)
      end
      pane = res.pane_id
      remember(bin, path, tab)
    end)
  end)
end

-- The argv that tabs `path` into `target` without focusing it.
local function open_into(path, target)
  return { "--json", "--id-format", "both", "open", path, "--pane", target, "--no-focus" }
end

-- Find `path` a pane when we have none: one already open beside Neovim, or else
-- a new split.
local function place(bin, path)
  pick_pane(bin, function(target)
    if not target then
      return open_split(bin, path)
    end
    run(bin, open_into(path, target), function(code, stdout, stderr)
      local tab = code == 0 and opened_tab(stdout) or nil
      if not tab then
        return failed(path, stderr)
      end
      pane = target
      remember(bin, path, tab)
    end)
  end)
end

--- Show the image at `path`: in a cmux pane beside Neovim, or in the system
--- viewer outside cmux.
---@param path string
function M.open(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  local bin = cmux.bin()
  if not bin then
    local _, err = vim.ui.open(path)
    if err then
      notify(err, vim.log.levels.WARN)
    end
    return
  end
  -- One spelling per file, since it keys the tab swap.
  path = vim.uv.fs_realpath(path) or path
  if not pane then
    return place(bin, path)
  end
  local target = pane
  run(bin, open_into(path, target), function(code, stdout)
    local tab = code == 0 and opened_tab(stdout) or nil
    if not tab then
      -- "Pane not found": its last tab was closed, which closes the pane.
      if pane == target then
        pane = nil
      end
      return place(bin, path)
    end
    remember(bin, path, tab)
  end)
end

-- nvim-tree's default open keys, with the api.node.open action and description
-- each is bound to in nvim-tree's own default_on_attach.
local TREE_KEYS = {
  { "<CR>", "edit", "Open" },
  { "o", "edit", "Open" },
  { "<2-LeftMouse>", "edit", "Open" },
  { "O", "no_window_picker", "Open: No Window Picker" },
  { "<C-e>", "replace_tree_buffer", "Open: In Place" },
  { "<C-t>", "tab", "Open: New Tab" },
  { "<C-v>", "vertical", "Open: Vertical Split" },
  { "<C-x>", "horizontal", "Open: Horizontal Split" },
  { "<Tab>", "preview", "Open Preview" },
}

--- Rebind the tree's open keys so an image node opens in cmux and every other
--- node does what the key always did. Call from nvim-tree's on_attach, after
--- default_on_attach (see lua/plugins/nvim-tree.lua). An image opened this way
--- leaves the tree open, unlike a file opened into a window.
function M.set_tree_keymaps(buf)
  local api = require("nvim-tree.api")
  for _, key in ipairs(TREE_KEYS) do
    local lhs, action, desc = key[1], key[2], key[3]
    vim.keymap.set(
      "n",
      lhs,
      function()
        -- nvim-tree hands out field-only CLONES of its nodes (see
        -- config.nvim_tree_hl_decorator), so read absolute_path and ask the
        -- filesystem rather than calling node methods. A folder named foo.png
        -- still toggles.
        local node = api.tree.get_node_under_cursor()
        local path = type(node) == "table" and node.absolute_path or nil
        if M.is_image(path) then
          local stat = vim.uv.fs_stat(path)
          if stat and stat.type == "file" then
            return M.open(path)
          end
        end
        api.node.open[action]()
      end,
      { buffer = buf, noremap = true, silent = true, nowait = true, desc = "nvim-tree: " .. desc }
    )
  end
end

--- Test seam: forget the pane and every tracked tab, so each spec starts from a
--- clean session.
function M._reset()
  pane, surfaces = nil, {}
end

--- Test seam: the module's current view of the world.
function M._state()
  return { pane = pane, surfaces = surfaces }
end

return M
