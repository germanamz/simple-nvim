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

-- Pure: (dir-marker map from _dir_markers, a directory node's relpath) ->
-- decorator icon list, or nil for a clean dir. path_util.relative :p-normalizes
-- the node path, which APPENDS a trailing slash to a directory ("a/b" -> "a/b/"),
-- but _dir_markers keys are slash-free — strip it before the lookup or the marker
-- never matches (the bug that silently hid every directory rollup). Glyph by
-- category: "*" flags a subtree with worktree (uncommitted) changes, mirroring
-- the "*" unstaged marker on file codes; "•" a subtree that only differs from the
-- review base (SmartFilesBase), which is committed, not uncommitted.
function M._dir_icon(dirs, rel)
  local hl = dirs[(rel:gsub("/$", ""))]
  if not hl then
    return nil
  end
  local glyph = hl == "SmartFilesBase" and "•" or "*"
  return { { str = glyph, hl = { hl } } }
end

-- Pure: directory relpath -> highlight group for the subtree marker. A dir
-- containing any worktree change is marked SmartFilesModified; one containing
-- only base-vs-HEAD changes is marked SmartFilesBase. `dirty_subs` (Tier 0) is a
-- set of submodule relpaths that are dirty with NO file codes of their own — a
-- commit-diverged (bumped-pointer) submodule the recursion sees as clean inside;
-- each such submodule marks its own folder AND its ancestors worktree-dirty, so a
-- collapsed folder still shows a bumped submodule buried under it. Modified always
-- dominates Base (a worktree change outranks a base-only sibling).
function M._dir_markers(codes, dirty_subs)
  local dirs = {}
  -- Walk `path`'s ancestor directories, applying `hl`. Modified overwrites; Base
  -- only fills an unmarked dir (so it never demotes a Modified ancestor).
  local function mark_ancestors(path, hl)
    local dir = path
    while true do
      dir = dir:match("^(.*)/[^/]+$")
      if not dir or dir == "" then
        break
      end
      if hl == "SmartFilesModified" then
        dirs[dir] = "SmartFilesModified"
      else
        dirs[dir] = dirs[dir] or "SmartFilesBase"
      end
    end
  end
  for p, code in pairs(codes) do
    mark_ancestors(p, code:sub(1, 1) == "b" and "SmartFilesBase" or "SmartFilesModified")
  end
  for sub in pairs(dirty_subs or {}) do
    dirs[sub] = "SmartFilesModified" -- the submodule folder itself
    mark_ancestors(sub, "SmartFilesModified")
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

-- opts.hard = true force-flushes the branch-fact cache (the definitive
-- HeadChanged / ReviewBaseChanged signals and the manual <leader>gR hatch);
-- otherwise (FocusGained) it revalidates cheaply, keeping every submodule whose
-- git index has not moved. Both then force-refresh the codes cache and reload.
function M.refresh_labels(opts)
  if not package.loaded["nvim-tree"] then
    return
  end
  local api = require("nvim-tree.api")
  if not api.tree.is_visible() then
    return
  end
  -- Reconcile the per-dir branch-fact cache so the root header and visible
  -- submodule labels re-resolve as needed. A hard flush drops everything; a
  -- revalidate keeps entries whose git index is unchanged, so a focus-gain over a
  -- 200-submodule superproject with nothing staged re-resolves NO submodules
  -- (vs. the old invalidate-every-visible-row storm). Only visible consumers
  -- re-request, so non-visible submodules stay out of cache either way.
  local repo_status = require("config.repo_status")
  if opts and opts.hard then
    repo_status.invalidate_all()
  else
    repo_status.revalidate()
  end
  local cwd = vim.fn.getcwd()
  if inflight[cwd] then
    -- OR-accumulate hardness so a HeadChanged coalescing behind an in-flight
    -- FocusGained still force-flushes on the trailing rerun (a HEAD move that
    -- left the index untouched would otherwise survive a soft revalidate).
    local hard = (trailing[cwd] and trailing[cwd].hard) or (opts and opts.hard) or false
    trailing[cwd] = { hard = hard }
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
      local t = trailing[cwd]
      trailing[cwd] = nil
      M.refresh_labels(t.hard and { hard = true } or nil)
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
      -- Definitive change signals: hard-flush the branch-fact cache. A review-base
      -- change is nvim-side state the index key can't see, and a HEAD move may
      -- leave the index untouched (reset --soft) — so revalidate could keep a
      -- stale label. Cheap: these are rare and scoped to the cwd root.
      M.refresh_labels({ hard = true })
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
  -- Reload when a branch-fact resolve lands: config.repo_status fires
  -- RepoStatusChanged { dir } once a `git status --porcelain=v2 --branch`
  -- completes (root header or a visible submodule), and config.nvim_tree_submodule
  -- fires it once the submodule set is enumerated. The reload re-runs both the
  -- root_folder_label and the submodule decorator against the now-warm caches —
  -- a cache hit this time, so it does not loop. Unlike the getcwd-scoped
  -- HeadChanged handler, this repaints regardless of which dir moved, so a
  -- submodule's status lands even though getcwd() is the superproject.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "RepoStatusChanged",
    callback = function()
      local api = require("nvim-tree.api")
      if api.tree.is_visible() then
        api.tree.reload()
      end
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
    -- _refresh also returns the Tier-0 dirty-submodule set (cwd-relative): the
    -- commit-diverged submodules that have no file codes of their own, so their
    -- rollups come from here rather than the recursion.
    local codes, _counts, _base, _root, dirty_subs =
      require("config.telescope_smart")._refresh(self.cwd)
    self.codes = codes
    self.dirs = M._dir_markers(self.codes, dirty_subs)
  end

  function Decorator:icons(node)
    local rel = path_util.relative(node.absolute_path, self.cwd)
    if node.type == "directory" then
      return M._dir_icon(self.dirs, rel)
    end
    local label, hl = git_status_codes.code_to_icon(self.codes[rel])
    return label and { { str = label, hl = hl and { hl } or {} } } or nil
  end

  return Decorator
end

return M
