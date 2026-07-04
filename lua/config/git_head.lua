-- Per-repo HEAD watcher: detects branch changes made outside this nvim
-- instance (checkouts from another terminal, scripts) and broadcasts them as
-- a `User HeadChanged` autocmd with `data = { root, branch }` (branch is nil
-- on detached HEAD). Mirrors config.review_base's store+event shape: this is
-- the only module that knows HEAD changed; consumers keep whatever derived
-- cache suits their rendering and re-sync on the event.
local M = {}

local git = require("util.git")

-- root -> { handle = uv fs_event, sha, branch, pending = boolean, recheck = boolean }
-- pending: a resolve is in flight (single-flight). recheck: a HEAD event landed
-- mid-resolve, so re-run once on completion.
local watched = {}

-- Last-seen branch for a watched root, nil when unwatched or detached.
function M.get(root)
  local w = root and watched[root]
  if w then
    return w.branch
  end
  return nil
end

-- Resolve HEAD for `root` off the main thread, calling cb with the { sha, branch }
-- shape (or nil when the process can't be spawned). Returns true when it spawned.
-- This is the second documented synchronous-layer exception (see util.git): the
-- watcher must never block the UI thread on a checkout that moves HEAD across
-- many submodule gitdirs at once.
function M._resolve_head(root, cb)
  return (
    pcall(
      vim.system,
      vim.list_extend({ "git", "-C", root }, git.HEAD_ARGS),
      { text = true },
      function(out)
        local head =
          git.parse_head(vim.split(out.stdout or "", "\n", { trimempty = true }), out.code == 0)
        vim.schedule(function()
          cb(head)
        end)
      end
    )
  )
end

-- Re-resolve HEAD asynchronously and broadcast only on an actual change. fs
-- events arrive in bursts for a single checkout, so a per-root single-flight
-- `pending` guard collapses the burst to one in-flight resolve. The gate keys on
-- the resolved object id AND branch: a `git submodule update` moves the sha
-- while the (detached, nil) branch is unchanged, which a branch-only gate would
-- miss. The broadcast payload stays {root, branch}.
function M._check(root)
  local w = watched[root]
  if not w then
    return
  end
  if w.pending then
    -- A HEAD event landed while a resolve is in flight (e.g. a second checkout):
    -- the in-flight result may predate it, so remember to re-resolve once on
    -- completion rather than spawn a concurrent process now.
    w.recheck = true
    return
  end
  w.pending = true
  local started = M._resolve_head(root, function(head)
    -- Drop a stale result: the watcher may have been torn down (unwatch / fs
    -- error) or re-armed (a fresh handle replaced this one) while the resolve was
    -- in flight. Identity, not mere presence, so a re-armed slot is left alone.
    if watched[root] ~= w then
      return
    end
    w.pending = false
    if head and (head.sha ~= w.sha or head.branch ~= w.branch) then
      w.sha = head.sha
      w.branch = head.branch
      vim.api.nvim_exec_autocmds("User", {
        pattern = "HeadChanged",
        data = { root = root, branch = head.branch },
      })
    end
    -- Single-flight + recheck (not a queue): one re-run picks up whatever moved
    -- during the resolve and converges, comparing against the just-applied value.
    if w.recheck then
      w.recheck = false
      M._check(root)
    end
  end)
  -- A failed spawn must not strand the watcher with pending=true forever (the old
  -- sync check cleared pending up front); clear it so a later fs event retries.
  if not started then
    w.pending = false
  end
end

-- Stop + close `root`'s fs_event handle and drop its entry, unconditionally.
-- The close step shared by unwatch (after its buffer-scan) and the fs-error path
-- (which must reap a dead handle even if a buffer still resolves under root, so
-- watch() can re-arm it). Idempotent: a no-op once the entry is gone.
local function teardown(root)
  local w = watched[root]
  if not w then
    return
  end
  if not w.handle:is_closing() then
    w.handle:stop()
    w.handle:close()
  end
  watched[root] = nil
end

-- The fs_event callback for `root`. An error (e.g. `git submodule deinit` deletes
-- .git/modules/<name>) leaves the handle dead, so reap it UNCONDITIONALLY — NOT
-- via the scan-gated unwatch, which would keep a dead, believed-alive handle
-- whenever a buffer still resolves under root, blocking watch() from re-arming.
-- Otherwise debounce the burst (lockfile, rename, change) a single checkout
-- emits via the per-root `pending` flag and re-resolve once via check().
local function on_fs_event(root, err, filename)
  if err then
    vim.schedule(function()
      teardown(root)
    end)
    return
  end
  if filename and filename ~= "HEAD" then
    return
  end
  if not watched[root] then
    return
  end
  -- The single-flight / coalescing lives in M._check; just hand off to it.
  vim.schedule(function()
    M._check(root)
  end)
end

-- Test-only: drive the fs_event callback directly (real libuv errors are hard
-- to provoke deterministically).
function M._on_fs_event(root, err, filename)
  on_fs_event(root, err, filename)
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
  local w =
    { handle = handle, sha = seed.sha, branch = seed.branch, pending = false, recheck = false }
  local ok = handle:start(gitdir, {}, function(e, filename)
    on_fs_event(root, e, filename)
  end)
  if ok ~= 0 then
    handle:close()
    return false
  end
  watched[root] = w
  return true
end

-- True when any loaded buffer still resolves to `root`. An authoritative scan,
-- not a refcount: BufEnter/BufWipeout can arrive asymmetrically (a buffer wiped
-- without a matching enter, :bufdo, etc.), and a counter would drift; the live
-- buffer list cannot.
local function any_buffer_under(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and git.buf_in_root(buf, root) then
      return true
    end
  end
  return false
end

-- Release `root`'s watcher, but only once no loaded buffer resolves under it —
-- so the live fs_event set stays proportional to the submodules you actually
-- have open. The lifecycle autocmd below defers this past the wipe so the
-- departing buffer is already gone when the scan runs.
function M.unwatch(root)
  if not root or any_buffer_under(root) then
    return
  end
  teardown(root)
end

-- Test-only: the live fs_event handle for `root`, or nil when unwatched.
function M._handle(root)
  local w = watched[root]
  return w and w.handle or nil
end

-- Evict a root's handle when its last loaded buffer is wiped, so the live
-- fs_event set stays proportional to the submodules with an open buffer
-- (watched[] otherwise only grows over a session). Resolve the departing
-- buffer's root while it is still valid, then defer the scan past the wipe so
-- the buffer no longer counts itself. Cheap-guarded: skip entirely when nothing
-- is watched, and only schedule for a root that actually has a watcher. Unnamed
-- buffers (which can seed a cwd-root watcher) are skipped — that lone watcher is
-- kept alive by any named sibling and reclaimed by _stop_all on exit.
local lifecycle = vim.api.nvim_create_augroup("git_head_lifecycle", { clear = true })
vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
  group = lifecycle,
  callback = function(args)
    if not next(watched) then
      return
    end
    if not vim.api.nvim_buf_is_valid(args.buf) or vim.api.nvim_buf_get_name(args.buf) == "" then
      return
    end
    local root = git.buf_root(args.buf)
    if root and watched[root] then
      vim.schedule(function()
        M.unwatch(root)
      end)
    end
  end,
})

-- Close every watcher. Test isolation only.
function M._stop_all()
  for root in pairs(watched) do
    teardown(root)
  end
end

return M
