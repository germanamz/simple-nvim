-- Which formatter and which linter does this JS/TS project actually configure?
--
-- The bug this fixes
-- ------------------
-- lua/config/formatters.lua sent every web filetype to prettier unconditionally,
-- and conform never asks whether prettier is configured for the project
-- (require_cwd defaults to false, conform/init.lua:806). In a repo whose style
-- rules live in ESLint and which has no prettier config, prettier therefore ran
-- bare and applied its own singleQuote:false default — rewriting single quotes to
-- double on every save, against the project's own @stylistic/quotes rule.
--
-- Two slots, not one
-- ------------------
-- A project's formatter and linter are frequently different tools (biome formats
-- while eslint lints; prettier formats while oxlint lints), so both are resolved
-- independently in a single upward walk. Nearest config wins; ties inside one
-- directory break by tool priority, so a package carrying its own .prettierrc
-- inside a biome-rooted repo formats with prettier, as its authors intended.
--
-- Asymmetric marker sets
-- ----------------------
-- FORMATTER gates whether conform runs a tool; LINTER gates a language server
-- that resolves its own root. Each set therefore mirrors the discovery rules of
-- the thing it gates, and they differ on purpose: conform's biome formatter
-- accepts .biome.json (conform/formatters/biome.lua) which the server does not
-- (lspconfig/lsp/biome.lua), and the oxlint server accepts far more than
-- .oxlintrc.json (lspconfig/lsp/oxlint.lua). A set narrower than the tool's own
-- rules means declining to run a tool the project considers configured; a set
-- wider than the server's means suppressing eslint_d while no server starts.
local M = {}

local PRETTIER_FILES = {
  ".prettierrc",
  ".prettierrc.json",
  ".prettierrc.json5",
  ".prettierrc.yml",
  ".prettierrc.yaml",
  ".prettierrc.toml",
  ".prettierrc.js",
  ".prettierrc.cjs",
  ".prettierrc.mjs",
  ".prettierrc.ts",
  ".prettierrc.cts",
  ".prettierrc.mts",
  "prettier.config.js",
  "prettier.config.cjs",
  "prettier.config.mjs",
  "prettier.config.ts",
  "prettier.config.cts",
  "prettier.config.mts",
}

local ESLINT_FILES = {
  "eslint.config.js",
  "eslint.config.mjs",
  "eslint.config.cjs",
  "eslint.config.ts",
  "eslint.config.mts",
  "eslint.config.cts",
  ".eslintrc",
  ".eslintrc.js",
  ".eslintrc.cjs",
  ".eslintrc.json",
  ".eslintrc.yml",
  ".eslintrc.yaml",
}

-- Highest priority first. `pkg_keys` are probed inside package.json; `vite_lint`
-- means "vite.config.ts mentioning both vite-plus and a lint field", which is how
-- the oxlint server detects a Vite+ project.
local FORMATTER = {
  { tool = "biome", files = { "biome.json", "biome.jsonc", ".biome.json", ".biome.jsonc" } },
  { tool = "dprint", files = { "dprint.json", ".dprint.json", "dprint.jsonc", ".dprint.jsonc" } },
  { tool = "oxfmt", files = { ".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts" } },
  { tool = "prettier", files = PRETTIER_FILES, pkg_keys = { "prettier" } },
  { tool = "eslint", files = ESLINT_FILES, pkg_keys = { "eslintConfig" } },
}

local LINTER = {
  { tool = "biome", files = { "biome.json", "biome.jsonc" }, pkg_keys = { "biomejs" } },
  {
    tool = "oxlint",
    files = { ".oxlintrc.json", ".oxlintrc.jsonc", "oxlint.config.ts" },
    pkg_keys = { "oxlint", "vite-plus" },
    vite_lint = true,
  },
  { tool = "eslint", files = ESLINT_FILES, pkg_keys = { "eslintConfig" } },
}

--- Entry names in `dir` mapped to their type ("file" / "directory" / "link").
--- nil when the directory cannot be read — the caller treats that as "no markers
--- here" and keeps walking, rather than raising inside BufWritePre.
---@param dir string
---@return table<string, string>|nil
local function entries(dir)
  local fd = vim.uv.fs_scandir(dir)
  if not fd then
    return nil
  end
  local out = {}
  while true do
    local name, typ = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    out[name] = typ
  end
  return out
end

--- Whole-file read that never raises. io.open (not io.lines) because io.lines
--- errors if the file vanished between the scan and the open.
---@param path string
---@return string|nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  return raw
end

--- Does `dir`'s package.json carry any of `keys` at the top level?
---@param dir string
---@param keys string[]
---@return boolean
local function pkg_has_key(dir, keys)
  local raw = read_file(vim.fs.joinpath(dir, "package.json"))
  if not raw then
    return false
  end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return false
  end
  for _, key in ipairs(keys) do
    if data[key] ~= nil then
      return true
    end
  end
  return false
end

--- A Vite+ config that opts into linting, matching lspconfig/lsp/oxlint.lua's
--- root_markers_with_field probe.
---@param dir string
---@return boolean
local function vite_lints(dir)
  local raw = read_file(vim.fs.joinpath(dir, "vite.config.ts"))
  if not raw then
    return false
  end
  return raw:find("vite-plus", 1, true) ~= nil and raw:find("lint:", 1, true) ~= nil
end

--- Does `rule` match at `dir`, given that directory's entry names?
---@param dir string
---@param names table<string, string>
---@param rule table
---@return boolean
local function matches(dir, names, rule)
  for _, file in ipairs(rule.files) do
    if names[file] then
      return true
    end
  end
  if rule.pkg_keys and names["package.json"] and pkg_has_key(dir, rule.pkg_keys) then
    return true
  end
  if rule.vite_lint and names["vite.config.ts"] and vite_lints(dir) then
    return true
  end
  return false
end

--- Does the walk end after `dir`?
---
--- A .git DIRECTORY is a standalone repository: always a boundary. A .git FILE is
--- a submodule, and there the package.json gate decides — an independent JS
--- package is sealed off from its superproject, while a vendored subtree (say a
--- markdown submodule inside a JS project) keeps inheriting the parent's config.
--- Without the directory case, a repo that is not itself a JS package (this nvim
--- config; a Go repo full of markdown) would walk all the way to /, where a stray
--- ~/.prettierrc would silently govern it.
---@param dir string
---@param names table<string, string>
---@return boolean
local function is_boundary(dir, names)
  local git = names[".git"]
  if not git then
    return false
  end
  if git == "directory" then
    return true
  end
  return require("util.project").is_root(dir, { "package.json" })
end

--- Memoized by the buffer's directory. Both slots are invariant per directory for
--- a session unless a config file is added or the repo topology changes; both of
--- those clear the cache (config.dir_cache, and the BufWritePost hook in
--- lua/plugins/conform.lua). Negative results are cached too — a repo that
--- configures nothing is the common case and must not re-walk on every save.
local cache = {}

--- Drop the memoized answers. Wired into config.dir_cache; also used by tests.
function M._clear()
  cache = {}
end

--- Every marker basename, plus package.json. lua/plugins/conform.lua uses this as
--- the BufWritePost pattern so adding a config takes effect on write.
---@return string[]
function M.marker_basenames()
  local seen, out = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  for _, group in ipairs({ FORMATTER, LINTER }) do
    for _, rule in ipairs(group) do
      for _, file in ipairs(rule.files) do
        add(file)
      end
      if rule.vite_lint then
        add("vite.config.ts")
      end
    end
  end
  add("package.json")
  return out
end

--- Which formatter and linter govern this buffer's project.
--- `root` is the directory of the first marker hit, whichever slot found it.
---@param bufnr integer 0 (or nil) means the current buffer
---@return { formatter: string|nil, linter: string|nil, root: string|nil }
function M.resolve(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local dir = (name ~= "" and vim.fs.dirname(name)) or vim.uv.cwd()
  if not dir then
    return { formatter = nil, linter = nil, root = nil }
  end

  local cached = cache[dir]
  if cached then
    return cached
  end

  local result = { formatter = nil, linter = nil, root = nil }
  local cur = dir
  while cur do
    local names = entries(cur)
    if names then
      if not result.formatter then
        for _, rule in ipairs(FORMATTER) do
          if matches(cur, names, rule) then
            result.formatter = rule.tool
            result.root = result.root or cur
            break
          end
        end
      end
      if not result.linter then
        for _, rule in ipairs(LINTER) do
          if matches(cur, names, rule) then
            result.linter = rule.tool
            result.root = result.root or cur
            break
          end
        end
      end
      if (result.formatter and result.linter) or is_boundary(cur, names) then
        break
      end
    end
    local parent = vim.fs.dirname(cur)
    if not parent or parent == cur then
      break
    end
    cur = parent
  end

  cache[dir] = result
  return result
end

return M
