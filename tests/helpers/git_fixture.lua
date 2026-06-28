local M = {}

local FIXED_DATE = "2026-04-26T12:00:00Z"

local function run(cwd, ...)
  local args = vim.list_extend({ "git", "-C", cwd }, { ... })
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    error(
      "git failed in "
        .. cwd
        .. ": "
        .. table.concat({ ... }, " ")
        .. "\n"
        .. table.concat(out, "\n")
    )
  end
  return out
end

local function commit(cwd, message)
  vim.fn.setenv("GIT_AUTHOR_DATE", FIXED_DATE)
  vim.fn.setenv("GIT_COMMITTER_DATE", FIXED_DATE)
  vim.fn.setenv("GIT_AUTHOR_NAME", "Test User")
  vim.fn.setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
  vim.fn.setenv("GIT_COMMITTER_NAME", "Test User")
  vim.fn.setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
  run(cwd, "add", "-A")
  run(cwd, "commit", "-m", message, "--no-gpg-sign", "--allow-empty")
end

local function write_file(cwd, path, content)
  local full = cwd .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "w"))
  f:write(content)
  f:close()
end

-- Recipe:
-- {
--   commits = { { files = { ["a.lua"] = "..." }, message = "init" }, ... },
--   staged = { ["x.lua"] = "..." },
--   modified = { ["y.lua"] = "..." },   -- modify already-committed file
--   untracked = { ["z.lua"] = "..." },
--   base_branch = "main",
-- }
function M.repo(opts)
  opts = opts or {}
  local root = vim.fn.tempname() .. "-fixture-repo"
  vim.fn.mkdir(root, "p")
  run(root, "init", "-q", "--initial-branch=" .. (opts.base_branch or "main"))
  run(root, "config", "user.email", "test@example.invalid")
  run(root, "config", "user.name", "Test User")
  run(root, "config", "commit.gpgsign", "false")

  for _, c in ipairs(opts.commits or {}) do
    for path, content in pairs(c.files or {}) do
      write_file(root, path, content)
    end
    commit(root, c.message or "commit")
  end

  for path, content in pairs(opts.staged or {}) do
    write_file(root, path, content)
    run(root, "add", path)
  end

  for path, content in pairs(opts.modified or {}) do
    write_file(root, path, content)
  end

  for path, content in pairs(opts.untracked or {}) do
    write_file(root, path, content)
  end

  return root
end

function M.with_remote(repo, name)
  name = name or "origin"
  local clone = vim.fn.tempname() .. "-fixture-remote"
  run(repo, "clone", "--bare", "--quiet", repo, clone)
  run(repo, "remote", "add", name, clone)
  run(repo, "fetch", "-q", name)
  return clone
end

-- Bare-bones git config (identity + no gpg) so commits succeed in a clean env.
local function init_repo(dir, branch)
  vim.fn.mkdir(dir, "p")
  run(dir, "init", "-q", "--initial-branch=" .. (branch or "main"))
  run(dir, "config", "user.email", "test@example.invalid")
  run(dir, "config", "user.name", "Test User")
  run(dir, "config", "commit.gpgsign", "false")
end

-- A standalone single-commit repo, used as a submodule source. Each carries a
-- `<name>.txt` so a file path inside the eventual submodule is resolvable.
local function standalone(name)
  local dir = vim.fn.tempname() .. "-" .. name
  init_repo(dir)
  write_file(dir, name .. ".txt", "-- " .. name .. "\n")
  commit(dir, "init " .. name)
  return dir
end

-- Add `src` as a submodule named `name` under `parent`. Local-path submodules
-- need protocol.file.allow=always since the CVE-2022-39253 fix disabled the
-- file transport by default. The `-c` must precede the `submodule` subcommand.
local function add_submodule(parent, src, name)
  run(parent, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", src, name)
end

-- Build a superproject: a parent repo with N child submodules, optionally a
-- nested grandchild submodule, a linked worktree of a child, and a standalone
-- unborn-HEAD repo. Returns:
--   {
--     root = <parent toplevel>,
--     children = { <name> = <parent>/<name>, ... },
--     grandchild = <child>/<gname>,   -- when opts.grandchild
--     worktree = <path>,              -- when opts.worktree (basename = opts.worktree.name)
--     unborn = <path>,                -- when opts.unborn (git init, no commit)
--   }
-- opts:
--   children   = { "childA", "childB" }
--   grandchild = { parent = "childA", name = "grand" }
--   worktree   = { child = "childA", name = "wt" }
--   unborn     = true
function M.superproject(opts)
  opts = opts or {}
  local parent = vim.fn.tempname() .. "-superproject"
  init_repo(parent)
  write_file(parent, "README.md", "# superproject\n")
  commit(parent, "init parent")

  local result = { root = parent, children = {} }

  local children = opts.children or {}
  for _, name in ipairs(children) do
    add_submodule(parent, standalone(name), name)
    result.children[name] = parent .. "/" .. name
  end
  if #children > 0 then
    commit(parent, "add submodules")
  end

  if opts.grandchild then
    local pchild = assert(result.children[opts.grandchild.parent], "grandchild parent not a child")
    add_submodule(pchild, standalone(opts.grandchild.name), opts.grandchild.name)
    commit(pchild, "add grandchild")
    -- Record the child's bumped gitlink in the superproject too.
    run(parent, "add", opts.grandchild.parent)
    commit(parent, "bump " .. opts.grandchild.parent)
    result.grandchild = pchild .. "/" .. opts.grandchild.name
  end

  if opts.worktree then
    local wchild = assert(result.children[opts.worktree.child], "worktree child not a child")
    -- Put the worktree at <tmp>/<name> so its gitdir lands at
    -- .git/modules/<child>/worktrees/<name> (worktree entry = path basename).
    local wtbase = vim.fn.tempname() .. "-wt"
    vim.fn.mkdir(wtbase, "p")
    local wt = wtbase .. "/" .. opts.worktree.name
    run(wchild, "worktree", "add", "-q", wt)
    result.worktree = wt
  end

  if opts.unborn then
    local u = vim.fn.tempname() .. "-unborn"
    init_repo(u)
    result.unborn = u
  end

  return result
end

return M
