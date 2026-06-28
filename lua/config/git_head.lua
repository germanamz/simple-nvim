-- Per-repo HEAD watcher: detects branch changes made outside this nvim
-- instance (checkouts from another terminal, scripts) and broadcasts them as
-- a `User HeadChanged` autocmd with `data = { root, branch }` (branch is nil
-- on detached HEAD). Mirrors config.review_base's store+event shape: this is
-- the only module that knows HEAD changed; consumers keep whatever derived
-- cache suits their rendering and re-sync on the event.
local M = {}

local git = require("util.git")

-- root -> { handle = uv fs_event, sha = string|nil, branch = string|nil, pending = boolean }
local watched = {}

-- Last-seen branch for a watched root, nil when unwatched or detached.
function M.get(root)
  local w = root and watched[root]
  if w then
    return w.branch
  end
  return nil
end

-- Re-resolve HEAD and broadcast only on an actual change — fs events arrive in
-- bursts (lockfile, rename, change) for a single checkout. The gate keys on the
-- resolved object id AND the branch: a `git submodule update` moves the sha
-- while leaving the (detached, nil) branch unchanged, which a branch-only gate
-- would never notice. The broadcast payload stays {root, branch} — consumers
-- only ever care which branch a root is on.
local function check(root)
  local w = watched[root]
  if not w then
    return
  end
  w.pending = false
  local head = git.head(root)
  if head.sha == w.sha and head.branch == w.branch then
    return
  end
  w.sha = head.sha
  w.branch = head.branch
  vim.api.nvim_exec_autocmds("User", {
    pattern = "HeadChanged",
    data = { root = root, branch = head.branch },
  })
end

-- Idempotently start watching `root`'s gitdir for HEAD movement. Returns true
-- when a watcher is (already) running, false when one could not be started
-- (not a repo, fs_event unavailable).
--
-- `seed` (optional) is a { sha, branch } snapshot the caller already resolved
-- (the statusline resolves both in its async spawn), sparing a duplicate
-- blocking git.head() on the first watch of each root. Omit it to resolve here.
-- Both fields follow the module invariant: nil-on-detached (branch) and
-- nil-on-unborn (sha); a "" branch must be normalized to nil before seeding.
function M.watch(root, seed)
  if not root or root == "" then
    return false
  end
  if watched[root] then
    return true
  end
  local gitdir = git.git_dir(root)
  if not gitdir then
    return false
  end
  local handle = vim.uv.new_fs_event()
  if not handle then
    return false
  end
  -- Watch the gitdir, not the HEAD file: git replaces HEAD atomically
  -- (write + rename), which strands a watcher pinned to the old inode.
  if seed == nil then
    seed = git.head(root)
  end
  local w = { handle = handle, sha = seed.sha, branch = seed.branch, pending = false }
  local ok = handle:start(gitdir, {}, function(_, filename)
    if filename and filename ~= "HEAD" then
      return
    end
    if w.pending then
      return
    end
    w.pending = true
    vim.schedule(function()
      check(root)
    end)
  end)
  if ok ~= 0 then
    handle:close()
    return false
  end
  watched[root] = w
  return true
end

-- Close every watcher. Test isolation only.
function M._stop_all()
  for root, w in pairs(watched) do
    if not w.handle:is_closing() then
      w.handle:stop()
      w.handle:close()
    end
    watched[root] = nil
  end
end

return M
