-- Hides git-ignored files in nvim-tree WITHOUT nvim-tree's builtin git
-- integration. In a superproject with many submodules that builtin path spawns
-- one *synchronous* `git status --ignored` per submodule and counts timeouts in
-- a module-level, never-reset counter that PERMANENTLY disables git (and with it
-- filters.git_ignored) after 5 of them — so node_modules/target silently
-- reappear "after a while". See lua/plugins/nvim-tree.lua for why git.enable is
-- off. This module is the replacement.
--
-- Two cooperating layers feed ONE fork-free predicate. nvim-tree calls
-- filters.custom synchronously per directory entry during the scandir build
-- (Filters:custom in nvim-tree/explorer/filters.lua), so the predicate must
-- never block — it is only table lookups:
--
--   STATIC — a curated basename set of heavy dirs that are heavy AND
--            essentially never tracked (node_modules, .venv, __pycache__, ...).
--            Hidden instantly, before any git runs, so they never flash and
--            their (huge) contents are never scandir'd. Faithful by
--            construction: a non-anchored bare directory name matches at any
--            depth in git, exactly like a basename set, and these names are
--            never legitimately tracked source. Ambiguous names that ecosystems
--            sometimes TRACK (target, build, dist, bin, vendor, .idea, Pods)
--            are deliberately absent — the oracle answers those with git's real,
--            index-aware verdict, so a tracked dir of that name stays visible.
--
--   ORACLE — `git -C <toplevel> check-ignore -z --stdin`, run lazily and
--            ASYNCHRONOUSLY (vim.system), one bounded process per enclosing
--            toplevel, for everything the static tier doesn't answer. True
--            gitignore fidelity (nested .gitignore, negation, core.excludesFile,
--            .git/info/exclude) and index-aware. A miss returns "show"
--            (fail-open) and enqueues the path; when the batch resolves, the
--            tree reloads ONCE so newly-known ignores disappear (a one
--            round-trip ~10ms flash of the ignored directory row, never its
--            contents). Results memoize in `_ignored`, so steady state is O(1).
--
-- Invalidation is event-driven, not a .git watcher: .gitignore / exclude writes
-- clear the cache here (M.setup); submodule-topology changes clear it through
-- config.dir_cache; <leader>gR is the manual hatch. Index-only changes
-- (`git add -f node_modules/x`, `git rm --cached`) are a deliberate non-goal of
-- the auto-events — refresh with <leader>gR.
local M = {}

local git = require("util.git")
local pool = require("util.pool")

-- Curated never-tracked heavy dirs (see header). A basename hit is a match at
-- any depth, which mirrors a non-anchored gitignore pattern exactly.
local STATIC = {}
for _, n in ipairs({
  "node_modules",
  ".venv",
  "venv",
  "__pycache__",
  ".mypy_cache",
  ".pytest_cache",
  ".ruff_cache",
  ".next",
  ".nuxt",
  ".turbo",
  ".svelte-kit",
  ".angular",
  ".vite",
  ".gradle",
  ".terraform",
  ".dart_tool",
  ".parcel-cache",
  ".nyc_output",
  "DerivedData",
  "elm-stuff",
}) do
  STATIC[n] = true
end

-- _ignored: abs -> true (HIDE) | false (git CONFIRMED not-ignored: render, never
--           re-ask). nil means unknown -> enqueue + fail-open.
-- seen:     abs currently enqueued (cleared as each resolves) so one build pass
--           can't push the same path twice.
local _ignored, seen, pending = {}, {}, {}
local drain_scheduled = false
local CHECK_TIMEOUT_MS = 2000

-- Pure: does the basename land in the static heavy-dir set?
function M._is_static(abs)
  local base = abs:match("[^/]+$")
  return base ~= nil and STATIC[base] == true
end

-- Pure: group absolute paths by the toplevel of their CONTAINING directory
-- (resolved via root_fn — injectable for tests). check-ignore is fatal across a
-- submodule boundary, so each path must be fed to the repo that actually owns
-- it; keying on the path's own enclosing toplevel handles arbitrary submodule
-- nesting. Returns (by_top, unrooted) — unrooted paths sit outside any work tree.
function M._partition(paths, root_fn)
  local by_top, unrooted = {}, {}
  for _, abs in ipairs(paths) do
    local top = root_fn(vim.fs.dirname(abs))
    if top then
      local t = by_top[top]
      if not t then
        t = {}
        by_top[top] = t
      end
      t[#t + 1] = abs
    else
      unrooted[#unrooted + 1] = abs
    end
  end
  return by_top, unrooted
end

-- Pure: the NUL-separated paths `git check-ignore -z` echoes back are exactly
-- the ignored subset of its input, in input form (we feed absolute paths).
function M._parse_check_ignore(stdout)
  local hit = {}
  for _, p in ipairs(vim.split(stdout or "", "\0", { trimempty = true })) do
    hit[p] = true
  end
  return hit
end

-- Resolve every pending path off the main thread, then reload once iff a render
-- actually changed. Termination: every fed path ends up non-nil in `_ignored`
-- (true -> pruned, its contents never scandir'd, never re-enqueued; false ->
-- rendered, short-circuits on next pass), so no new miss -> no new drain -> no
-- reload loop.
--
-- Both async stages guard on the cache's table identity: M._clear() mints
-- fresh tables, so `_ignored ~= cache` detects a mid-flight invalidation (a
-- .gitignore write, a submodule-topology change) and drops the batch's stale
-- verdicts instead of repopulating the just-cleared cache with answers
-- computed against the old rules. The dropped paths simply re-enqueue on the
-- next render — the same fail-open flash the first pass already exhibits.
local function drain()
  if #pending == 0 then
    return
  end
  local batch = pending
  pending = {}
  local cache = _ignored

  -- Stage 1: resolve the batch's enclosing toplevels off the main thread.
  -- git.root's synchronous wait() is fine per buffer event, but one drain can
  -- carry paths under dozens of distinct uncached directories (expand_all over
  -- a many-submodule tree), and a burst of sequential blocking rev-parse
  -- spawns on the main loop would contradict this module's own never-block
  -- discipline. So cache misses resolve through the same bounded async pool,
  -- priming util.git's memo so every other caller stays warm.
  local dirs, dir_seen = {}, {}
  for _, abs in ipairs(batch) do
    local dir = vim.fs.dirname(abs)
    if not dir_seen[dir] and git._cached_root(dir) == nil then
      dir_seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end

  -- dir -> toplevel, or false when the dir sits outside any work tree. Kept
  -- separate from util.git's memo, which caches only successes (a non-repo dir
  -- must stay cheap to re-probe later without a synchronous fallback here).
  local roots = {}
  pool.run(dirs, pool.GIT_CONCURRENCY, function(dir, done)
    vim.system(
      { "git", "-C", dir, "rev-parse", "--show-toplevel" },
      { text = true, timeout = CHECK_TIMEOUT_MS },
      function(res)
        vim.schedule(function()
          local top = res.code == 0 and vim.split(res.stdout or "", "\n", { trimempty = true })[1]
          if top and top ~= "" then
            roots[dir] = top
            -- Prime util.git's memo only while this batch's cache is still
            -- live: dir_cache.clear() drops the root cache and this cache in
            -- the same synchronous tick, so identity proves no clear landed
            -- mid-resolve — an unguarded prime could re-insert a
            -- pre-topology-change toplevel that M.root would then serve
            -- stale for the rest of the session.
            if _ignored == cache then
              git._prime_root(dir, top)
            end
          else
            roots[dir] = false
          end
          done()
        end)
      end
    )
  end, function()
    if _ignored ~= cache then
      return
    end

    local by_top, unrooted = M._partition(batch, function(dir)
      return git._cached_root(dir) or roots[dir] or nil
    end)
    for _, abs in ipairs(unrooted) do
      _ignored[abs] = false
      seen[abs] = nil
    end

    local tops = vim.tbl_keys(by_top)
    if #tops == 0 then
      return
    end

    -- Stage 2: one bounded check-ignore per toplevel.
    local found_new = false
    pool.run(tops, pool.GIT_CONCURRENCY, function(top, done)
      local paths = by_top[top]
      vim.system(
        -- --no-optional-locks: check-ignore reads the index (tracked files are
        -- never ignored), and git would opportunistically grab .git/index.lock to
        -- refresh the index stat cache. config.telescope_smart's decorator runs
        -- `git status`/`git diff` in this same repo concurrently; two git
        -- processes colliding on that lock make one exit nonzero and drop its
        -- output (the labels), so suppress the optional lock here. (telescope_smart
        -- serializes its own status+diff for the same reason.)
        { "git", "--no-optional-locks", "-C", top, "check-ignore", "-z", "--stdin" },
        { stdin = table.concat(paths, "\0") .. "\0", timeout = CHECK_TIMEOUT_MS },
        function(res)
          vim.schedule(function()
            -- A cleared cache mid-batch: drop the stale verdicts but still call
            -- done() so the pool drains and its on_complete runs.
            if _ignored ~= cache then
              return done()
            end
            -- rc 0 = some ignored, rc 1 = none ignored (both authoritative);
            -- rc 128 = error -> empty hit -> those paths fail open (shown), still
            -- recorded so the batch terminates.
            local hit = (res.code == 0 or res.code == 1) and M._parse_check_ignore(res.stdout) or {}
            for _, p in ipairs(paths) do
              local ig = hit[p] == true
              if ig and _ignored[p] ~= true then
                found_new = true
              end
              _ignored[p] = ig
              seen[p] = nil
            end
            done()
          end)
        end
      )
    end, function()
      if found_new then
        local ok, api = pcall(require, "nvim-tree.api")
        if ok and api.tree.is_visible() then
          api.tree.reload()
        end
      end
    end)
  end)
end

-- THE FILTER. Synchronous, O(1), never forks. Returns true to HIDE.
function M.is_ignored(abs)
  if M._is_static(abs) then
    return true
  end
  local v = _ignored[abs]
  if v ~= nil then
    return v
  end
  if not seen[abs] then
    seen[abs] = true
    pending[#pending + 1] = abs
    if not drain_scheduled then
      drain_scheduled = true
      vim.schedule(function()
        drain_scheduled = false
        drain()
      end)
    end
  end
  return false -- fail-open: show until the oracle answers
end

-- Drop the oracle cache. Chained from config.dir_cache (submodule topology /
-- DirChanged / <leader>gR) and from the .gitignore watcher in M.setup.
function M._clear()
  _ignored, seen, pending = {}, {}, {}
end

function M.setup()
  local g = vim.api.nvim_create_augroup("ignore_filter", { clear = true })
  -- Basename patterns (no slash): '.gitignore' anywhere in the tree, and
  -- 'exclude' covers .git/info/exclude. Editing either changes ignore answers.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = g,
    pattern = { ".gitignore", "exclude" },
    callback = function()
      M._clear()
      local ok, api = pcall(require, "nvim-tree.api")
      if ok and api.tree.is_visible() then
        api.tree.reload()
      end
    end,
  })
end

return M
