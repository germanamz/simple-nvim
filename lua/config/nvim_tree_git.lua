-- nvim-tree git decorator aligned with the smart pickers: files carry the same
-- porcelain labels (A, M*, ?*, bM, ...) in the same colors, sourced from the
-- same per-cwd codes cache in telescope_smart — so the review base (config
-- .review_base) is honored identically. Replaces nvim-tree's builtin "Git"
-- decorator in the renderer.decorators list; git.enable stays on so the
-- git_ignored filter and the .git watcher keep working.
local M = {}

local git_status_codes = require("config.git_status_codes")
local path_util = require("util.path")

-- Pure: directory relpath -> highlight group for the subtree marker. A dir
-- containing any worktree change is marked SmartFilesModified; one containing
-- only base-vs-HEAD changes is marked SmartFilesBase.
function M._dir_markers(codes)
  local dirs = {}
  for p, code in pairs(codes) do
    local base_only = code:sub(1, 1) == "b"
    local dir = p
    while true do
      dir = dir:match("^(.*)/[^/]+$")
      if not dir or dir == "" then
        break
      end
      if base_only then
        dirs[dir] = dirs[dir] or "SmartFilesBase"
      else
        dirs[dir] = "SmartFilesModified"
      end
    end
  end
  return dirs
end

local Decorator

-- Build (once) and return the decorator class. Deferred behind a function
-- because nvim-tree.api is only requirable after the plugin has loaded.
function M.decorator()
  if Decorator then
    return Decorator
  end

  Decorator = require("nvim-tree.api").Decorator:extend()

  -- Constructed once per tree render: snapshot the codes cache (500ms TTL, so
  -- repeated renders don't re-shell to git) and the derived directory markers.
  function Decorator:new()
    self.enabled = true
    self.highlight_range = "none"
    self.icon_placement = "before"

    git_status_codes.define_highlights()
    self.cwd = vim.fn.getcwd()
    self.codes = require("config.telescope_smart")._refresh(self.cwd)
    self.dirs = M._dir_markers(self.codes)
  end

  function Decorator:icons(node)
    local rel = path_util.relative(node.absolute_path, self.cwd)
    if node.type == "directory" then
      local hl = self.dirs[rel]
      return hl and { { str = "•", hl = { hl } } } or nil
    end
    local label, hl = git_status_codes.code_to_icon(self.codes[rel])
    return label and { { str = label, hl = hl and { hl } or {} } } or nil
  end

  return Decorator
end

return M
