-- Per-repo HEAD watcher: detects branch changes made outside this nvim
-- instance (checkouts from another terminal, scripts) and broadcasts them as
-- a `User HeadChanged` autocmd with `data = { root, branch }` (branch is nil
-- on detached HEAD). Mirrors config.review_base's store+event shape: this is
-- the only module that knows HEAD changed; consumers keep whatever derived
-- cache suits their rendering and re-sync on the event.
local M = {}

local git = require("util.git")

-- root -> { handle = uv fs_event, branch = string|nil, pending = boolean }
local watched = {}

-- Last-seen branch for a watched root, nil when unwatched or detached.
function M.get(root)
  local w = root and watched[root]
  if w then
    return w.branch
  end
  return nil
end

-- Re-resolve the branch and broadcast only on an actual change — fs events
-- arrive in bursts (lockfile, rename, change) for a single checkout.
local function check(root)
  local w = watched[root]
  if not w then
    return
  end
  w.pending = false
  local branch = git.branch(root)
  if branch == w.branch then
    return
  end
  w.branch = branch
  vim.api.nvim_exec_autocmds("User", {
    pattern = "HeadChanged",
    data = { root = root, branch = branch },
  })
end

-- Idempotently start watching `root`'s gitdir for HEAD movement. Returns true
-- when a watcher is (already) running, false when one could not be started
-- (not a repo, fs_event unavailable).
--
-- `branch` (optional) seeds the last-seen branch with a value the caller already
-- resolved, sparing a duplicate blocking git.branch() spawn on the first watch
-- of each root. Pass nil for detached HEAD / unknown (NOT "" — the module's
-- invariant is nil-on-detached); nil falls back to resolving here.
function M.watch(root, branch)
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
  local seed = branch
  if seed == nil then
    seed = git.branch(root)
  end
  local w = { handle = handle, branch = seed, pending = false }
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
