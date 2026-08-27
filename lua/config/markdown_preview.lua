-- Markdown preview in a cmux panel.
--
-- This Neovim runs inside cmux, a Ghostty-based terminal whose `markdown`
-- surface renders a file with real formatting and re-renders it whenever the
-- file changes on disk. `<leader>mp` hands a file to one of those panels, so the
-- reading view is a native cmux panel rather than anything Neovim draws. (It
-- replaces an in-Neovim `glow` terminal-buffer preview, which had to re-run glow
-- on every edit and could never render a table and prose at once.)
--
-- Everything is async. A preview must never block the keypress that asked for
-- it, and every cmux call is a socket round-trip.
--
-- ## One pane, many tabs
--
-- cmux has no "open a markdown panel *into* pane X" primitive: `markdown open`
-- always splits a fresh pane, and `new-surface --type markdown` silently
-- degrades to a plain terminal. So the second and later files are opened and
-- then moved:
--
--   markdown open <file> --focus false --surface <a surface in the preview pane>
--   move-surface --surface <the new panel> --pane <the preview pane>
--   focus-pane --pane <the pane the keypress came from>
--
-- `--surface` on the open is what keeps the editor still: the transient pane is
-- split off the preview column, not off Neovim's own window, so the editor never
-- resizes. The trailing `focus-pane` is not optional -- `move-surface` ignores
-- `--focus false` and takes focus every single time.
--
-- ## Why paths, not buffer numbers
--
-- State keys on the file's absolute path because `<leader>mp` also fires from
-- nvim-tree, where there is no buffer to key on. That also makes the toggle
-- symmetric: open a file's preview from the tree, close it from the buffer.
-- Nothing here watches buffer lifecycle -- a cmux panel is an independent pane
-- with its own file watcher, and wiping the buffer is not a reason to kill it.
--
-- ## What you see is what is on disk
--
-- cmux watches and renders the file on disk, so an unsaved buffer previews as
-- its last saved state. The keymap says so rather than writing your file behind
-- your back; every later save re-renders the panel on its own.

local cmux = require("util.cmux")
local ft_util = require("util.ft")

local M = {}

-- Absolute file path -> the cmux surface (panel tab) currently showing it.
local surfaces = {}

-- The cmux pane every preview tabs into, plus a surface known to live in it.
-- The surface is the anchor we split from, so a new panel is born in the preview
-- column rather than shrinking the editor.
local preview_pane, pane_surface = nil, nil

-- The pane Neovim itself lives in, for handing focus back after a move.
--
-- It CANNOT be read off the open response: `--surface <anchor>` makes the anchor
-- the split source, so an anchored open reports the *preview* pane as
-- source_pane_id, and focusing that would leave focus exactly where the move
-- stranded it. So it comes from the discovery call's `caller`, or from an
-- unanchored open, where source_pane_id really is us.
local caller_pane = nil

-- Pane discovery runs once per session, lazily, before the first open.
local discovered = false

-- "not a cmux session" is a property of the session, so say it once.
local notified = false

-- Forward declaration: close() re-opens when its surface turns out to be gone.
local open

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "markdown preview" })
end

local function notify_no_cmux()
  if notified then
    return
  end
  notified = true
  notify(
    "markdown preview needs cmux: no cmux session detected.\n"
      .. "`<leader>mp` renders through a cmux markdown panel.",
    vim.log.levels.WARN
  )
end

-- Test seam: every cmux invocation funnels through here, so a spec can drive the
-- whole state machine -- open, move, focus, and each failure branch -- with no
-- cmux socket in sight. nil in normal use.
---@type nil|fun(args: string[], on_done: fun(code: integer, stdout: string))
M._run = nil

---@param bin string
---@param args string[]
---@param on_done fun(code: integer, stdout: string)
local function run(bin, args, on_done)
  if M._run then
    return M._run(args, on_done)
  end
  local cmd = { bin }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    -- vim.system's callback lands in a luv context; hop to the main loop so
    -- handlers can notify and touch the editor freely.
    vim.schedule(function()
      on_done(res.code, res.stdout or "")
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

-- One canonical spelling of a path, since it is the state key and reaches us
-- from two places -- a buffer name and an nvim-tree node -- that need not agree
-- about symlinks. On macOS /tmp is a symlink to /private/tmp, so the same file
-- can arrive under two names and desync the toggle into opening a second tab it
-- then cannot close. fs_realpath settles it.
--
-- It settles it only for a path that EXISTS, though: realpath fails outright on
-- a file not yet written, which is a real case here (a markdown buffer for a
-- file you have not saved). So when the whole path will not resolve, walk up to
-- the deepest ancestor that does, resolve that, and re-attach the tail -- which
-- collapses /tmp/new.md and /private/tmp/new.md just the same. Only a path with
-- no resolvable ancestor at all falls back to plain normalization.
local function canonical(path)
  local full = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local resolved = vim.uv.fs_realpath(full)
  if resolved then
    return resolved
  end
  local tail, dir = {}, full
  while true do
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      return full
    end
    table.insert(tail, 1, vim.fs.basename(dir))
    local real = vim.uv.fs_realpath(parent)
    if real then
      return vim.fs.normalize(real .. "/" .. table.concat(tail, "/"))
    end
    dir = parent
  end
end

-- The id of a surface in `pane` when every surface in it is a cmux markdown
-- panel, else nil. An empty pane doesn't qualify.
local function markdown_anchor(pane)
  local list = pane.surfaces or {}
  if #list == 0 then
    return nil
  end
  for _, surface in ipairs(list) do
    if surface.type ~= "markdown" then
      return nil
    end
  end
  return list[1].id
end

-- Adopt an all-markdown pane in the caller's workspace as the preview pane, so a
-- Neovim restart tabs back into the panel column it was already using instead of
-- splitting a second one beside it.
--
-- Pane-level only: a surface's JSON carries a basename title and a null `url`,
-- never the file it renders, so panels opened before this session cannot be
-- matched back to their paths. Re-previewing one of those files opens a second
-- tab for it. Reusing the *wrong* file's tab would be worse than that, and
-- basenames collide (every repo has a README.md), so we don't guess.
local function discover(bin, done)
  if discovered then
    return done()
  end
  discovered = true
  run(bin, { "--json", "--id-format", "both", "tree" }, function(code, stdout)
    local tree = code == 0 and decode(stdout) or nil
    local caller = tree and tree.caller
    caller_pane = (caller and caller.pane_id) or caller_pane
    local workspace = caller and caller.workspace_id
    if not workspace then
      return done()
    end
    for _, window in ipairs(tree.windows or {}) do
      for _, ws in ipairs(window.workspaces or {}) do
        if ws.id == workspace then
          for _, pane in ipairs(ws.panes or {}) do
            local anchor = markdown_anchor(pane)
            if anchor then
              preview_pane, pane_surface = pane.id, anchor
              return done()
            end
          end
        end
      end
    end
    done()
  end)
end

-- cmux renders the file on disk, so a modified buffer would preview as its last
-- saved state. Say so; don't write the user's file for them.
local function warn_if_modified(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- Canonicalize both sides. `path` has already been through canonical(), so
    -- comparing a raw buffer name against it would silently miss the buffer
    -- whenever Neovim hands the name back unresolved, and skip the warning on
    -- exactly the symlinked files canonical() exists to reconcile.
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name ~= "" and canonical(name) == path then
      if vim.bo[buf].modified then
        notify(
          "showing the last saved version — the buffer has unsaved changes",
          vim.log.levels.WARN
        )
      end
      return
    end
  end
end

-- Hand `path` to a cmux markdown panel and tab it into the preview pane.
open = function(path)
  local bin = cmux.bin()
  if not bin then
    return notify_no_cmux()
  end
  warn_if_modified(path)
  discover(bin, function()
    local attempt
    attempt = function(use_anchor)
      local args = { "--json", "--id-format", "both", "markdown", "open", path, "--focus", "false" }
      local anchor = use_anchor and pane_surface or nil
      if anchor then
        vim.list_extend(args, { "--surface", anchor })
      end
      run(bin, args, function(code, stdout)
        local res = code == 0 and decode(stdout) or nil
        if not (res and res.surface_id) then
          if anchor then
            -- The anchor tab is gone. Keep the pane -- its other tabs may well
            -- be alive -- and retry from the caller's own surface; the move
            -- below still lands the panel in the right column.
            pane_surface = nil
            return attempt(false)
          end
          return notify(
            "cmux could not open " .. vim.fn.fnamemodify(path, ":t"),
            vim.log.levels.WARN
          )
        end
        -- An unanchored open split from us, so its source IS our pane. Worth
        -- recording: it is the only route to the caller when discovery failed.
        if not anchor and res.source_pane_id then
          caller_pane = res.source_pane_id
        end
        surfaces[path] = res.surface_id
        if not preview_pane or res.target_pane_id == preview_pane then
          preview_pane, pane_surface = res.target_pane_id, res.surface_id
          return
        end
        local move = { "move-surface", "--surface", res.surface_id, "--pane", preview_pane }
        run(bin, move, function(move_code)
          if move_code ~= 0 then
            -- The preview pane is gone. The panel is already open where it
            -- landed, so that becomes the preview pane -- and nothing stole
            -- focus, so there is nothing to put back.
            preview_pane, pane_surface = res.target_pane_id, res.surface_id
            return
          end
          pane_surface = res.surface_id
          -- move-surface ignores `--focus false`, so focus is sitting in the
          -- preview pane now. Put it back where the keypress came from. Not
          -- knowing where that is beats guessing: focusing the wrong pane would
          -- yank the user somewhere they never asked to go.
          if caller_pane then
            run(bin, { "focus-pane", "--pane", caller_pane }, function() end)
          end
        end)
      end)
    end
    attempt(true)
  end)
end

-- Close `path`'s panel tab.
local function close(path)
  local id = surfaces[path]
  surfaces[path] = nil
  local bin = cmux.bin()
  if not (bin and id) then
    return
  end
  if pane_surface == id then
    pane_surface = nil
  end
  run(bin, { "close-surface", "--surface", id }, function(code)
    -- Exit 1 is "Surface not found": that tab had already been closed by hand,
    -- so the toggle was a press behind. Open it rather than making you press
    -- again to get back to where you thought you were.
    if code ~= 0 then
      open(path)
    end
  end)
end

--- Toggle the cmux preview panel for an absolute file path.
---@param path string
function M.toggle(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  if surfaces[path] then
    close(path)
  else
    open(path)
  end
end

-- Install `<leader>mp` on a markdown-family buffer. Called from config.options'
-- single markdown FileType autocmd (the one entry point for the family), not
-- from a FileType autocmd here.
function M.set_keymap(buf)
  vim.keymap.set("n", "<leader>mp", function()
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
      return notify("nothing to preview: this buffer has no file on disk")
    end
    M.toggle(canonical(name))
  end, { buffer = buf, desc = "Toggle markdown preview" })
end

-- Install `<leader>mp` on the nvim-tree buffer, previewing the node under the
-- cursor without opening it in a buffer first. Called from nvim-tree's
-- on_attach (see lua/plugins/nvim-tree.lua).
function M.set_tree_keymap(buf)
  vim.keymap.set("n", "<leader>mp", function()
    local ok, api = pcall(require, "nvim-tree.api")
    local node = ok and api.tree.get_node_under_cursor() or nil
    -- nvim-tree hands out field-only CLONES of its nodes -- fields, no methods
    -- (see config.nvim_tree_hl_decorator) -- so read absolute_path and ask the
    -- filesystem, rather than calling node:is_dir() and friends.
    local path = type(node) == "table" and node.absolute_path or nil
    if type(path) ~= "string" or path == "" then
      return notify("no file under the cursor")
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      return notify("not a file: " .. vim.fn.fnamemodify(path, ":t"))
    end
    if not ft_util.is_markdown_path(path) then
      return notify("not a markdown file: " .. vim.fn.fnamemodify(path, ":t"))
    end
    M.toggle(canonical(path))
  end, { buffer = buf, nowait = true, desc = "Toggle markdown preview" })
end

M.open = function(path)
  open(path)
end
M.close = close
M._canonical = canonical
M._markdown_anchor = markdown_anchor

--- Test seam: forget every tracked panel, the preview pane, and the one-shot
--- notices, so each spec starts from a clean session.
function M._reset()
  surfaces = {}
  preview_pane, pane_surface, caller_pane = nil, nil, nil
  discovered, notified = false, false
end

--- Test seam: the state machine's current view of the world.
function M._state()
  return { pane = preview_pane, anchor = pane_surface, caller = caller_pane, surfaces = surfaces }
end

return M
