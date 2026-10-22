-- Which Python interpreter a project runs.
--
-- Two consumers need the same answer and must not drift apart:
--   * config.python_lsp hands it to basedpyright as `python.pythonPath`. Without
--     it the server takes whatever `python` Neovim inherited from the shell
--     that launched it, so third-party imports resolve to bundled stubs or to
--     nothing, and the same `gd` lands somewhere different depending on how
--     Neovim was started.
--   * config.docs.adapters.python runs pydoc with it, which only works against
--     the interpreter that has the project's packages installed.
--
-- The docs adapter asks about one directory (its root, no `top`), exactly as
-- it always has. The type server asks with `top` set to the repository root,
-- because a uv workspace keeps ONE `.venv` at the workspace top while each
-- member has its own pyproject.toml below it: a lookup that stops at the
-- member finds nothing.
--
-- Everything here is a filesystem probe. No process is spawned: this runs from
-- an LSP before_init and from a keypress.
local M = {}

local state = require("util.state")

--- Is `path` `dir` itself or somewhere below it? Realpath'd on both sides when
--- the path exists, and compared on a "/" boundary so /repo-backup is not taken
--- for a child of /repo.
---@param path string
---@param dir string
---@return boolean
local function under(path, dir)
  path = vim.uv.fs_realpath(path) or path
  dir = vim.uv.fs_realpath(dir) or dir
  return path == dir or vim.startswith(path, dir == "/" and "/" or dir .. "/")
end

--- `root`, then each parent up to and including `top`. Just `root` when `top`
--- is nil or not one of its ancestors.
---@param root string
---@param top string|nil
---@return string[]
local function ladder(root, top)
  local dirs = { root }
  if not top or root == top or not under(root, top) then
    return dirs
  end
  local d = root
  while true do
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    d = parent
    dirs[#dirs + 1] = d
    if d == top or not under(d, top) then
      break
    end
  end
  return dirs
end

--- Entry names in `dir`, or nil when it cannot be listed.
---@param dir string|nil
---@return string[]|nil
local function entries(dir)
  local fd = dir and vim.uv.fs_scandir(dir)
  if not fd then
    return nil
  end
  local out = {}
  while true do
    local name = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    out[#out + 1] = name
  end
  return out
end

--- The virtualenv directory this project's packages live in, if there is one.
---
--- `.venv` or `venv` (with a pyvenv.cfg, which every venv builder writes) in
--- `root` and then in each parent up to `top`, nearest first. An activated
--- `$VIRTUAL_ENV` only counts when it sits under `top` (or `root` without one):
--- Neovim inherits whatever shell it was launched from, and an env var pointing
--- at some other project's venv is worse than no answer, because it resolves
--- imports against packages this project never declared.
---@param root string|nil
---@param top string|nil
---@return string|nil
function M.venv_dir(root, top)
  if not root then
    return nil
  end
  for _, d in ipairs(ladder(root, top)) do
    for _, name in ipairs({ ".venv", "venv" }) do
      local dir = vim.fs.joinpath(d, name)
      if vim.uv.fs_stat(vim.fs.joinpath(dir, "pyvenv.cfg")) then
        return dir
      end
    end
  end
  local active = vim.env.VIRTUAL_ENV
  if active and active ~= "" and under(active, top or root) then
    if vim.uv.fs_stat(vim.fs.joinpath(active, "pyvenv.cfg")) then
      return active
    end
  end
  return nil
end

--- Resolve a pyenv-managed interpreter for a version request.
---
--- `.python-version` is not the pyenv-only file it used to be: uv writes one
--- too, and it writes a bare minor version (`3.12`) where pyenv's versions
--- directory holds `3.12.10`, so an exact match alone finds nothing. An exact
--- hit is tried first (pyenv's own rule) and a component-boundary prefix match
--- is the fallback, taking the highest such version. The boundary check
--- matters: a plain prefix test would let `3.1` claim `3.10.14`.
---@param want string
---@return string|nil
function M.pyenv_interpreter(want)
  local pyenv = vim.env.PYENV_ROOT
  if not pyenv or pyenv == "" then
    pyenv = vim.fs.joinpath(vim.env.HOME or "", ".pyenv")
  end
  local versions = vim.fs.joinpath(pyenv, "versions")
  local exact = vim.fs.joinpath(versions, want, "bin", "python")
  if vim.uv.fs_stat(exact) then
    return exact
  end
  -- Compared as versions, not strings: as strings "3.12.4" outranks "3.12.10".
  -- A name vim.version cannot parse (a "3.12.0b1" build) falls back to the
  -- string order rather than raising out of an LSP hook.
  local function older(a, b)
    local ok, lt = pcall(vim.version.lt, a, b)
    if ok then
      return lt
    end
    return a < b
  end
  local best = nil
  for _, name in ipairs(entries(versions) or {}) do
    if name:sub(1, #want + 1) == want .. "." and (not best or older(best, name)) then
      best = name
    end
  end
  if not best then
    return nil
  end
  local exe = vim.fs.joinpath(versions, best, "bin", "python")
  return vim.uv.fs_stat(exe) and exe or nil
end

---@class PythonEnv
---@field exe string the interpreter
---@field venv string|nil the virtualenv directory, for kind "venv"
---@field kind "venv"|"pyenv"

--- The interpreter that can import this project's dependencies, or nil when
--- nothing on disk identifies one — in which case the caller should leave the
--- choice to whoever runs Python next rather than guess `python3` on PATH.
---
--- A venv anywhere up to `top` wins; failing that, the pyenv version named by
--- the nearest `.python-version` up to `top`. The pyenv rung exists because
--- `python3` on PATH is usually a pyenv shim, a script that re-reads
--- `.python-version` relative to the CWD of whatever runs it — Neovim's, not
--- the project's.
---@param root string|nil
---@param top string|nil
---@return PythonEnv|nil
function M.resolve(root, top)
  if not root then
    return nil
  end
  local venv = M.venv_dir(root, top)
  if venv then
    local exe = vim.fs.joinpath(venv, "bin", "python")
    if vim.uv.fs_stat(exe) then
      return { exe = exe, venv = venv, kind = "venv" }
    end
  end
  for _, d in ipairs(ladder(root, top)) do
    local pinned = state.read_file(vim.fs.joinpath(d, ".python-version"))
    local want = pinned and pinned:match("^%s*([%w%.%-_]+)")
    if want then
      local exe = M.pyenv_interpreter(want)
      return exe and { exe = exe, kind = "pyenv" } or nil
    end
  end
  return nil
end

--- A venv's site-packages directory: `lib/python3.X/site-packages`. Built from
--- the venv DIRECTORY, never from the interpreter path — every venv builder
--- symlinks `bin/python` at the base install, whose site-packages holds none of
--- the project's packages.
---@param venv string|nil
---@return string|nil
function M.site_packages(venv)
  local lib = venv and vim.fs.joinpath(venv, "lib")
  for _, name in ipairs(entries(lib) or {}) do
    if name:match("^python%d") then
      local sp = vim.fs.joinpath(lib, name, "site-packages")
      if vim.uv.fs_stat(sp) then
        return sp
      end
    end
  end
  return nil
end

return M
