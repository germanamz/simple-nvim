-- Go documentation coordinates: which package a cursor sits in, and how to show
-- its docs without a network round trip.
--
-- Why prefer = "local"
-- --------------------
-- `go doc` is the strongest offline renderer any adapter here gets: it reads
-- $GOMODCACHE directly, needs no build step and no generated HTML, and answered
-- in 91ms (stdlib) / 136ms (third-party) under GOPROXY=off on a warm cache. The
-- float beats the browser, so the URL is the fallback rather than the reverse.
--
-- The all-or-nothing module graph
-- -------------------------------
-- `go doc` resolves the WHOLE module graph before it will name a single symbol,
-- so any unresolvable require poisons it — but not uniformly, and the asymmetry
-- is what cmd() below is shaped around. Probed with one uncached module in
-- go.mod: stdlib lookups still succeed (exit 0) while EVERY third-party lookup
-- fails (exit 1), including modules that are themselves fully cached, because
-- the failed graph load drops the go command back to GOPATH resolution. A
-- missing go.sum entry fails identically. So a failing cmd() is routine, not
-- exceptional: the driver falls through to url() and pkg.go.dev serves the same
-- page.
--
-- Why url() carries no version
-- ----------------------------
-- gopls hovers link the versioned page
-- (pkg.go.dev/github.com/go-chi/chi/v5@v5.3.1#Mux.Get) and config.docs.resolve
-- already scrapes exactly that whenever gopls is warm. This adapter is the cold
-- path, and DocCoord has no version field to carry one through — so it emits the
-- unversioned pkg.go.dev/<path>#<Symbol>, which serves latest. Resolving a
-- version here would mean reading go.mod from inside url(), costing the purity
-- the driver's unit tests depend on, for a cosmetic gain.

local M = {}

-- go.sum and go.work are deliberately absent. go.sum lines are hashes, not
-- module identities, and go.work `use ./dir` lines name local directories that
-- have no published docs — neither yields a coordinate worth a keypress.
M.ft = { "go", "gomod" }

-- Only go.mod. A go.work parent would resolve LOWER than the module the buffer
-- actually lives in, and `go doc -C` wants the module directory, which is
-- already a valid target inside a workspace.
M.manifest = "go.mod"

M.prefer = "local"

-- Bound on the two `go` invocations deps() makes. A toolchain that decides it
-- needs to download itself can block for a long time; a picker open must not.
local GO_TIMEOUT_MS = 3000

--- Run `argv`, returning stdout only on a clean exit.
---
--- Synchronous by necessity — the contract's deps() returns its list rather than
--- taking a callback. pcall wraps the call because vim.system raises outright
--- when the executable is missing, and "no Go toolchain installed" must read as
--- "no dependencies to offer", not as an error thrown out of a picker.
---@param argv string[]
---@return string|nil
local function capture(argv)
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait(GO_TIMEOUT_MS)
  end)
  if not ok or type(res) ~= "table" or res.code ~= 0 then
    return nil
  end
  return res.stdout
end

--- Is `path` a standard-library import path rather than a module path?
---
--- Verified in both directions against this toolchain: no entry in `go list std`
--- has a dot in its first path element, and no require in any go.mod on this
--- machine lacks one. It is the same test the go command uses to tell a module
--- path from a std path — a module path's leading element is a hostname.
---@param path string
---@return boolean
local function is_stdlib(path)
  local first = path:match("^([^/]+)")
  return first ~= nil and not first:find(".", 1, true)
end

--- The identifier an import binds when it carries no explicit alias.
---
--- NOT simply the last path element. `/vN` is the module-path major-version
--- suffix and never appears in the package name — github.com/go-chi/chi/v5 is
--- package `chi`, confirmed against gopls, which anchors its hover links at
--- chi.Mux. Only N>=2 is a valid suffix, so a genuine `/v1` element stays.
--- gopkg.in spells the same version as `.vN` on the last element and there it
--- starts at .v1, so gopkg.in/yaml.v3 is package `yaml` (read out of the module
--- cache to confirm).
---@param path string
---@return string|nil
local function package_name(path)
  local last = path:match("([^/]+)$")
  if not last then
    return nil
  end
  local major = last:match("^v(%d+)$")
  if major and tonumber(major) >= 2 then
    last = path:match("([^/]+)/[^/]+$") or last
  end
  return (last:gsub("%.v%d+$", ""))
end

--- Every import in `bufnr`, keyed by the identifier it binds.
---
--- A line scan rather than treesitter: coord() must answer with no parser
--- installed and no LSP attached, and Go's import syntax is regular enough that
--- the scan is exact. The walk stops at the first top-level declaration because
--- the language requires imports to precede them — that bounds the work on a
--- large file and keeps a `)` inside a function body from being mistaken for the
--- end of an import block we are no longer in.
---@param bufnr integer
---@return table<string, string>
local function imports(bufnr)
  local out = {}

  local function add(text)
    local alias, path = text:match('^%s*([%w_%.]+)%s+"([^"]+)"')
    if not path then
      path = text:match('^%s*"([^"]+)"')
    end
    if not path then
      return
    end
    -- `_` binds nothing and `.` binds every symbol unqualified. Recording either
    -- would let a later lookup match an identifier that is not in scope under
    -- that name, inventing a coordinate instead of declining to answer.
    if alias == "_" or alias == "." then
      return
    end
    local key = alias or package_name(path)
    if key then
      out[key] = path
    end
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    return out
  end

  local in_block = false
  for _, line in ipairs(lines) do
    if in_block then
      if line:match("^%s*%)") then
        in_block = false
      else
        add(line)
      end
    else
      local rest = line:match("^%s*import%s+(.*)$")
      if rest then
        if rest:match("^%(") then
          in_block = true
          add(rest:sub(2))
        else
          add(rest)
        end
      elseif
        line:match("^%s*func%s")
        or line:match("^%s*type%s")
        or line:match("^%s*var%s")
        or line:match("^%s*const%s")
      then
        break
      end
    end
  end
  return out
end

--- Coordinates for the identifier under the cursor.
---
--- Three shapes, and the order matters. A word carrying a slash is an import
--- path, so it is handled first: splitting github.com/go-chi/chi/v5 on its first
--- dot would resolve package `github`. A trailing `.Symbol` counts as a selector
--- only when it follows the LAST slash and is exported, since Go symbols
--- reachable from another package are always capitalised while a dot inside a
--- path segment belongs to the hostname.
---
--- A dotted word whose head is not an import resolves to nil on purpose. That is
--- the common `router.HandlerFunc` case — a local variable, not a package — and
--- guessing a package from it would send the browser somewhere arbitrary.
--- config.docs.resolve's hover path answers those correctly off gopls.
---@param ctx DocCtx
---@return DocCoord|nil
function M.coord(ctx)
  local word = ctx and ctx.word
  if type(word) ~= "string" or word == "" then
    return nil
  end

  if word:find("/", 1, true) then
    local path, sym = word:match("^(.-/[^/%.]*)%.(%u[%w_%.]*)$")
    if path then
      return { pkg = path, symbol = sym, stdlib = is_stdlib(path) }
    end
    return { pkg = word, stdlib = is_stdlib(word) }
  end

  local imps = imports(ctx.bufnr)

  local head, rest = word:match("^([%w_]+)%.(.+)$")
  if head then
    local path = imps[head]
    if not path then
      return nil
    end
    -- `rest` keeps any further dots: httprouter.Router.ServeHTTP yields
    -- Router.ServeHTTP, which is simultaneously what `go doc` accepts and the
    -- pkg.go.dev anchor (verified: pkg.go.dev/net/http#ResponseWriter.Write).
    return { pkg = path, symbol = rest, stdlib = is_stdlib(path) }
  end

  local path = imps[word]
  if path then
    return { pkg = path, stdlib = is_stdlib(path) }
  end
  return nil
end

--- A pkg.go.dev URL for `c`.
---
--- Pure: pkg/symbol/stdlib in, string out, no disk and no process. The shapes
--- are copied from what gopls itself emits, captured over a live LSP session
--- rather than guessed — package pages as pkg.go.dev/<path>#<Symbol>, module
--- pages (from manifest_line) as pkg.go.dev/mod/<module>@<version>.
---
--- Nothing is escaped because nothing needs to be: import paths are already
--- URL-safe, module paths keep their capitals on pkg.go.dev
--- (.../mod/github.com/Masterminds/squirrel@v1.5.4, straight off gopls), and the
--- `+` in a `+incompatible` version is literal in a path segment.
---@param c DocCoord
---@return string|nil
function M.url(c, _ctx)
  if not c or type(c.pkg) ~= "string" or c.pkg == "" then
    return nil
  end
  -- An `@` means manifest_line built this: a module identity, not an import
  -- path. Module and package pages are different URLs, and only the module page
  -- exists for a module with no root package.
  if c.pkg:find("@", 1, true) then
    return "https://pkg.go.dev/mod/" .. c.pkg
  end
  local url = "https://pkg.go.dev/" .. c.pkg
  -- Pin when the caller already knows the version. go.mod records exact
  -- versions (v1.3.0, or a v0.0.0-<ts>-<sha> pseudo-version), both of which are
  -- valid path segments, so the picker gets the docs for the build you have
  -- rather than for latest. Nothing is resolved to learn this — it is the
  -- string the manifest already stated.
  if type(c.version) == "string" and c.version ~= "" then
    url = url .. "@" .. c.version
  end
  if type(c.symbol) == "string" and c.symbol ~= "" then
    url = url .. "#" .. c.symbol
  end
  return url
end

--- argv for rendering `c` with `go doc`.
---
--- `-C` must be the first flag — `go doc <sym> -C <dir>` prints a usage error —
--- and it is what makes third-party lookups work at all: from outside a module,
--- `go doc github.com/julienschmidt/httprouter.Router` fails while
--- `go doc net/http.HandlerFunc` still resolves out of GOROOT. That is exactly
--- why a nil root is fatal for a dependency but harmless for the standard
--- library, and why this returns nil in only the first of those two cases.
---
--- The `@` guard is not defensive coding: `go doc` genuinely rejects
--- `pkg@version` ("cannot find package ..."), so a manifest_line coordinate
--- would burn a process spawn to fail before the driver reached url().
---@param c DocCoord
---@param ctx DocCtx
---@return string[]|nil
function M.cmd(c, ctx)
  if not c or type(c.pkg) ~= "string" or c.pkg == "" then
    return nil
  end
  if c.pkg:find("@", 1, true) then
    return nil
  end

  local arg = c.pkg
  if type(c.symbol) == "string" and c.symbol ~= "" then
    arg = arg .. "." .. c.symbol
  end

  local root = ctx and ctx.root
  if not root then
    if not c.stdlib then
      return nil
    end
    return { "go", "doc", arg }
  end
  return { "go", "doc", "-C", root, arg }
end

-- Module paths and versions, as character classes rather than %p: %p would also
-- swallow the quotes and parens that surround real go.mod syntax.
local PATH_PAT = "[%w%.%-_~/]+"
local VERSION_PAT = "v[%w%.%-+_]+"

--- Parse one go.mod line into a coordinate.
---
--- Split out from manifest_line so it can be tested against fixture strings with
--- no buffer, and public for the same reason.
---
--- Both require spellings are accepted (`require <path> <version>` and a bare
--- indented line inside a `require (` block). The dot test on the first path
--- element is load-bearing, not cosmetic: `retract v1.0.0` is real go.mod syntax
--- that otherwise parses as the module "retract" at v1.0.0. It also rejects
--- `go 1.26.4` and `toolchain go1.26.4` on its own, since neither version token
--- starts with a literal `v`.
---@param line string
---@return DocCoord|nil
function M._parse_require(line)
  if type(line) ~= "string" then
    return nil
  end
  -- Strip a trailing comment before matching: every indirect dependency carries
  -- `// indirect`, and a module path can never contain `//`.
  local code = line:match("^(.-)//") or line

  local path, version =
    code:match("^%s*require%s+(" .. PATH_PAT .. ")%s+(" .. VERSION_PAT .. ")%s*$")
  if not path then
    path, version = code:match("^%s*(" .. PATH_PAT .. ")%s+(" .. VERSION_PAT .. ")%s*$")
  end
  if not path then
    return nil
  end
  local first = path:match("^([^/]+)")
  if not first or not first:find(".", 1, true) then
    return nil
  end
  return { pkg = path .. "@" .. version }
end

--- The coordinate for the go.mod line the cursor is on.
---
--- A fallback, not the primary path: gopls emits precisely these targets as
--- documentLinks (verified against a live session —
--- pkg.go.dev/mod/github.com/go-chi/chi/v5@v5.3.1), and config.docs.resolve
--- prefers them. This answers when gopls is not attached.
---
--- `lnum` is treated as 1-indexed, matching the cursor position the driver reads
--- it from. The basename check keeps a stray require-shaped line in some other
--- buffer from being read as a dependency.
---@param bufnr integer
---@param lnum integer
---@return DocCoord|nil
function M.manifest_line(bufnr, lnum)
  local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  if not ok or vim.fs.basename(name) ~= "go.mod" then
    return nil
  end
  local got, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum - 1, lnum, false)
  if not got or not lines or not lines[1] then
    return nil
  end
  return M._parse_require(lines[1])
end

-- Directory names that never contribute an importable standard-library package.
-- `cmd` is the toolchain's own source, and `go list std` reports nothing under
-- it; `internal` and `vendor` are unimportable from user code.
local STD_SKIP = { internal = true, vendor = true, testdata = true, cmd = true }

-- Invariant per toolchain, so it is resolved once per session. go.mod is
-- deliberately NOT cached alongside it: the user edits that file, and a 37ms
-- reparse is cheaper than reasoning about when to invalidate it.
local stdlib_cache = nil

--- Standard-library import paths, read straight off GOROOT/src.
---
--- `go list std` is the obvious source and the wrong one: it costs 305-473ms,
--- spawns the go command, and — because it only reports what builds for the
--- current GOOS/GOARCH — omits pages that pkg.go.dev genuinely serves, notably
--- syscall/js, builtin, encoding/json/v2 and crypto/boring. Scanning the
--- directory tree instead takes 7.5ms over 1320 directories and was diffed
--- against `go list std` on this toolchain: it is a strict superset of all 176
--- public entries, plus those 11 build-constrained ones.
---
--- The `.go` test is what distinguishes a package from a plain grouping
--- directory (`archive` holds only tar/ and zip/ and is not itself importable),
--- and it costs nothing since the scandir pass is already listing the entries.
---@return string[]
local function stdlib_packages()
  if stdlib_cache then
    return stdlib_cache
  end

  local out = {}
  local root = capture({ "go", "env", "GOROOT" })
  root = root and vim.trim(root) or ""
  -- Deliberately NOT cached: an unresolvable GOROOT means the toolchain was
  -- missing or wedged for this call, not that this machine has no standard
  -- library. Memoizing that would make one bad moment permanent for the session,
  -- and retrying costs a single failed spawn.
  if root == "" then
    return out
  end

  local function walk(dir, prefix)
    local fd = vim.uv.fs_scandir(dir)
    if not fd then
      return
    end
    local subs, has_go = {}, false
    while true do
      local name, typ = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if typ == "directory" then
        -- The go command ignores any path element starting with `_` or `.`, and
        -- so must this: without it the walk surfaces build-tool scaffolding like
        -- crypto/md5/_asm and simd/archsimd/_gen as importable packages.
        if not STD_SKIP[name] and not name:match("^[_%.]") then
          subs[#subs + 1] = name
        end
      elseif not has_go and name:sub(-3) == ".go" and not name:match("_test%.go$") then
        has_go = true
      end
    end
    if prefix ~= "" and has_go then
      out[#out + 1] = prefix
    end
    for _, name in ipairs(subs) do
      walk(vim.fs.joinpath(dir, name), prefix == "" and name or (prefix .. "/" .. name))
    end
  end

  walk(vim.fs.joinpath(root, "src"), "")
  table.sort(out)
  stdlib_cache = out
  return out
end

--- Dependencies declared by the go.mod at `root`, direct ones first.
---
--- `go mod edit -json` and nothing else. It is a pure parse of the one file —
--- 37ms, no module graph, no proxy, no build cache — where `go list -m all`
--- resolves the transitive graph and is not offline-safe. Passing the file path
--- explicitly rather than setting a cwd keeps the answer independent of wherever
--- the editor happens to be.
---
--- `Indirect` is absent rather than false on direct requires, so it is tested
--- for truth, not compared.
---@param root string
---@return table[]
local function module_deps(root)
  local raw = capture({ "go", "mod", "edit", "-json", vim.fs.joinpath(root, "go.mod") })
  if not raw then
    return {}
  end
  local ok, mod = pcall(vim.json.decode, raw)
  if not ok or type(mod) ~= "table" or type(mod.Require) ~= "table" then
    return {}
  end

  -- A `replace` decides which version is actually compiled, so reporting the
  -- required one would name a release the build never sees. Keyed twice because
  -- go.mod allows both a version-specific replace and a blanket one for a path.
  local replaced = {}
  for _, r in ipairs(type(mod.Replace) == "table" and mod.Replace or {}) do
    if type(r.Old) == "table" and type(r.New) == "table" then
      local key = r.Old.Path
      if r.Old.Version then
        key = key .. "@" .. r.Old.Version
      end
      replaced[key] = r.New
    end
  end

  local direct, indirect = {}, {}
  for _, req in ipairs(mod.Require) do
    if type(req.Path) == "string" then
      local version = req.Version
      local new = replaced[req.Path .. "@" .. tostring(req.Version)] or replaced[req.Path]
      if new then
        -- A replacement onto a local directory has no New.Version at all
        -- (verified), and no published page either — so the version is dropped
        -- rather than back-filled from the require line.
        version = new.Version
      end
      local entry =
        { name = req.Path, version = version, kind = req.Indirect and "indirect" or "direct" }
      table.insert(req.Indirect and indirect or direct, entry)
    end
  end

  vim.list_extend(direct, indirect)
  return direct
end

--- Everything worth offering in the dependency picker.
---
--- Ordered direct, then indirect, then standard library, so a picker that does
--- not sort on `kind` still opens on the packages this module actually chose.
--- The standard library is included because for Go it is the common answer, and
--- it is offered even when `root` is nil: a stray .go file outside any module
--- still has net/http.
---@param ctx DocCtx
---@return table[]|nil
function M.deps(ctx)
  local out = (ctx and ctx.root) and module_deps(ctx.root) or {}
  for _, name in ipairs(stdlib_packages()) do
    out[#out + 1] = { name = name, kind = "stdlib" }
  end
  if #out == 0 then
    return nil
  end
  return out
end

return M
