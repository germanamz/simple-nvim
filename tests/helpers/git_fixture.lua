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

return M
