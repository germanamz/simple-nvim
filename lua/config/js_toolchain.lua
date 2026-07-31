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
--
-- Two package.json probe styles, not one
-- ---------------------------------------
-- pkg_keys does a top-level key lookup on the decoded JSON; pkg_patterns scans
-- the raw text line by line for a Lua pattern. These are not interchangeable,
-- and which one a rule uses is dictated by the tool it mirrors, not by taste.
-- conform's prettierd.lua and the eslintConfig convention read package.json as
-- structured data, so the FORMATTER prettier/eslint rows use pkg_keys. The
-- LINTER biome/oxlint rows use pkg_patterns because that is what
-- nvim-lspconfig/lua/lspconfig/util.lua's root_markers_with_field literally
-- does: open the file and call line:find(pattern) on every line, unparsed. So
-- lspconfig's "biomejs" probe matches the devDependencies line
-- `"@biomejs/biome": "^2.5.5",` — a dependency, not a top-level key, which a
-- real project's package.json essentially never has. A key-lookup here would
-- resolve linter "eslint" for a biome project that only has the dependency,
-- the biome server would still attach on its own root logic, and Task 6 would
-- fire eslint_d on top: duplicate diagnostics from two linters, the exact
-- failure these asymmetric tables exist to prevent. Do not collapse the two
-- probes into one "cleaner" helper — they answer different questions.
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
  -- Deliberately no vite.config.ts probe here, unlike conform's own oxfmt
  -- builtin (conform/formatters/oxfmt.lua): that marker is broad — any
  -- vite.config.ts — and would claim every Vite project in the tree for a
  -- formatter it doesn't use. The LINTER oxlint row below DOES probe
  -- vite.config.ts, but only because lspconfig's own check is narrow: it
  -- requires both "vite-plus" AND "lint:" inside the file, not just the
  -- file's existence (see vite_lint / vite_lints below). Do not "restore
  -- parity" between the two rows — the asymmetry mirrors each row's own tool.
  { tool = "oxfmt", files = { ".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts" } },
  { tool = "prettier", files = PRETTIER_FILES, pkg_keys = { "prettier" } },
  { tool = "eslint", files = ESLINT_FILES, pkg_keys = { "eslintConfig" } },
}

-- biome and oxlint use pkg_patterns (raw line scan), not pkg_keys — see "Two
-- package.json probe styles" above. "vite%-plus" is a Lua pattern escaping the
-- hyphen (a bare "-" after a literal char means "0 or more, lazy" in Lua
-- patterns and would silently fail to match); keep it escaped.
local LINTER = {
  { tool = "biome", files = { "biome.json", "biome.jsonc" }, pkg_patterns = { "biomejs" } },
  {
    tool = "oxlint",
    files = { ".oxlintrc.json", ".oxlintrc.jsonc", "oxlint.config.ts" },
    pkg_patterns = { "oxlint", "vite%-plus" },
    vite_lint = true,
  },
  { tool = "eslint", files = ESLINT_FILES, pkg_keys = { "eslintConfig" } },
}

--- Entry names in `dir` mapped to their type ("file" / "directory" / "link").
--- nil when the directory cannot be read — never a raise, since this runs inside
--- BufWritePre. The caller ends the walk there (see M.resolve).
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

--- `dir`'s package.json, read and decoded at most once per directory per walk.
--- `raw` is the whole-file text (nil if absent or unreadable); `data` is the
--- decoded table (nil if raw is nil, unparsable, or not a table). Rules that
--- gate on package.json — up to five of them per directory across both
--- tables — share this instead of each re-opening and re-decoding the file.
---@param dir string
---@return { raw: string|nil, data: table|nil }
local function read_pkg(dir)
  local raw = read_file(vim.fs.joinpath(dir, "package.json"))
  if not raw then
    return { raw = nil, data = nil }
  end
  local ok, data = pcall(vim.json.decode, raw)
  return { raw = raw, data = (ok and type(data) == "table") and data or nil }
end

--- Does `pkg`'s decoded package.json carry any of `keys` at the top level?
--- Structured lookup — for rules that mirror a tool reading package.json as
--- data (conform's prettierd.lua, the eslintConfig convention).
---@param pkg { raw: string|nil, data: table|nil }
---@param keys string[]
---@return boolean
local function pkg_has_key(pkg, keys)
  if not pkg.data then
    return false
  end
  for _, key in ipairs(keys) do
    if pkg.data[key] ~= nil then
      return true
    end
  end
  return false
end

--- Does any line of `pkg`'s raw package.json text match any of `patterns`?
--- Unparsed line scan, matching nvim-lspconfig/lua/lspconfig/util.lua's
--- root_markers_with_field in its default 'any' match mode: open the file,
--- call line:find(pattern) on every line, stop at the first hit. Used for
--- rules that mirror a language server deciding its own attachment this way
--- (the LINTER biome/oxlint rows) — see "Two package.json probe styles" above.
---@param pkg { raw: string|nil, data: table|nil }
---@param patterns string[]
---@return boolean
local function pkg_matches_pattern(pkg, patterns)
  if not pkg.raw then
    return false
  end
  for line in pkg.raw:gmatch("[^\r\n]+") do
    for _, pat in ipairs(patterns) do
      if line:find(pat) then
        return true
      end
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

--- Does `rule` match at `dir`, given that directory's entry names and its
--- (already read, possibly nil) package.json context?
---@param dir string
---@param names table<string, string>
---@param rule table
---@param pkg { raw: string|nil, data: table|nil }|nil
---@return boolean
local function matches(dir, names, rule, pkg)
  for _, file in ipairs(rule.files) do
    if names[file] then
      return true
    end
  end
  if pkg then
    if rule.pkg_keys and pkg_has_key(pkg, rule.pkg_keys) then
      return true
    end
    if rule.pkg_patterns and pkg_matches_pattern(pkg, rule.pkg_patterns) then
      return true
    end
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
  -- vim.fn.getcwd() (window/tab-local), not vim.uv.cwd() (process-wide), and for
  -- the same reason config.formatters:27 uses it: the answer is memoized below
  -- and invalidated by config.dir_cache on DirChanged, which fires for `:lcd` —
  -- an event that moves the window's cwd without necessarily moving a process
  -- cwd this resolver would then never consult.
  local dir = (name ~= "" and vim.fs.dirname(name)) or vim.fn.getcwd()
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
    -- A directory we cannot list is a boundary, not a blank level. It is
    -- traversable (we got here from a child), but its `.git` is exactly as
    -- invisible to us as its `.prettierrc` — so climbing past it is climbing
    -- past a repo root we simply failed to see, all the way to /, where a stray
    -- ~/.prettierrc silently governs the buffer. Stopping loses at worst a
    -- config we could not have read anyway.
    if not names then
      break
    end
    local pkg = names["package.json"] and read_pkg(cur) or nil
    if not result.formatter then
      for _, rule in ipairs(FORMATTER) do
        if matches(cur, names, rule, pkg) then
          result.formatter = rule.tool
          result.root = result.root or cur
          break
        end
      end
    end
    if not result.linter then
      for _, rule in ipairs(LINTER) do
        if matches(cur, names, rule, pkg) then
          result.linter = rule.tool
          result.root = result.root or cur
          break
        end
      end
    end
    if (result.formatter and result.linter) or is_boundary(cur, names) then
      break
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

-- Memoized by base, then by tool, so re-running the plugin spec (:Lazy reload,
-- a test clearing package.loaded) returns the same wrapper instead of
-- layering a second gate on the first — mirrors config.lsp_root's `bounded`.
-- Weak-keyed outer table so a base lspconfig discards can still be collected.
-- The tool name gets a nested key rather than folding into one flat table,
-- because the same base could in principle be gated for two different tools;
-- each (base, tool) pair gets its own wrapper, and (as below) each wrapper is
-- also stored under itself so re-gating an already-gated resolver for the
-- same tool is a no-op rather than a second layer.
local gated = setmetatable({}, { __mode = "k" })

--- Wrap a language server's `root_dir` so it starts only where detection names
--- `tool` as the linter.
---
--- Wrapping rather than replacing: the server keeps deciding WHERE its root is
--- (biome's resolver deliberately picks the monorepo root so one instance serves
--- every package), we only decide WHETHER it gets one. Declining to call `on_dir`
--- is how lspconfig itself says "not this buffer", and with workspace_required —
--- which both servers already set — that means no process at all.
---@param base fun(bufnr: integer, on_dir: fun(dir: string|nil))
---@param tool string
---@return fun(bufnr: integer, on_dir: fun(dir: string|nil))
function M.gate_root_dir(base, tool)
  local by_tool = gated[base]
  local cached = by_tool and by_tool[tool]
  if cached then
    return cached
  end
  local fn = function(bufnr, on_dir)
    local ok, result = pcall(M.resolve, bufnr)
    if not ok or result.linter ~= tool then
      return
    end
    -- Deliberately wraps the call to `on_dir` too, not just `base`: `base`
    -- invokes `on_dir` synchronously (both lspconfig resolvers here do), so
    -- there is no seam to pcall one without the other. A genuine error raised
    -- from inside vim.lsp's own dir handling is therefore swallowed silently
    -- here as well — accepted, not overlooked, because the alternative is a
    -- throw propagating into lspconfig's resolution.
    pcall(base, bufnr, on_dir)
  end
  gated[base] = gated[base] or setmetatable({}, { __mode = "k" })
  gated[base][tool] = fn
  gated[fn] = gated[fn] or setmetatable({}, { __mode = "k" })
  gated[fn][tool] = fn
  return fn
end

return M
