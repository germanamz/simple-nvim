-- nvim-tree decorator that labels each submodule folder with its own branch and
-- working state (config.repo_status), placed AFTER the folder name. A second
-- decorator from config.nvim_tree_git (which is icon_placement="before"): a
-- decorator carries one placement, so the submodule "after" labels need their
-- own class. Lazy by construction — a decorator only runs on VISIBLE nodes, so a
-- submodule's status is resolved the moment its row appears and never for a
-- submodule you have not navigated to.
local M = {}

local path_util = require("util.path")

-- cwd -> { [superproject-relative submodule path] = true } | "pending". The
-- submodule set for a superproject, discovered once via the cheap .gitmodules
-- enumerator (no per-submodule spawn). Keyed by the enumerator's own paths
-- ("childA", "childA/grand") — which equal the decorator's
-- path_util.relative(node.absolute_path, cwd) lookup when cwd is the
-- superproject root (the workspace case). Keying off the enumerator path rather
-- than re-relativizing against git.root(cwd) sidesteps a symlink trap: git
-- resolves --show-toplevel to the canonical path (/private/var/… on macOS) while
-- cwd may be the logical /var/…, and path_util.relative's :p normalize does not
-- resolve symlinks, so the two would not share a prefix.
local sets = {}

-- Snapshot the submodule set for `cwd`. On a cold cache returns {} and kicks the
-- async enumeration (single-flight via the "pending" marker), firing
-- RepoStatusChanged when the set lands so the tree repaints and the decorator
-- re-runs against the now-warm set. A plain repo (no .gitmodules) caches {} with
-- zero git spawns.
function M._subs_for(cwd)
  local cached = sets[cwd]
  if type(cached) == "table" then
    return cached
  end
  if cached == "pending" then
    return {}
  end
  local root = require("util.git").root(cwd)
  local smart = require("config.telescope_smart")
  if not root or not smart._has_submodules(root) then
    sets[cwd] = {}
    return {}
  end
  sets[cwd] = "pending"
  smart._submodule_paths_async(root, function(paths)
    local set = {}
    for _, p in ipairs(paths) do
      set[p] = true
    end
    sets[cwd] = set
    vim.api.nvim_exec_autocmds("User", { pattern = "RepoStatusChanged", data = { dir = root } })
  end)
  return {}
end

-- Absolute submodule dir -> decorator segments (a leading gap after the folder
-- name, then the branch/status parts), or nil. On a cache miss it schedules a
-- resolve (repo_status.request) and returns nil so the label appears on the
-- repaint that the resolve fires.
function M._segments_for(abs)
  local rs = require("config.repo_status")
  local s = rs.get(abs)
  if not s then
    rs.request(abs)
    return nil
  end
  local segs = rs.segments(s)
  if #segs == 0 then
    return nil
  end
  table.insert(segs, 1, { str = "  ", hl = {} })
  return segs
end

-- Test seam: forget every discovered submodule set.
function M._reset()
  sets = {}
end

local Decorator

-- Build (once) and return the decorator class. Deferred behind a function
-- because nvim-tree.api is only requirable after the plugin has loaded.
function M.decorator()
  if Decorator then
    return Decorator
  end

  Decorator = require("nvim-tree.api").Decorator:extend()

  -- The label groups are static (default=true); define them once here (this
  -- builder is memoized) and re-apply on ColorScheme, matching nvim_tree_git.
  -- Named augroup with clear=true so a package.loaded reset + rebuild replaces
  -- the autocmd instead of stacking a duplicate.
  require("config.repo_status").define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("nvim_tree_submodule_hl", { clear = true }),
    callback = require("config.repo_status").define_highlights,
  })

  function Decorator:new()
    self.enabled = true
    self.highlight_range = "none"
    self.icon_placement = "after"
    self.cwd = vim.fn.getcwd()
    self.subs = M._subs_for(self.cwd)
  end

  function Decorator:icons(node)
    if node.type ~= "directory" then
      return nil
    end
    -- path_util.relative :p-normalizes, which APPENDS a trailing slash for a
    -- directory ("childA" -> "childA/"); strip it so the lookup matches the
    -- slash-free enumerator keys ("childA", "childA/grand").
    local rel = (path_util.relative(node.absolute_path, self.cwd):gsub("/$", ""))
    if not self.subs[rel] then
      return nil
    end
    return M._segments_for(node.absolute_path)
  end

  return Decorator
end

return M
