-- Thin git-shellout layer. Single home for the synchronous `systemlist` +
-- `shell_error` guard + `-C <cwd>` plumbing that was hand-rolled (with subtly
-- inconsistent error handling) across telescope_smart, review_base and gitsigns.
-- (statusline is the deliberate exception: it needs an async vim.system spawn
-- that resolves toplevel + branch in one call off the main thread, which this
-- synchronous layer can't express, so it keeps its own shellout.)
--
-- Deliberately thin: it shells out and reports success/first-line. Higher-level
-- parsing (porcelain status, name-status diffs) stays in its owning module.
local M = {}

-- util.path is a git-free leaf (vim.fn only), so requiring it here can't cycle.
-- buf_root lives on this side of the boundary — it composes path + root, and
-- root resolution is git's concern — keeping path.lua a pure path module.
local path = require("util.path")

-- Run a git command. `opts.cwd`, when non-empty, inserts `-C <cwd>` right after
-- `git` so the command runs against that repo. Returns the output lines and a
-- boolean `ok` (true when git exited 0).
function M.run(args, opts)
  local cmd = { "git" }
  if opts and opts.cwd and opts.cwd ~= "" then
    cmd[#cmd + 1] = "-C"
    cmd[#cmd + 1] = opts.cwd
  end
  vim.list_extend(cmd, args)
  local lines = vim.fn.systemlist(cmd)
  return lines, vim.v.shell_error == 0
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
-- across submodules — to one per distinct directory. Only successful lookups are
-- cached (a non-repo dir is cheap to re-probe and could later become a repo).
local root_cache = {}

function M.root(start)
  local key = start or vim.fn.getcwd()
  local cached = root_cache[key]
  if cached then
    return cached
  end
  local r = M.first_line({ "rev-parse", "--show-toplevel" }, { cwd = start })
  if r then
    root_cache[key] = r
  end
  return r
end

-- Drop the memoized roots. For tests and for the rare case a directory's repo
-- membership changes mid-session (git init, submodule add/remove).
function M._clear_root_cache()
  root_cache = {}
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
-- Uses vim.system, not M.run: systemlist merges stderr, so the unborn-HEAD
-- "fatal: ambiguous argument 'HEAD'" would land in the output and corrupt the
-- positional parse. vim.system keeps stdout clean, so the parse is keyed purely
-- on the exit code (0 -> [sha, token]; nonzero/unborn -> [token]). :wait() makes
-- it synchronous, same blocking shape as M.run on this off-hot-path call.
function M.head(root)
  local res = vim
    .system({ "git", "-C", root, "rev-parse", "HEAD", "--abbrev-ref", "HEAD" }, { text = true })
    :wait()
  local lines = vim.split(res.stdout or "", "\n", { trimempty = true })
  local sha, token
  if res.code == 0 then
    sha, token = lines[1], lines[2]
  else
    token = lines[1] -- unborn: only the abbrev-ref "HEAD" reaches stdout
  end
  local branch = (token and token ~= "HEAD") and token or nil
  return { sha = sha, branch = branch }
end

-- Absolute path of the git directory for `root`, or nil outside a repo.
-- Worktrees and submodules resolve to their own gitdir — the one whose HEAD
-- file moves on checkout — not the shared parent .git.
function M.git_dir(root)
  return M.first_line({ "rev-parse", "--absolute-git-dir" }, { cwd = root })
end

-- True when `ref` resolves to an object in `root`.
function M.resolve(root, ref)
  if not root or not ref or ref == "" then
    return false
  end
  local _, ok = M.run({ "rev-parse", "--verify", "--quiet", ref }, { cwd = root })
  return ok
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
