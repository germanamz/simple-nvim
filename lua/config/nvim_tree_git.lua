-- nvim-tree git decorator aligned with the smart pickers: files carry the same
-- porcelain labels (A, M*, ?*, bM, ...) in the same colors, sourced from the
-- same per-cwd codes cache in telescope_smart — so the review base (config
-- .review_base) is honored identically. Replaces nvim-tree's builtin "Git"
-- decorator in the renderer.decorators list. Independent of nvim-tree's builtin
-- git (which is OFF — see lua/plugins/nvim-tree.lua): labels come from
-- telescope_smart, not Filters:git, and repaints from the config() autocmds, not
-- the .git watcher. Ignore-hiding lives in config.ignore_filter.
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

-- Force-refresh the tree's git labels: fetch fresh codes for the cwd off the
-- main thread, then reload so the decorator repaints with them. The one home
-- for the guard/refresh/reload contract shared by the ReviewBaseChanged/
-- HeadChanged and FocusGained handlers (lua/plugins/nvim-tree.lua) and the
-- <leader>gR manual hatch (lua/plugins/gitsigns.lua). No-op when nvim-tree
-- isn't loaded or the tree isn't on screen — skip the git spawn entirely.
function M.refresh_labels()
  if not package.loaded["nvim-tree"] then
    return
  end
  local api = require("nvim-tree.api")
  if not api.tree.is_visible() then
    return
  end
  -- telescope_smart resolved at call time, not module load: the e2e specs spy
  -- on _refresh_async by swapping the module field. Going through the async
  -- core directly (not the deduped non-blocking read) guarantees a refresh
  -- with the *current* inputs even if a prior refresh is still in flight.
  require("config.telescope_smart")._refresh_async(vim.fn.getcwd(), function()
    if api.tree.is_visible() then
      api.tree.reload()
    end
  end)
end

local Decorator

-- Build (once) and return the decorator class. Deferred behind a function
-- because nvim-tree.api is only requirable after the plugin has loaded.
function M.decorator()
  if Decorator then
    return Decorator
  end

  Decorator = require("nvim-tree.api").Decorator:extend()

  -- The status highlight groups are static (default=true), so define them once
  -- here (this builder runs once, memoized) and re-apply on ColorScheme — which
  -- resets highlight groups — instead of on every Decorator:new() (i.e. every
  -- tree render: scroll, expand, focus, SmartCodesRefreshed). Matches the
  -- block_guides/lsp_refs/gitsigns ColorScheme pattern.
  git_status_codes.define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = git_status_codes.define_highlights,
  })

  -- Constructed once per tree render: snapshot the codes cache (500ms TTL, so
  -- repeated renders don't re-shell to git) and the derived directory markers.
  function Decorator:new()
    self.enabled = true
    self.highlight_range = "none"
    self.icon_placement = "before"

    -- self.cwd doubles as telescope_smart's codes-cache key, so it MUST match
    -- the plain getcwd() form every other caller uses (the pickers, the
    -- FocusGained/ReviewBaseChanged handlers). A normalized :p form (trailing
    -- slash) ping-ponged the cache key between '/x' and '/x/': every repaint
    -- missed the just-refreshed entry, blanked the labels for a render, and
    -- kicked a second full recursive scan. path_util.relative :p-normalizes
    -- its base itself, so rendering is unchanged.
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
