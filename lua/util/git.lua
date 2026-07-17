-- Thin git-shellout layer. Single home for the synchronous, time-bounded
-- `vim.system():wait()` + exit-code guard + `-C <cwd>` plumbing that was
-- hand-rolled (with subtly inconsistent error handling) across telescope_smart,
-- review_base and gitsigns. (statusline keeps its own async spawn: it resolves
-- toplevel + sha + branch off the main thread, which this synchronous layer
-- can't express. config.git_head._resolve_head is the other async exception.)
--
-- vim.system (not systemlist) for two reasons: it separates stdout from stderr,
-- so a git diagnostic ("fatal: not a git repository") never pollutes the parsed
-- lines; and :wait(TIMEOUT_MS) bounds the call, so a hung or network submodule
-- gitdir degrades to ok=false instead of freezing Neovim. A timed-out call is
-- treated as a plain failure — and M.root never memoizes a timeout (only
-- definitive answers), so it is not poisoned and stays cheap to re-probe. The
-- synchronous bulk status/diff path
-- (M._git_changes) is test-only; production resolves the porcelain/diff through
-- config.telescope_smart's own async vim.system, unaffected by this bound.
--
-- Deliberately thin: it shells out and reports success/first-line. Higher-level
-- parsing (porcelain status, name-status diffs) stays in its owning module.
local M = {}

-- util.path is a git-free leaf (vim.fn only), so requiring it here can't cycle.
-- buf_root lives on this side of the boundary — it composes path + root, and
-- root resolution is git's concern — keeping path.lua a pure path module.
local path = require("util.path")

-- The one home for "how long a synchronous git call may block". Every M.run
-- caller is a cheap resolve (rev-parse / branch / verify), so a single flat
-- bound is enough; raise it here, not at call sites.
local TIMEOUT_MS = 2000

-- Run a git command. `opts.cwd`, when non-empty, inserts `-C <cwd>` right after
-- `git` so the command runs against that repo. Returns the output lines (stdout
-- only), a boolean `ok` (true when git exited 0), and `timed_out` (true when
-- the call hit TIMEOUT_MS — so callers can tell a transient hang from git
-- definitively saying no; see review_base's prune-vs-retry decision).
function M.run(args, opts)
  local cmd = { "git" }
  if opts and opts.cwd and opts.cwd ~= "" then
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = opts.cwd
  end
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait(TIMEOUT_MS)
  if not res then
    -- wait(timeout) normally returns a completed result (code=124, signal=9)
    -- after SIGKILLing a timed-out process; nil only when the process survives
    -- even the SIGKILL within the wait window (e.g. uninterruptible sleep on a
    -- hung network gitdir). Either way it timed out.
    return {}, false, true
  end
  local timed_out = res.code == 124 and res.signal == 9
  return vim.split(res.stdout or "", "\n", { trimempty = true }), res.code == 0, timed_out
end

-- Run a command and return its first output line, or nil when the command
-- failed or produced no (non-empty) output.
function M.first_line(args, opts)
  local lines, ok = M.run(args, opts)
  if not ok or not lines[1] or lines[1] == "" then
    return nil
  end
  return lines[1]
end

-- Repo toplevel containing `start` (or the cwd when `start` is nil), or nil
-- outside a work tree.
--
-- Memoized by directory: a directory's git toplevel is invariant for a session,
-- and this is on hot paths that re-resolve the same dirs constantly (gitsigns
-- attach + new-vs-base per buffer, the smart picker, the tree decorator). In a
-- superproject that collapses N blocking `rev-parse` spawns — one per buffer
-- across submodules — to one per distinct directory. Definitive misses are
-- memoized too (as false): buffer churn (pickers, previews, help buffers)
-- re-resolves the same non-repo dirs constantly, and each miss would otherwise
-- be a fresh blocking spawn. Only a timeout is left uncached — a transient hang
-- must stay re-probeable. A dir that later becomes a repo (git init, submodule
-- add) is rediscovered through the same invalidation that already covers stale
-- positives: config.dir_cache clears the whole memo via _clear_root_cache.
local root_cache = {}

function M.root(start)
  local key = start or vim.fn.getcwd()
  local cached = root_cache[key]
  if cached ~= nil then
    return cached or nil
  end
  local lines, ok, timed_out = M.run({ "rev-parse", "--show-toplevel" }, { cwd = start })
  local r = (ok and lines[1] and lines[1] ~= "") and lines[1] or nil
  if r then
    root_cache[key] = r
  elseif not timed_out then
    root_cache[key] = false
  end
  return r
end

-- Drop the memoized roots. For tests and for the rare case a directory's repo
-- membership changes mid-session (git init, submodule add/remove).
function M._clear_root_cache()
  root_cache = {}
end

-- Read-only peek at the root memo, for callers that must never block the main
-- loop (config.ignore_filter resolves cache misses through its own async
-- rev-parse instead of M.root's synchronous wait). Returns the raw entry:
-- false is a memoized "not a repo", nil means unresolved.
function M._cached_root(dir)
  return root_cache[dir]
end

-- Prime the root memo with an externally-resolved toplevel, so an async
-- resolve warms the same cache the synchronous callers read.
function M._prime_root(dir, top)
  root_cache[dir] = top
end

-- Repo toplevel for buffer `buf`, resolved from its start dir (its file's
-- directory, or the cwd when unnamed) — the per-buffer analog of M.root that the
-- statusline and gitsigns both compute inline. In a superproject this returns
-- the submodule the buffer actually lives in, so consumers (diffview, the
-- review-base pickers) act on that submodule rather than whatever cwd resolves
-- to. nil when the buffer is outside any work tree.
function M.buf_root(buf)
  return M.root(path.buf_start_dir(buf))
end

-- True when buffer `buf` lives in the work tree whose toplevel is `root`. Used
-- to scope event fan-out (HeadChanged / ReviewBaseChanged carry data.root) to
-- the buffers a change can actually affect. EXACT toplevel equality, never a
-- path prefix: a submodule's working copy sits on disk under the superproject,
-- so a prefix test would wrongly match a child buffer against the parent's root.
function M.buf_in_root(buf, root)
  return M.buf_root(buf) == root
end

-- Current branch name for `root`, or nil on detached HEAD / outside a repo.
function M.branch(root)
  return M.first_line({ "branch", "--show-current" }, { cwd = root })
end

-- Resolve HEAD for `root` to its object id and branch name in ONE git process:
--   normal   -> { sha = <id>, branch = "main" }
--   detached -> { sha = <id>, branch = nil }   (--abbrev-ref prints "HEAD")
--   unborn   -> { sha = nil,  branch = nil }    (rev-parse HEAD fails)
-- The HEAD watcher gates on BOTH fields: a `git submodule update` moves the sha
-- while the (nil) branch is unchanged, which a branch-name-only gate misses.
--
-- Turn one `rev-parse HEAD --abbrev-ref HEAD` result into { sha, branch }. The
-- parse keys on the exit code (via `ok`): on success the lines are [sha, token];
-- an unborn HEAD exits nonzero with only the abbrev-ref "HEAD" on stdout (the
-- "fatal: ambiguous argument" diagnostic stays on stderr, which run() drops). A
-- "HEAD" token means detached or unborn → nil branch. Pure, so the sync M.head
-- and the async HEAD watcher (config.git_head._resolve_head) share one parse.
function M.parse_head(lines, ok)
  local sha, token
  if ok then
    sha, token = lines[1], lines[2]
  else
    token = lines[1]
  end
  local branch = (token and token ~= "HEAD") and token or nil
  return { sha = sha, branch = branch }
end

-- The argv shared by the sync resolve (here, via run()) and the async one
-- (config.git_head._resolve_head, which prepends `git -C <root>` itself).
M.HEAD_ARGS = { "rev-parse", "HEAD", "--abbrev-ref", "HEAD" }

function M.head(root)
  return M.parse_head(M.run(M.HEAD_ARGS, { cwd = root }))
end

-- Absolute path of the git directory for `root`, or nil outside a repo.
-- Worktrees and submodules resolve to their own gitdir — the one whose HEAD
-- file moves on checkout — not the shared parent .git.
function M.git_dir(root)
  return M.first_line({ "rev-parse", "--absolute-git-dir" }, { cwd = root })
end

-- Spawn-free change key for a repo dir: the mtime of its git index. The index
-- is rewritten by stage / commit / checkout / reset / submodule-update
-- (verified empirically), so a changed key means "something git-visible
-- happened" — enough to gate an expensive `git status` re-resolve on FocusGained
-- without paying a per-dir spawn (config.repo_status, config.submodule_status).
-- Two things it deliberately does NOT catch: a bare worktree edit (an untracked
-- or unstaged change never touches the index — the documented staleness window,
-- escape-hatched by <leader>gR and the in-session filesystem watcher) and, on
-- its own, a HEAD move (config.git_head's HeadChanged already covers that). The
-- index lives at <gitdir>/index; a submodule/worktree has a `.git` FILE that
-- points its gitdir elsewhere (gitdir: ../.git/modules/<name>), so resolve that
-- with pure fs before stat-ing. The resolved index path is invariant for a
-- session, so memoize it (only positive resolutions — a missing .git stays cheap
-- to re-probe). nil when the dir is not a repo or has no index yet (unborn).
local index_path_cache = {}

local function resolve_index_path(dir)
  local cached = index_path_cache[dir]
  if cached then
    return cached
  end
  local dotgit = dir .. "/.git"
  local st = vim.uv.fs_stat(dotgit)
  local gitdir
  if st and st.type == "directory" then
    gitdir = dotgit
  elseif st and st.type == "file" then
    local f = io.open(dotgit, "r")
    if f then
      local line = f:read("*l") or ""
      f:close()
      local ref = line:match("^gitdir:%s*(.+)$")
      if ref then
        gitdir = ref:match("^/") and ref or vim.fn.simplify(dir .. "/" .. ref)
      end
    end
  end
  local idx = gitdir and (gitdir .. "/index") or nil
  if idx then
    index_path_cache[dir] = idx
  end
  return idx
end

function M.index_key(dir)
  local idx = dir and resolve_index_path(dir)
  if not idx then
    return nil
  end
  local st = vim.uv.fs_stat(idx)
  if not st or not st.mtime then
    return nil
  end
  return st.mtime.sec .. "." .. st.mtime.nsec
end

-- Drop the memoized index paths (test seam; and the rare mid-session .git
-- relocation, alongside _clear_root_cache).
function M._clear_index_cache()
  index_path_cache = {}
end

-- True when `ref` resolves to an object in `root`. The second return marks a
-- timed-out (not definitively failed) check, so callers can retry later
-- instead of treating a transient hang as "ref is gone".
function M.resolve(root, ref)
  if not root or not ref or ref == "" then
    return false
  end
  local _, ok, timed_out = M.run({ "rev-parse", "--verify", "--quiet", ref }, { cwd = root })
  return ok, timed_out
end

-- True when `relpath` exists in `ref` (e.g. the file was committed in that ref).
function M.file_in_ref(root, ref, relpath)
  if not root or not ref or not relpath or relpath == "" then
    return false
  end
  local _, ok = M.run({ "cat-file", "-e", ref .. ":" .. relpath }, { cwd = root })
  return ok
end

return M
