-- Where the Python type server is rooted: the workspace, not the member.
--
-- lspconfig roots basedpyright with an ordered root_markers list, and the
-- search stops at the first directory holding any marker it is looking for.
-- pyproject.toml outranks .git, so in a uv workspace — one uv.lock and one
-- `.venv` at the top, a pyproject.toml in every member — each member got a
-- server of its own. Each saw only its own files when asked for references or
-- implementations, and none of them looked where the workspace keeps its venv.
--
-- The rule, nearest-first within the repository (the `.git` that holds the
-- buffer, so a submodule is its own boundary):
--   1. a directory that configures the type checker: pyrightconfig.json, or a
--      pyproject.toml with [tool.pyright] / [tool.basedpyright]. In
--      language-server mode the server reads its config ONLY from the root it
--      was given, so rooting anywhere else silently drops that config.
--   2. a pyproject.toml with a lockfile beside it. A uv workspace keeps its
--      one uv.lock at the top and none in its members, while poetry and pdm
--      projects, and independent uv projects that happen to share a repo, each
--      carry their own — so the nearest lockfile is the project boundary in
--      both layouts. (Zed takes the OUTERMOST lockfile, which roots an
--      independent nested project at whatever happens to sit above it.)
--   3. the nearest pyproject.toml, which is what lspconfig did already.
-- Nothing found: lspconfig's own marker list, unchanged.
local M = {}

local LOCKFILES = { "uv.lock", "poetry.lock", "pdm.lock", "Pipfile.lock" }

-- lspconfig's lsp/basedpyright.lua root_markers, for the fallback. A copy
-- rather than a read of vim.lsp.config, because setting root_dir is what makes
-- core ignore root_markers in the first place.
M.FALLBACK_MARKERS = {
  "pyrightconfig.json",
  "pyproject.toml",
  "setup.py",
  "setup.cfg",
  "requirements.txt",
  "Pipfile",
  ".git",
}

---@param path string
---@return boolean
local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Does `dir`'s pyproject.toml carry a type-checker section? Anchored at the
--- line start, so a commented-out header does not count; the trailing class
--- accepts a subtable header ([tool.pyright.defineConstant]), which implies the
--- section just as much. Same matcher config.pyright_rules.shadowed uses.
---@param dir string
---@return boolean
function M.has_tool_section(dir)
  local f = io.open(vim.fs.joinpath(dir, "pyproject.toml"), "r")
  if not f then
    return false
  end
  local found = false
  for line in f:lines() do
    if line:match("^%[tool%.pyright[%]%.]") or line:match("^%[tool%.basedpyright[%]%.]") then
      found = true
      break
    end
  end
  f:close()
  return found
end

---@param dir string
---@return boolean
local function configures_checker(dir)
  return exists(vim.fs.joinpath(dir, "pyrightconfig.json")) or M.has_tool_section(dir)
end

---@param dir string
---@return boolean
local function locked_project(dir)
  if not exists(vim.fs.joinpath(dir, "pyproject.toml")) then
    return false
  end
  for _, lock in ipairs(LOCKFILES) do
    if exists(vim.fs.joinpath(dir, lock)) then
      return true
    end
  end
  return false
end

---@param dir string
---@return boolean
local function project(dir)
  return exists(vim.fs.joinpath(dir, "pyproject.toml"))
end

--- `start` and each of its parents, stopping after `top` (or at the
--- filesystem root when there is no top).
---@param start string
---@param top string|nil
---@return string[]
local function upward(start, top)
  local dirs, d = {}, start
  while true do
    dirs[#dirs + 1] = d
    if d == top then
      break
    end
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    d = parent
  end
  return dirs
end

--- The type server's root for a buffer in `start`, or nil when no rule
--- applies. Pure apart from the filesystem probes.
---@param start string directory to search from
---@param top string|nil repository root bounding the search
---@return string|nil
function M.find(start, top)
  local dirs = upward(start, top)
  for _, rule in ipairs({ configures_checker, locked_project, project }) do
    for _, d in ipairs(dirs) do
      if rule(d) then
        return d
      end
    end
  end
  return nil
end

--- The directory the search starts from: the buffer's own, falling back to the
--- cwd only for a genuinely unnamed buffer (config.lsp_root's buf_dir, same
--- reasoning).
---@param bufnr integer
---@return string
local function buf_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return vim.uv.cwd()
  end
  return vim.fs.dirname(name)
end

--- `root_dir` resolver for vim.lsp.config. Always calls back: no root at all
--- starts the server in single-file mode, exactly as an unmatched
--- root_markers list would.
---@param bufnr integer
---@param on_dir fun(dir: string|nil)
function M.root_dir(bufnr, on_dir)
  local start = buf_dir(bufnr)
  local top = vim.fs.root(start, { ".git" })
  on_dir(M.find(start, top) or vim.fs.root(start, M.FALLBACK_MARKERS))
end

return M
