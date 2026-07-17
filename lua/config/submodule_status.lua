-- Per-submodule worktree status, cached by a cheap git-state key so the
-- whole-superproject scan runs cold ONCE and thereafter re-scans only the
-- submodules that actually changed. This is the shared "cache" behind two
-- consumers with different triggers:
--
--   * config.telescope_smart's recursive_changes_async (the pickers) drives the
--     bulk scan() over every submodule to build whole-tree file codes.
--   * config.nvim_tree_git (the tree) drives request() on-demand for a single
--     submodule (an expanded row, or a dirty-rollup probe) and reads dirty()/get().
--
-- Both share one cache and one single-flight guard, so a submodule scanned for
-- the picker is free for the tree and vice versa. Each entry is keyed by
-- util.git.index_key at resolve time; revalidate() drops only entries whose
-- index moved (stage/commit/checkout), so a FocusGained over a 200-submodule
-- superproject with nothing changed re-scans NOTHING — the recurring cost that
-- the old always-recurse recursive_changes_async paid on every focus.
--
-- nvim-tree-free: request() fires `User SubmoduleStatusChanged { dir }` when a
-- resolve lands (the tree subscribes and reloads); the bulk scan() is silent and
-- reports through its on_complete callback.
local M = {}

local git = require("util.git")
local pool = require("util.pool")

-- Matches the per-submodule status telescope_smart used to run inline:
-- --untracked-files=all lists each new file (not a collapsed dir row), and
-- --ignore-submodules=all keeps a submodule's own scan from descending into (and
-- racing on the index.lock of) a nested child — each nested repo scans on its own.
local STATUS_ARGS = { "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all" }

-- One bound for how long a single per-submodule status may run; a hung/slow one
-- is killed and contributes nothing (empty), so the pool always drains.
local GIT_TIMEOUT_MS = 2000

-- abs submodule dir -> { lines = <porcelain lines>, state = index_key }. Never a
-- pending marker; get() must stay clean.
local cache = {}
-- abs dir -> { cbs = { fn, ... }, notify = bool }. Single-flight across request()
-- and scan(): concurrent asks for the same submodule attach to one spawn.
local pendings = {}

-- The real spawn. Assigned to M._resolve (a swappable seam so tests drive
-- completion by hand). One `git status --porcelain`; parsing is vim.schedule'd
-- onto the main loop (vim.system's on_exit runs in a fast context). cb(lines) on
-- success, cb(nil) on any failure/timeout.
local function default_resolve(dir, cb)
  local ok = pcall(
    vim.system,
    vim.list_extend({ "git", "-C", dir }, STATUS_ARGS),
    { text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      local lines = res.code == 0 and vim.split(res.stdout or "", "\n", { trimempty = true }) or nil
      vim.schedule(function()
        cb(lines)
      end)
    end
  )
  if not ok then
    vim.schedule(function()
      cb(nil)
    end)
  end
end
M._resolve = default_resolve

-- Core single-flight resolve shared by request() and scan(). `cb(lines)` always
-- runs (lines = {} on failure). `notify` (from request) makes the landing fire
-- SubmoduleStatusChanged once; scan passes it false so a 200-submodule bulk scan
-- never storms the tree with reloads. A cache hit returns synchronously.
local function resolve_one(dir, cb, notify)
  local entry = cache[dir]
  if entry then
    return cb(entry.lines)
  end
  local p = pendings[dir]
  if p then
    p.cbs[#p.cbs + 1] = cb
    if notify then
      p.notify = true
    end
    return
  end
  p = { cbs = { cb }, notify = notify or false }
  pendings[dir] = p
  M._resolve(dir, function(lines)
    pendings[dir] = nil
    if lines then
      -- Capture the cheap index key so revalidate() can later tell "unchanged"
      -- (keep) from "restaged/committed/checked out" (drop) without a spawn.
      cache[dir] = { lines = lines, state = git.index_key(dir) }
    end
    for _, fn in ipairs(p.cbs) do
      fn(lines or {})
    end
    if p.notify then
      vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "SubmoduleStatusChanged", data = { dir = dir } }
      )
    end
  end)
end

-- Cached porcelain lines for `dir`, or nil when unresolved/failed. Never spawns.
function M.get(dir)
  local e = cache[dir]
  return e and e.lines or nil
end

-- Tri-state worktree dirtiness for a rollup: true (resolved, has changes), false
-- (resolved, clean), nil (not yet resolved — caller should request()).
function M.dirty(dir)
  local e = cache[dir]
  if not e then
    return nil
  end
  return #e.lines > 0
end

-- Ensure `dir` is scanned (single-flight) and fire SubmoduleStatusChanged when it
-- lands so the tree repaints. No-op when already cached — revalidate() drops
-- stale entries, so a present entry is fresh. The tree's on-demand lever for an
-- expanded submodule row / a dirty-rollup probe.
function M.request(dir)
  if cache[dir] then
    return
  end
  resolve_one(dir, function() end, true)
end

-- Bulk scan `items` ({ key = <caller label>, dir = <abs submodule dir> }) through
-- the shared cache + single-flight, bounded by pool.GIT_CONCURRENCY. Silent (no
-- per-item events); calls on_complete({ [key] = lines }) after the last one. The
-- pickers' whole-tree driver — a cached-fresh submodule costs zero spawns.
function M.scan(items, on_complete)
  local results = {}
  pool.run(items, pool.GIT_CONCURRENCY, function(item, done)
    resolve_one(item.dir, function(lines)
      results[item.key] = lines
      done()
    end)
  end, function()
    on_complete(results)
  end)
end

-- The cheap FocusGained lever: drop only entries whose git index moved since they
-- were scanned, keeping the rest. Mirrors config.repo_status.revalidate.
function M.revalidate()
  for dir, entry in pairs(cache) do
    if git.index_key(dir) ~= entry.state then
      cache[dir] = nil
    end
  end
end

-- Targeted drop for one submodule — the precise, in-session lever for the
-- filesystem watcher (a bare worktree edit the index key can't see).
function M.invalidate(dir)
  cache[dir] = nil
end

-- Hard flush (the <leader>gR hatch).
function M.invalidate_all()
  cache = {}
end

-- Test seam: clear all state and restore the real resolver.
function M._reset()
  cache, pendings = {}, {}
  M._resolve = default_resolve
end

-- Test seam: pin a cached entry's state key (a fake dir has no real index to
-- stat), so revalidate()'s comparison can be driven deterministically.
function M._set_state(dir, state)
  if cache[dir] then
    cache[dir].state = state
  end
end

return M
