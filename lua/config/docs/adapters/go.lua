-- Go documentation coordinates: which package a cursor sits in, and how to show
-- its docs without a network round trip.
--
-- Why prefer = "local"
-- --------------------
-- `go doc` is the strongest offline renderer any adapter here gets: it reads
-- $GOMODCACHE directly, needs no build step and no generated HTML, and answered
-- in 91ms (stdlib) / 136ms (third-party) under GOPROXY=off on a warm cache —
-- 60-70ms for a whole package with -all. The viewer beats the browser, so the
-- URL is the fallback rather than the reverse.
--
-- The all-or-nothing module graph
-- -------------------------------
-- `go doc` resolves the WHOLE module graph before it will name a single symbol,
-- so any unresolvable require poisons it — but not uniformly, and the asymmetry
-- is what page() below is shaped around. Probed with one uncached module in
-- go.mod: stdlib lookups still succeed (exit 0) while EVERY third-party lookup
-- fails (exit 1), including modules that are themselves fully cached, because
-- the failed graph load drops the go command back to GOPATH resolution. A
-- missing go.sum entry fails identically. So a failing page() is routine, not
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

-- ===========================================================================
-- The viewer's half: a whole page, an outline into it, and source locations.
-- ===========================================================================

--- argv for the COMPLETE package page.
---
--- `-all` rather than the index `go doc` prints by default, and that one flag
--- is what makes the viewer possible. The index renders `type Client struct{
--- ... }` and stops; -all carries the full struct with its field comments and
--- every method inline (net/http: the type at line 711, `func (c *Client) Do`
--- at 796). So one 60-70ms call leaves nothing to fetch, and picking a symbol
--- out of the outline is a scroll rather than another subprocess.
---
--- `c.symbol` is deliberately ignored. A page is a package; the symbol you
--- arrived asking about only decides where the viewer parks the cursor.
---@param c DocCoord
---@param ctx DocCtx
---@return DocPage|nil
function M.page(c, ctx)
  if not c or type(c.pkg) ~= "string" or c.pkg == "" then
    return nil
  end
  -- A module coordinate (`path@version`, from manifest_line) names a thing
  -- `go doc` cannot render — same rejection cmd() makes, and for the same
  -- reason: it would burn a spawn to fail.
  if c.pkg:find("@", 1, true) then
    return nil
  end
  local root = ctx and ctx.root
  if root then
    return { cmd = { "go", "doc", "-all", "-C", root, c.pkg }, title = c.pkg }
  end
  -- Outside a module only GOROOT resolves, exactly as in cmd().
  if not c.stdlib then
    return nil
  end
  return { cmd = { "go", "doc", "-all", c.pkg }, title = c.pkg }
end

-- The four headers `go doc -all` emits, at column 0 and in this spelling.
local SECTIONS = {
  CONSTANTS = true,
  VARIABLES = true,
  FUNCTIONS = true,
  TYPES = true,
}

-- The declaration keywords that can open a column-0 line. Matched against an
-- exact set rather than `^%l+%s`, so a doc paragraph that happens to begin at
-- column 0 with a lowercase word cannot be read as a declaration.
local DECL = { func = true, type = true, const = true, var = true }

--- An outline of `lines`, as a tree of entries indexing back into them.
---
--- Pure: page text in, entries out, no buffer and no process. That is what
--- lets the whole parser be tested against captured `go doc -all` output.
---
--- The format makes this exact rather than heuristic. Declarations sit at
--- column 0 and documentation prose is always indented, so anchoring on `^`
--- separates them with no lookahead. Methods nest under their type by parsing
--- the RECEIVER — `func (c *Client) Do` files under `type Client` because of
--- the `(c *Client)`, not because of where it happens to fall in the file.
---
--- const/var groups collapse to one entry apiece. Expanding them is what an
--- outline must not do: net/http declares roughly a hundred status constants
--- in a single block, and listing each would bury the types they sit above.
--- The group is labelled with its first member, and `/` still finds any
--- individual constant in the page.
---@param lines string[]
---@return DocEntry[]
function M.outline(lines)
  if type(lines) ~= "table" then
    return {}
  end

  local out, by_type = {}, {}
  local section, group = nil, nil

  for i, line in ipairs(lines) do
    if group then
      -- Inside a `const (` / `var (` block. Column-0 `)` ends it; the first
      -- tab-indented identifier names it. Comment lines inside the block start
      -- `\t//` and so cannot be mistaken for that identifier.
      if line:match("^%)") then
        group = nil
      elseif not out[group].label then
        local name = line:match("^\t([%w_]+)")
        if name then
          out[group].label = name .. " …"
          out[group].symbol = name
        end
      end
    elseif SECTIONS[line] then
      out[#out + 1] = { label = line, lnum = i, kind = "section" }
      section = #out
    else
      local kw, rest = line:match("^([%l]+)%s+(.*)$")
      if kw and DECL[kw] and rest ~= "" then
        -- Only const and var open a group. Testing the paren alone would read
        -- a method — `func (c *Client) Do(...)`, whose rest also begins `(` —
        -- as a block opener, and it would then swallow every declaration up to
        -- the next column-0 `)`.
        if (kw == "const" or kw == "var") and rest:sub(1, 1) == "(" then
          -- `const (` / `var (`: one entry, labelled once we see a member.
          out[#out + 1] = { label = nil, lnum = i, kind = kw, parent = section }
          group = #out
        elseif kw == "func" then
          local recv, name = rest:match("^%(%s*[%w_]*%s*%*?([%w_]+)[^%)]*%)%s*([%w_]+)")
          if recv and name then
            out[#out + 1] = {
              label = name,
              lnum = i,
              kind = "method",
              parent = by_type[recv] or section,
              -- `Client.Do` is simultaneously what `go doc` accepts and the
              -- pkg.go.dev anchor, so one string serves both.
              symbol = recv .. "." .. name,
            }
          else
            local fn = rest:match("^([%w_]+)")
            if fn then
              out[#out + 1] = { label = fn, lnum = i, kind = "func", parent = section, symbol = fn }
            end
          end
        else
          local name = rest:match("^([%w_]+)")
          if name then
            out[#out + 1] = { label = name, lnum = i, kind = kw, parent = section, symbol = name }
          end
          if kw == "type" and name then
            by_type[name] = #out
          end
        end
      end
    end
  end

  -- A group that never yielded a member name (an empty or malformed block) has
  -- no label and would render as a blank row. Drop those rather than show them.
  local kept = {}
  local remap = {}
  for idx, e in ipairs(out) do
    if e.label then
      kept[#kept + 1] = e
      remap[idx] = #kept
    end
  end
  for _, e in ipairs(kept) do
    e.parent = e.parent and remap[e.parent] or nil
  end
  return kept
end

--- Import short-name -> import path, for the page's own package.
---
--- Async and lazy. The viewer asks only when you actually press <CR> on a
--- qualified name, so a page you merely read costs nothing, and the answer is
--- cached for the life of that page. `go list` is 40ms and — unlike `go list
--- -m all` — resolves only this one package, so it stays offline-safe.
---
--- Keyed by the identifier the import BINDS, which is package_name()'s job:
--- net/url binds `url`, and github.com/go-chi/chi/v5 binds `chi`, not `v5`.
---@param c DocCoord
---@param ctx DocCtx
---@param cb fun(map: table<string, string>)
function M.qualifiers(c, ctx, cb)
  if not c or type(c.pkg) ~= "string" or c.pkg == "" then
    return cb({})
  end
  -- The `\\n` is deliberate. Go's template parser wants the two characters
  -- `\` `n` and unescapes them itself; a real newline here makes the template
  -- an unterminated string literal and `go list` fails to parse it.
  local argv = { "go", "list", "-f", '{{join .Imports "\\n"}}' }
  if ctx and ctx.root then
    table.insert(argv, 2, "-C")
    table.insert(argv, 3, ctx.root)
  end
  argv[#argv + 1] = c.pkg

  local ok = pcall(function()
    vim.system(argv, { text = true }, function(res)
      local map = {}
      if res.code == 0 and res.stdout then
        for path in res.stdout:gmatch("[^\n]+") do
          local key = package_name(path)
          if key then
            map[key] = path
          end
        end
      end
      vim.schedule(function()
        cb(map)
      end)
    end)
  end)
  if not ok then
    cb({})
  end
end

--- What page does `word` point at, if any?
---
--- Pure, and about ONE question: which other package. Names that live on the
--- page you are already reading never reach here — the viewer resolves those
--- against its own outline and scrolls, which costs nothing.
---
--- `ctx.qualifiers` is the map qualifiers() produced. Absent it, only a word
--- that is already a full import path can resolve; guessing a package from a
--- bare qualifier is the same mistake coord() declines to make on
--- `router.HandlerFunc`.
---@param word string
---@param c DocCoord
---@param ctx DocCtx
---@return DocCoord|nil
function M.xref(word, c, ctx)
  if type(word) ~= "string" or word == "" then
    return nil
  end

  -- A slash means it is spelled as an import path already.
  if word:find("/", 1, true) then
    local path, sym = word:match("^(.-/[^/%.]*)%.(%u[%w_%.]*)$")
    if path then
      return { pkg = path, symbol = sym, stdlib = is_stdlib(path) }
    end
    return { pkg = word, stdlib = is_stdlib(word) }
  end

  local head, rest = word:match("^([%w_]+)%.([%w_%.]+)$")
  if not head then
    return nil
  end
  local quals = ctx and ctx.qualifiers
  local path = type(quals) == "table" and quals[head] or nil
  if not path then
    return nil
  end
  return { pkg = path, symbol = rest, stdlib = is_stdlib(path) }
end

--- An ERE matching the declaration of `symbol` at column 0.
---
--- Split out and pure so the receiver handling can be tested directly. The
--- receiver group is anchored on the closing paren — `\*?Client\)` rather than
--- `Client[^)]*\)` — because the loose form also matches `(cc *ClientConn)`
--- and would land `Client.Do` in httputil (verified against GOROOT).
---
--- The optional `\[[^]]*\]` after the type name is the generic parameter list,
--- so `func (r *N[C]) n()` still resolves.
---@param symbol string
---@return string|nil
function M._decl_pattern(symbol)
  if type(symbol) ~= "string" or symbol == "" then
    return nil
  end
  local recv, name = symbol:match("^([%w_]+)%.([%w_]+)$")
  if recv then
    return "^func \\([A-Za-z_0-9]+ \\*?" .. recv .. "(\\[[^]]*\\])?\\) " .. name .. "\\("
  end
  if not symbol:match("^[%w_]+$") then
    return nil
  end
  return "^(func|type|var|const) " .. symbol .. "([ (\\[]|$)"
end

--- Where `c.symbol` is declared on disk.
---
--- Two steps, both offline: `go list` names the package directory (GOROOT for
--- the standard library, GOMODCACHE for a dependency) and grep finds the
--- declaration in it. Enumerating the directory's own .go files rather than
--- passing grep -r is deliberate — recursion reaches subpackages, which is how
--- `Client.Do` first resolved to net/http/httputil.
---
--- Test files are excluded: an `ExampleClient_Do` in client_test.go is not the
--- declaration, and for some symbols it is the only other column-0 match.
---@param c DocCoord
---@param ctx DocCtx
---@param cb fun(loc: {file: string, lnum: integer}|nil)
function M.locate(c, ctx, cb)
  local pattern = c and M._decl_pattern(c.symbol)
  if not pattern or type(c.pkg) ~= "string" or c.pkg == "" then
    return cb(nil)
  end

  local argv = { "go", "list", "-f", "{{.Dir}}" }
  if ctx and ctx.root then
    table.insert(argv, 2, "-C")
    table.insert(argv, 3, ctx.root)
  end
  argv[#argv + 1] = c.pkg

  local function fail()
    vim.schedule(function()
      cb(nil)
    end)
  end

  local ok = pcall(function()
    vim.system(argv, { text = true }, function(res)
      if res.code ~= 0 or not res.stdout then
        return fail()
      end
      local dir = vim.trim(res.stdout)
      if dir == "" then
        return fail()
      end

      local files = {}
      for name, typ in vim.fs.dir(dir) do
        if typ == "file" and name:sub(-3) == ".go" and not name:match("_test%.go$") then
          files[#files + 1] = vim.fs.joinpath(dir, name)
        end
      end
      if #files == 0 then
        return fail()
      end

      -- -H because grep omits the filename when handed exactly one file, and a
      -- single-file package (common for small modules) would then parse as a
      -- bare line number with no path.
      local grep = { "grep", "-HnE", pattern }
      vim.list_extend(grep, files)
      vim.system(grep, { text = true }, function(hit)
        if hit.code ~= 0 or not hit.stdout or hit.stdout == "" then
          return fail()
        end
        local file, lnum = hit.stdout:match("^([^\n:]+):(%d+):")
        if not file or not lnum then
          return fail()
        end
        vim.schedule(function()
          cb({ file = file, lnum = tonumber(lnum) })
        end)
      end)
    end)
  end)
  if not ok then
    fail()
  end
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
