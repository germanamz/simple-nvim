-- Package-level documentation for JS/TS, and deliberately nothing below that.
--
-- npm has no generated-docs host. There is no rustdoc, no pkg.go.dev, no
-- javadoc.io — nobody renders published packages into a reference you can aim a
-- symbol URL at, and the third-party attempts are gone: as of 2026-08-12
-- tsdocs.dev answers 522 and paka.dev does not answer at all. So a symbol URL is
-- not something this adapter declines to build; it is something that does not
-- exist.
--
-- What every typed package DOES ship is its .d.ts, and that genuinely IS the
-- documentation: the signature, plus the JSDoc ts_ls already renders on hover,
-- and `gd` opens the file. Symbols therefore belong to the LSP half of this
-- feature (config.docs.resolve). This adapter answers one question — which
-- PACKAGE is under the cursor — and points at that package's own front door:
--
--   node builtins    nodejs.org/api/<module>.html
--   everything else  the installed package.json's `homepage` (offline, and
--                    exact for the version actually on disk), then
--                    npmjs.com/package/<name> as the link-out
--
-- No `cmd`, because there is nothing to run. Go has `go doc`, Python has
-- `pydoc`, Rust has a local rustdoc build; npm's `docs` subcommand just shells
-- out to a browser and everything else in the CLI is a network call. The one
-- offline artifact is the package's README, which is a file to open, not a
-- command's stdout.
--
-- Nothing here spawns a process. `npm ls` in particular is not an option: run at
-- a pnpm workspace root it prints every real dependency with `extraneous`
-- appended (measured in ~/projects/expenses: 32 of the 34 rows, every one of
-- them installed and linked), because npm answers about the package.json in the
-- cwd and a pnpm workspace root frequently has no package.json at all.

local M = {}

local state = require("util.state")

M.ft = { "javascript", "javascriptreact", "typescript", "typescriptreact" }

-- package.json, not tsconfig.json: both questions this adapter asks — which
-- package owns a specifier, what does this project depend on — are answered by
-- the manifest that sits next to node_modules. In a pnpm workspace that is the
-- LEAF package (packages/app/package.json), which is the right root here even
-- though ts_ls roots itself at the lockfile several levels above it.
M.manifest = "package.json"

-- Node core module -> the page that documents it under nodejs.org/api/. The
-- value is the page basename, or `false` for a builtin that has no page of its
-- own, so `url` can decline instead of linking at a 404.
--
-- Built from `require('module').builtinModules` on Node 24.13.0 minus the
-- `_http_*`/`_stream_*`/`_tls_*` internals, which are importable but undocumented
-- and never written on purpose, then checked name by name against the /api/ index.
local NODE_CORE = [[
  assert async_hooks buffer child_process cluster console crypto dgram
  diagnostics_channel dns domain events fs http http2 https inspector module net
  os path perf_hooks process punycode querystring readline repl sea sqlite stream
  string_decoder test timers tls tty url util v8 vm wasi worker_threads zlib
]]

local NODE_PAGE = {}
for name in NODE_CORE:gmatch("%S+") do
  NODE_PAGE[name] = name
end

-- The three names where the module and its page disagree. Nothing about the
-- module name predicts these, so they are the whole reason this is a table and
-- not string concatenation.
NODE_PAGE.trace_events = "tracing"
NODE_PAGE.sea = "single-executable-applications"
NODE_PAGE["stream/web"] = "webstreams" -- keyed with the subpath: see M.url

-- And the two builtins with no page anywhere. Both are deprecated aliases
-- (`sys` for util, `constants` for the per-module constants), documented only as
-- deprecation entries, so there is no module page to open.
NODE_PAGE.sys = false
NODE_PAGE.constants = false

-- Three of the names above are reachable ONLY through the `node:` prefix, which
-- is exactly how builtinModules lists them (`node:sqlite`, never `sqlite`) and
-- is not cosmetic: with an npm package of the same name installed,
-- `require("sqlite")` loads node_modules while `require("node:sqlite")` loads
-- core (verified both ways against a stub package). Unprefixed, these are
-- third-party names — and `test` is one anybody might install.
local PREFIX_ONLY = { sea = true, sqlite = true, test = true }

-- What makes a quoted string on a line a module specifier rather than just a
-- string. Frontier patterns so `./importer` and `information` do not count.
local IMPORT_CONTEXT = {
  "%f[%w]import%f[%W]",
  "%f[%w]export%f[%W]",
  "%f[%w]from%f[%W]",
  "%f[%w]require%s*%(",
}

-- Words a clause scan will pick up that are never a local binding. `type` and
-- `as` come from `import type { A }` and `* as ns`; the declaration keywords
-- come from the require() pass, whose clause runs backwards to the previous `=`.
local NOT_A_BINDING = {
  as = true,
  const = true,
  default = true,
  from = true,
  ["function"] = true,
  import = true,
  let = true,
  require = true,
  type = true,
  var = true,
}

-- Dependency maps a cursor can legitimately land in. `scripts` is deliberately
-- absent, and is the reason M._manifest_coord scans for its section at all:
-- `"dev": "vite --port 3001"` is line-locally indistinguishable from
-- `"react": "^18.3.1"`, and treating it as a package opens npm's page for `dev`.
local MANIFEST_SECTIONS = {
  dependencies = true,
  devDependencies = true,
  peerDependencies = true,
  optionalDependencies = true,
}

-- What `deps` lists, in order, with the kind it stamps on each row. Narrower
-- than MANIFEST_SECTIONS on purpose: peer and optional dependencies frequently
-- are NOT installed here (a peer is the consumer's job to provide, an optional
-- one may have been skipped), so listing them would fill the picker with rows
-- whose local package.json — the thing `url` reads for a homepage — is missing.
-- A cursor sitting on one in the manifest is still a real question, which is why
-- the other table is wider.
local DEPS_SECTIONS = {
  { key = "dependencies", kind = "direct" },
  { key = "devDependencies", kind = "dev" },
}

-- Lockfiles, in the order they are probed. A repo that switched managers tends
-- to keep the old lockfile around, so `.pnp.*` goes first: it is the only entry
-- that changes what is on DISK rather than just who wrote it.
local LOCKFILES = {
  { file = ".pnp.cjs", pm = "pnp" },
  { file = ".pnp.data.json", pm = "pnp" },
  { file = "pnpm-lock.yaml", pm = "pnpm" },
  { file = "pnpm-workspace.yaml", pm = "pnpm" },
  { file = "bun.lock", pm = "bun" },
  { file = "bun.lockb", pm = "bun" },
  { file = "yarn.lock", pm = "yarn" },
  { file = "package-lock.json", pm = "npm" },
  { file = "npm-shrinkwrap.json", pm = "npm" },
}

--- Which package manager owns `dir`, or nil when nothing there says so.
---
--- "pnp" is not a manager but a linker: Yarn Berry in its default mode (and
--- pnpm's `nodeLinker: pnp`) resolves out of zipped archives and writes NO
--- node_modules at all. That matters here beyond an empty stat — any
--- node_modules found under a `.pnp.cjs` is a leftover from a previous install,
--- so its package.json describes a version this project is not running, and
--- reading a homepage out of it is worse than falling through to npm.
---@param dir string
---@return "pnp"|"pnpm"|"bun"|"yarn"|"npm"|nil
function M._package_manager(dir)
  for _, entry in ipairs(LOCKFILES) do
    if vim.uv.fs_stat(vim.fs.joinpath(dir, entry.file)) then
      return entry.pm
    end
  end
  return nil
end

--- Coordinates for an import specifier, or nil when it names no package.
---
--- Everything that is not a bare package specifier is rejected: relative and
--- absolute paths, URLs (esm.sh / deno style), package.json `imports` subpaths
--- (`#internal/db`) and — the one that actually bites — tsconfig path aliases,
--- which are conventionally written `@/lib/metadata` and look exactly like a
--- scoped package until you notice the scope is empty.
---
--- A builtin wins over an identically named npm package because that is what
--- node itself does: with `node_modules/path` installed, both `require("path")`
--- and `import "path"` still load core (verified against a stub). `fs`, `path`
--- and `events` are all real names on npm, so this order is not academic.
---@param spec string
---@return DocCoord|nil
function M._specifier_coord(spec)
  if type(spec) ~= "string" or spec == "" then
    return nil
  end
  if spec:find("^%.") or spec:find("^/") or spec:find("^#") or spec:find("://") then
    return nil
  end

  local prefixed = spec:match("^node:(.+)$")
  local name = prefixed or spec
  local base = name:match("^([^/]+)") or name
  if NODE_PAGE[base] ~= nil and (prefixed or not PREFIX_ONLY[base]) then
    -- The subpath is kept (`fs/promises`, `stream/web`): M.url needs it to tell
    -- the one subpath with its own page from the many without.
    return { pkg = name, stdlib = true }
  end

  if name:sub(1, 1) == "@" then
    -- Two segments, both non-empty. `@/lib/metadata` fails the first `[^/]+` and
    -- comes back nil rather than as a package called `@`.
    local scoped = name:match("^(@[^/]+/[^/]+)")
    return scoped and { pkg = scoped } or nil
  end
  return { pkg = base }
end

--- The module specifier the cursor sits inside, or nil.
---
--- A quoted-span scan rather than a treesitter query: this has to answer for all
--- four filetypes whether or not a parser is attached, and the shape it looks
--- for — a string literal on a line that also carries an import keyword — is
--- identical in every one of them. The keyword gate is load-bearing: without it
--- `const brand = "react"` opens a package page.
---@param line string
---@param col integer 0-indexed cursor column
---@return string|nil
function M._specifier_at(line, col)
  if type(line) ~= "string" or type(col) ~= "number" then
    return nil
  end
  local in_import = false
  for _, pat in ipairs(IMPORT_CONTEXT) do
    if line:find(pat) then
      in_import = true
      break
    end
  end
  if not in_import then
    return nil
  end

  local init = 1
  while true do
    local s, e, _, body = line:find("(['\"`])([^'\"`]*)%1", init)
    if not s then
      return nil
    end
    -- Either quote counts as inside: parking on the closing quote and pressing
    -- the key is the same question as pressing it mid-string.
    if col + 1 >= s and col + 1 <= e then
      return body
    end
    init = e + 1
  end
end

--- Record every local name a clause binds, all pointing at `spec`.
---@param clause string
---@param spec string
---@param out table<string, string>
local function bind_clause(clause, spec, out)
  -- Aliases first, and they are removed as they are read, so the plain pass
  -- below cannot also bind the EXPORTED name: `{ readFile as rf }` binds `rf`
  -- only, and `* as fs` binds `fs` (its `*` is not a word char, hence the
  -- separate pattern).
  clause = clause:gsub("%*%s*as%s+([%w_%$]+)", function(alias)
    out[alias] = spec
    return " "
  end)
  clause = clause:gsub("[%w_%$]+%s+as%s+([%w_%$]+)", function(alias)
    out[alias] = spec
    return " "
  end)
  for word in clause:gmatch("[%a_%$][%w_%$]*") do
    if not NOT_A_BINDING[word] then
      out[word] = spec
    end
  end
end

--- Local name -> the specifier it was imported from, for a whole buffer's text.
---
--- Line-oriented with an explicit continuation, rather than one lazy pattern
--- over the joined text. The lazy version is shorter and wrong: a named-import
--- list wraps across lines, so its clause has to cross newlines, and then in a
--- file written without semicolons — which is most of the JS on this machine —
--- a `// import stuff` comment opens a clause that runs down to the next real
--- `from "pkg"` and binds every word in between to that package. Anchoring the
--- start at `^%s*import` and refusing to continue past a quote keeps a statement
--- inside its own statement.
---
--- One pass over the buffer per keypress, and only when the cursor was NOT on a
--- specifier — which is the common case, since answering for the identifier
--- itself is the whole point of this map.
---@param text string
---@return table<string, string>
function M._import_bindings(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  local pending = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local stmt = pending and (pending .. " " .. line) or (line:match("^%s*import%f[%W]") and line)
    pending = nil
    if stmt then
      local clause, _, spec = stmt:match("^%s*import%s*(.-)%s*from%s*(['\"])([^'\"]+)%2")
      if clause then
        bind_clause(clause, spec, out)
      elseif not stmt:find("['\"]") and #stmt < 500 then
        -- No specifier yet, and no string for the statement to have ended on: a
        -- named-import list still open across lines. A side-effect
        -- `import "./app.css"` carries its quote, so it never continues.
        pending = stmt
      end
    end
    -- The require() clause runs backwards to the previous `=`, and deliberately
    -- not across a newline: a `const a = b` on the line above would otherwise
    -- land `b` in this line's clause and bind it to this line's package.
    local rclause, _, rspec = line:match("([%w_%${},: \t]-)=%s*require%s*%(%s*(['\"])([^'\"]+)%2")
    if rclause then
      -- The clause keeps the declaration keyword and whatever literal preceded
      -- it; NOT_A_BINDING and bind_clause's leading-letter rule drop both.
      bind_clause(rclause, rspec, out)
    end
  end
  return out
end

--- Cursor -> package coordinates.
---
--- Two ways in, in this order:
---   1. the cursor is inside an import specifier — the package is right there;
---   2. the cursor is on an identifier some import bound, so the package is the
---      one that identifier came from.
---
--- (2) is what makes the mapping useful away from the top of the file, and it is
--- also why a coordinate carries `symbol`: this adapter has no per-symbol URL to
--- build, but the driver's search fallback is much better with the identifier
--- than with the bare package name.
---
--- A cursor on a relative import returns nil rather than falling through to (2):
--- the string under the cursor is unambiguous, and `gf` already opens that file.
---@param ctx DocCtx
---@return DocCoord|nil
function M.coord(ctx)
  if type(ctx) ~= "table" or not ctx.bufnr or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return nil
  end

  -- The contract hands over a buffer, not a position, so the cursor comes from
  -- the window — which is only the right cursor for the buffer displayed there.
  if ctx.bufnr == vim.api.nvim_get_current_buf() then
    local pos = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(ctx.bufnr, pos[1] - 1, pos[1], false)[1]
    local spec = line and M._specifier_at(line, pos[2])
    if spec then
      return M._specifier_coord(spec)
    end
  end

  -- `word` arrives with its dots (`fs.readFile`); the binding is the head.
  local head = type(ctx.word) == "string" and ctx.word:match("^[%a_%$][%w_%$]*") or nil
  if not head then
    return nil
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), "\n")
  local spec = M._import_bindings(text)[head]
  local coord = spec and M._specifier_coord(spec)
  if not coord then
    return nil
  end
  coord.symbol = ctx.word
  return coord
end

--- `homepage` of the INSTALLED copy of `pkg`, searched from `root` upward.
---
--- Which directory holds the install depends on the manager, so the walk cannot
--- be skipped: pnpm links only DIRECT dependencies into each package's own
--- node_modules (measured in expenses/packages/app: 20 direct deps linked, and
--- no `scheduler`, which react-dom pulls in), while npm hoists the whole tree
--- flat into the nearest install and workspace leaves often have no
--- node_modules at all.
---
--- The walk is bounded by the lockfile, and that bound is the point: above the
--- workspace lies ~/node_modules, someone else's install of a package that
--- happens to share a name.
---@param pkg string
---@param root string|nil
---@return string|nil
local function homepage_of(pkg, root)
  local dir = root
  while dir do
    local pm = M._package_manager(dir)
    if pm == "pnp" then
      return nil
    end
    local raw = state.read_file(vim.fs.joinpath(dir, "node_modules", pkg, "package.json"))
    if raw then
      local ok, data = pcall(vim.json.decode, raw)
      local home = ok and type(data) == "table" and data.homepage or nil
      -- Found the install; this is the answer either way. 137 of the 365
      -- installed packages sampled across ~/projects declare no homepage at all,
      -- so "keep climbing" would resolve that very common case to a DIFFERENT
      -- install of the same name one level up.
      return type(home) == "string" and home:match("^https?://") and home or nil
    end
    -- The lockfile marks the workspace root, so stop after checking it.
    if pm or vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) then
      return nil
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return nil
    end
    dir = parent
  end
  return nil
end

--- Coordinates -> a docs URL.
---
--- Pure but for one optional file read: given `ctx.root` it prefers the
--- installed package's own `homepage`, the only version-exact offline answer
--- available. With no root, no install, or a PnP tree it degrades to the npm
--- page — which is also exactly what a unit test with a fixture ctx sees.
---@param c DocCoord
---@param ctx DocCtx|nil
---@return string|nil
function M.url(c, ctx)
  if type(c) ~= "table" or type(c.pkg) ~= "string" or c.pkg == "" then
    return nil
  end

  if c.stdlib then
    -- Anchorless on purpose. Node's anchors are the whole signature with the
    -- punctuation deleted — fs.writeFile(file, data[, options], callback)
    -- becomes #fswritefilefile-data-options-callback — so an anchor built from
    -- `fs.writeFile` matches nothing and the browser silently shows the top of
    -- the page anyway. And unversioned on purpose: /api/ is the current release,
    -- while pinning the project's own Node would mean resolving a version, which
    -- this feature does not do anywhere.
    local page = NODE_PAGE[c.pkg]
    if page == nil then
      -- fs/promises, timers/promises, util/types, test/reporters: no page of
      -- their own, all documented inside the parent module's page (fs.html
      -- carries the entire "Promises API" section).
      page = NODE_PAGE[c.pkg:match("^([^/]+)") or ""]
    end
    return page and ("https://nodejs.org/api/" .. page .. ".html") or nil
  end

  -- The scope stays literal in both halves: node_modules/@types/node is a real
  -- nested directory, and npm's own URLs carry the `@` and the `/` unencoded.
  return homepage_of(c.pkg, ctx and ctx.root) or ("https://www.npmjs.com/package/" .. c.pkg)
end

--- Coordinates for the dependency named on `lines[lnum]`, or nil.
---
--- A line scan rather than a decode of the whole manifest: package.json is
--- routinely mid-edit (one unbalanced comma) exactly when you want to look a
--- dependency up, and vim.json.decode is all-or-nothing with no line numbers to
--- map back from anyway.
---
--- Which section the cursor is in is decided by walking up to the nearest
--- unclosed `"<key>": {`. The closing-brace counter is not decoration: a
--- top-level field written after the dependency block — `"packageManager":
--- "pnpm@9.15.4"`, which five projects here carry — has the dependency block's
--- opener above it and would otherwise be reported as a package.
---@param lines string[]
---@param lnum integer 1-indexed
---@return DocCoord|nil
function M._manifest_coord(lines, lnum)
  local line = type(lines) == "table" and lines[lnum] or nil
  if type(line) ~= "string" then
    return nil
  end
  local name = line:match('^%s*"([^"]+)"%s*:%s*"')
  if not name then
    return nil
  end
  local closed = 0
  for i = lnum - 1, 1, -1 do
    local above = lines[i] or ""
    if above:match("^%s*}") then
      closed = closed + 1
    else
      -- Only an opener that ends the line: a one-line `"scripts": { "dev": "x" }`
      -- is balanced and must not shift the count.
      local key = above:match('^%s*"([^"]+)"%s*:%s*{%s*$')
      if key then
        if closed == 0 then
          -- Named in a dependency map, so it is an npm package by definition —
          -- no builtin check here, unlike M._specifier_coord: a project that
          -- depends on the npm package `fs` writes exactly this line.
          return MANIFEST_SECTIONS[key] and { pkg = name } or nil
        end
        closed = closed - 1
      end
    end
  end
  return nil
end

--- Cursor on a package.json line naming a dependency.
---@param bufnr integer
---@param lnum integer 1-indexed
---@return DocCoord|nil
function M.manifest_line(bufnr, lnum)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return M._manifest_coord(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lnum)
end

--- The project's declared dependencies, for the picker.
---
--- The manifest and nothing else. `npm ls` is banned (see the header), and
--- reading each installed package.json for its resolved version would be one
--- file read per dependency — 200+ in a real project — to replace a range with a
--- number the picker does not need. `version` is therefore the range as written:
--- "^18.3.1", "workspace:*", "catalog:". That is what the file says and what the
--- reader edits.
---
--- Rows come back unsorted; config.docs.deps owns the ordering.
---@param ctx DocCtx
---@return table[]|nil
function M.deps(ctx)
  local root = type(ctx) == "table" and ctx.root or nil
  if not root then
    return nil
  end
  local raw = state.read_file(vim.fs.joinpath(root, "package.json"))
  if not raw then
    return nil
  end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end

  local rows = {}
  for _, section in ipairs(DEPS_SECTIONS) do
    local map = data[section.key]
    if type(map) == "table" then
      for name, range in pairs(map) do
        rows[#rows + 1] = {
          name = name,
          version = type(range) == "string" and range or nil,
          kind = section.kind,
        }
      end
    end
  end
  if #rows == 0 then
    return nil
  end
  return rows
end

return M
