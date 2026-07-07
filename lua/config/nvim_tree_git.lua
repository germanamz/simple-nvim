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
-- Per-cwd trailing coalescing: rapid triggers (rebase, focus toggling) must
-- not stack overlapping whole-tree git pipelines. While one is in flight, new
-- triggers collapse into a single queued rerun that goes back through
-- refresh_labels — so it re-reads cwd/visibility — once the in-flight one
-- completes. At most 1 running + 1 queued, and the final refresh always uses
-- the then-current inputs, which is what the old always-spawn gave us.
local inflight, trailing = {}, {}

function M.refresh_labels()
  if not package.loaded["nvim-tree"] then
    return
  end
  local api = require("nvim-tree.api")
  if not api.tree.is_visible() then
    return
  end
  local cwd = vim.fn.getcwd()
  if inflight[cwd] then
    trailing[cwd] = true
    return
  end
  inflight[cwd] = true
  -- telescope_smart resolved at call time, not module load: the e2e specs spy
  -- on _refresh_async by swapping the module field. Going through the async
  -- core directly (not the deduped non-blocking read) keeps the refresh
  -- unconditional on the 500ms cache TTL.
  require("config.telescope_smart")._refresh_async(cwd, function()
    inflight[cwd] = nil
    if api.tree.is_visible() then
      api.tree.reload()
    end
    if trailing[cwd] then
      trailing[cwd] = nil
      M.refresh_labels()
    end
  end)
end

-- Trailing-slash- and symlink-insensitive directory compare. The decorator
-- keys the codes cache with plain getcwd() like every other caller, so
-- SmartCodesRefreshed's data.cwd matches a raw `==` — this survives as
-- defense in depth for symlinked cwds.
local function same_dir(a, b)
  return vim.fn.resolve(vim.fn.fnamemodify(a, ":p")) == vim.fn.resolve(vim.fn.fnamemodify(b, ":p"))
end

-- Register the repaint autocmds (called from lua/plugins/nvim-tree.lua's
-- config() once the plugin is loaded). One augroup with clear = true keeps
-- re-registration idempotent: a config() re-run (:Lazy reload) replaces the
-- handlers instead of stacking duplicate git pipelines per event.
function M.register_autocmds()
  local group = vim.api.nvim_create_augroup("nvim_tree_git_refresh", { clear = true })
  -- Re-render the tree when the review base or HEAD changes (external
  -- checkout) so labels appear or vanish immediately. Force-refresh the
  -- codes cache first — its 500ms TTL could otherwise serve codes computed
  -- against the old base or branch.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "ReviewBaseChanged", "HeadChanged" },
    callback = function(args)
      -- Both events carry their repo root in data.root and fire per-submodule
      -- (each watched root has its own HEAD watcher). The decorator only ever
      -- computes codes for getcwd(), so a change in a *different* root can't
      -- alter any displayed label — skip the refresh for it. resolve() both
      -- sides so a symlinked cwd still matches.
      local root = args.data and args.data.root
      if root and vim.fn.resolve(root) ~= vim.fn.resolve(vim.fn.getcwd()) then
        return
      end
      M.refresh_labels()
    end,
  })
  -- The codes cache refreshes asynchronously, so the decorator's first render
  -- on a cold cache shows no git labels. When a refresh for the displayed cwd
  -- lands, reload the tree so the labels appear. The reload runs a fresh
  -- decorator pass that reads the now-warm cache (no further async kick), so
  -- this does not loop.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SmartCodesRefreshed",
    callback = function(args)
      local api = require("nvim-tree.api")
      local cwd = args.data and args.data.cwd
      if cwd and same_dir(cwd, vim.fn.getcwd()) and api.tree.is_visible() then
        api.tree.reload()
      end
    end,
  })
  -- Re-sync the git decorations when focus returns to nvim. A commit or
  -- `git add` from another terminal changes file status without moving HEAD,
  -- so config.git_head's HEAD watcher never fires ReviewBaseChanged/HeadChanged
  -- and the labels would stay stale until a manual reload. (gitsigns hunks
  -- and the statusline re-sync on the same FocusGained event from their own
  -- modules.)
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      M.refresh_labels()
    end,
  })
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
  -- Named augroup with clear=true: a rebuild after a package.loaded reset
  -- replaces the autocmd instead of stacking a duplicate.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("nvim_tree_git_hl", { clear = true }),
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
