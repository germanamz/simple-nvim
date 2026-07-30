-- Keep ts_ls's root_dir inside the repository that contains the buffer.
--
-- The bug this fixes
-- ------------------
-- lspconfig roots ts_ls at the nearest package-manager lockfile, and
-- `vim.fs.root`'s NESTED marker groups mean "nearest lockfile ANYWHERE up to /"
-- outranks "nearest .git". So a single stray `pnpm-lock.yaml` at or above a
-- superproject root captures every lockfile-less submodule into ONE client
-- rooted over the whole tree — on a 200-submodule workspace, tsserver indexing
-- everything. It also hands `<root>/node_modules/.bin/typescript-language-server`
-- the server binary (lspconfig's `cmd` prefers it), and it widens
-- config.lsp_tsdk's own search bound so *that* adopts the stray ancestor
-- TypeScript as `(user-setting)`. The stray lockfile does not merely bypass the
-- tsdk fix, it recruits it.
--
-- Why the gate
-- ------------
-- Clamping unconditionally breaks the mirror-image layout: a git submodule
-- VENDORED inside a TS project and compiled by the parent's tsconfig gets
-- re-rooted at itself, tsserver puts the file in an inferred project, and a file
-- that compiled cleanly grows a false TS2307. That shape is live here —
-- `~/projects/germanamz` is a pnpm project whose `content/posts` is a submodule.
-- So the clamp only fires when the repo boundary is *itself* a TypeScript
-- project (owns tsconfig.json / jsconfig.json). Rooting a config-less submodule
-- at its own directory buys nothing anyway.
--
-- Known residue: a lockfile-less submodule with NO tsconfig of its own keeps the
-- escape (and the .bin hijack). Documented in docs/lsp-typescript-version.md.
--
-- Wiring (lua/plugins/lsp.lua): `bound()` must sit INSIDE
-- `lsp_tsdk.wrap_root_dir`, so the tsdk memo is keyed by the CLAMPED dir —
-- `before_init` looks the memo up by `config.root_dir`, so clamping outside the
-- wrapper turns every injection into a miss (measured: both packages fell back
-- to the bundled copy and a real error was swallowed — worse than not clamping).
local M = {}

--- Directory the boundary search starts from: the buffer's own, falling back to
--- the cwd only for a genuinely unnamed buffer.
---
--- Deliberately NOT util.path.buf_start_dir — that has its own getcwd() fallback
--- whenever the buffer's directory does not exist, which relocates
--- `vim.fs.root(bufnr, …)`'s cwd trap rather than dodging it. Measured producing
--- a root that does not contain the buffer, which lsp_fs_sync's `root_covers`
--- then excludes from every nvim-tree file-operation notification.
---@param bufnr integer
---@return string
local function buf_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return vim.uv.cwd()
  end
  return vim.fs.dirname(name)
end

--- Does `dir` look like the root of a TypeScript project?
---@param dir string|nil
---@return boolean
function M.is_ts_project(dir)
  if not dir then
    return false
  end
  for _, marker in ipairs({ "tsconfig.json", "jsconfig.json" }) do
    if vim.uv.fs_stat(vim.fs.joinpath(dir, marker)) then
      return true
    end
  end
  return false
end

--- Pull `dir` down to `boundary` when the buffer's repo sits strictly below the
--- root upstream chose, and that repo is a TS project. Pure — no filesystem.
---@param dir string|nil root upstream resolved
---@param boundary string|nil nearest enclosing .git dir, or nil outside a repo
---@param is_ts_project boolean whether `boundary` owns a ts/jsconfig
---@return string|nil
function M.clamp(dir, boundary, is_ts_project)
  if not dir or not boundary or not is_ts_project then
    return dir
  end
  local d = (dir:gsub("(.)/+$", "%1"))
  local b = (boundary:gsub("(.)/+$", "%1"))
  -- "/" is its own separator; "/" .. "/" would be a bogus prefix and would let a
  -- root of "/" (a getcwd fallback, a top-level stray lockfile) escape the clamp.
  local prefix = d == "/" and "/" or d .. "/"
  if #b > #d and vim.startswith(b, prefix) then
    return b
  end
  return dir
end

-- Memoized by base so re-running the plugin spec (`:Lazy reload`) returns the
-- same wrapper instead of layering a second clamp on the first.
local bounded = setmetatable({}, { __mode = "k" })

--- Wrap a `root_dir` resolver so its answer is clamped to the buffer's repo.
--- The base keeps deciding (including lspconfig's deno abort: if it never calls
--- back, neither do we).
---@param base fun(bufnr: integer, on_dir: fun(dir: string|nil))
function M.bound(base)
  -- One lookup covers both cases, because a wrapper is stored under itself:
  -- a base we have seen returns its wrapper, and a wrapper returns itself.
  local cached = bounded[base]
  if cached then
    return cached
  end
  -- A resolver config.lsp_tsdk handed out on a previous config run — wrapping it
  -- would stack a second clamp on the first.
  if require("config.lsp_tsdk").is_wrapped(base) then
    return base
  end
  local fn = function(bufnr, on_dir)
    base(bufnr, function(dir)
      local boundary = vim.fs.root(buf_dir(bufnr), { ".git" })
      on_dir(M.clamp(dir, boundary, M.is_ts_project(boundary)))
    end)
  end
  bounded[base] = fn
  bounded[fn] = fn
  return fn
end

return M
