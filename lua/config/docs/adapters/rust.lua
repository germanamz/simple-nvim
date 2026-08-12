-- Rust: docs.rs, and deliberately nothing cleverer than that.
--
-- Symbols are not this adapter's business. rust-analyzer answers
-- experimental/externalDocs (config.docs.resolve) and it is the only thing that
-- can: it prefers a crate's own #![doc(html_root_url)] over docs.rs, and it
-- resolves re-exports to the DEFINING crate — `serde::Serialize` documents under
-- serde_core, which no amount of manifest reading could discover (`cargo
-- metadata` reports the serde → serde_core dependency edge, never which crate a
-- re-exported item was defined in). So `coord` answers at crate granularity
-- only, and only once the server has already declined.
--
-- The docs.rs URL carries two crate-shaped segments and they are NOT the same
-- string. Verified against the live site:
--
--   https://docs.rs/unicode-width/latest/unicode_width/   200
--   https://docs.rs/unicode-width/latest/unicode-width/   404
--   https://docs.rs/unicode_width/latest/unicode_width/   200, canonicalized to
--                                                         the hyphenated crate
--
-- Segment 1 is the published crate name; the last segment is the lib target's
-- module path, which is the crate name with `-` turned into `_`. docs.rs
-- normalizes hyphen and underscore in the crate segment but NOT in the module
-- segment, so the underscoring is the load-bearing half. A crate that overrides
-- `[lib] name` to something other than its own package name would 404 here; the
-- recovery is https://docs.rs/<crate>/latest/ with no module segment, which
-- always redirects to the real lib. Cargo writes an explicit `[lib] name` into
-- the manifest it publishes, so the rule is checkable: all 26 of the crates in
-- this machine's registry cache that declare one obey it, which is what makes
-- the deep link worth the rare miss.
--
-- No `cmd`. `cargo doc` builds the entire dependency graph before it renders a
-- byte, which is minutes on a cold target dir and therefore not a keypress. The
-- local-docs win arrives from the other side anyway: rust_analyzer runs with
-- experimental.localDocs (lua/plugins/lsp.lua) and returns a file:// path once
-- `cargo doc` HAS been run, which resolve.lua stats before preferring it.
local state = require("util.state")

local M = {}

-- "toml" is claimed because Cargo.toml has no filetype of its own, and a cursor
-- on a dependency line there is the one case `manifest_line` exists for.
-- config.docs.BY_FT must route toml here for that to fire; both entry points a
-- toml buffer can reach refuse a file not named Cargo.toml, so the route costs
-- pyproject.toml and friends nothing.
M.ft = { "rust", "toml" }

M.manifest = "Cargo.toml"

-- Cargo's dependency tables, mapped to the `kind` reported by `deps` —
-- "direct" matching the go/js/python adapters, since config.docs.deps only
-- distinguishes "indirect" and Cargo.toml declares nothing indirect. The
-- underscore spellings are deprecated but still live: cargo 1.96 accepts
-- `[dev_dependencies]` / `[build_dependencies]` and reports them as dev/build
-- kinds (checked with `cargo metadata --no-deps --offline`), so a manifest in
-- the wild can be spelled either way.
local DEP_TABLES = {
  ["dependencies"] = "direct",
  ["dev-dependencies"] = "dev",
  ["dev_dependencies"] = "dev",
  ["build-dependencies"] = "build",
  ["build_dependencies"] = "build",
}

-- The sysroot crates: no manifest entry to match them against, and they live on
-- doc.rust-lang.org rather than docs.rs.
local SYSROOT = { std = true, core = true, alloc = true, proc_macro = true }

--- crates.io's name alphabet. Doubles as the gate that keeps a mis-sliced line
--- out of a URL: parsing a multi-line inline table can hand us a "key" like
--- `], version`, and that must never reach the browser.
---@param name string|nil
---@return boolean
local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil
end

--- Crate name -> the module path rustdoc publishes it under.
---@param name string
---@return string
local function module_path(name)
  return (name:gsub("%-", "_"))
end

--- The basename of `bufnr`'s file, or nil when it has none.
---
--- nil means a scratch or fixture buffer, which the guards below let through:
--- the unit tests drive these functions from buffers that have no file behind
--- them, and refusing those would make the adapter untestable.
---@param bufnr integer|nil
---@return string|nil
local function buf_basename(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local fname = vim.api.nvim_buf_get_name(bufnr)
  return fname ~= "" and vim.fs.basename(fname) or nil
end

--- Split a TOML dotted path on its unquoted dots, dropping the quotes and any
--- whitespace around each segment.
---
--- A plain `vim.split(s, ".")` shreds the one segment that matters: a target
--- section's middle key is an arbitrary quoted string, as in
--- `[target.'cfg(not(target_os = "macos"))'.dependencies]` (alacritty quotes
--- with `'`, cargo's own published manifests with `"`). Same routine serves
--- dotted KEYS, because `libc.version = "0.2"` is a legal dependency spelling.
---@param s string
---@return string[]
local function split_path(s)
  local parts, buf, quote = {}, {}, nil
  for i = 1, #s do
    local ch = s:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      else
        buf[#buf + 1] = ch
      end
    elseif ch == "'" or ch == '"' then
      quote = ch
    elseif ch == "." then
      parts[#parts + 1] = vim.trim(table.concat(buf))
      buf = {}
    else
      buf[#buf + 1] = ch
    end
  end
  parts[#parts + 1] = vim.trim(table.concat(buf))
  return parts
end

--- The section path of a TOML table header, or nil when the line is not one.
---
--- `[[bin]]`-style array-of-tables headers are matched too, and that is not
--- cosmetic: if they went unrecognized, a `[[bin]]`'s `name = "x"` following a
--- `[dependencies]` block would still be attributed to the dependency section
--- and read as a crate. Neither pattern is anchored at end-of-line, so a
--- trailing comment is tolerated; that costs nothing because no cfg expression
--- or target triple contains a `]`.
---@param line string
---@return string[]|nil
local function header_path(line)
  local inner = line:match("^%s*%[%[(.-)%]%]") or line:match("^%s*%[(.-)%]")
  return inner and split_path(inner) or nil
end

--- What kind of section is this, and does the header itself name a single
--- dependency (`[dependencies.foo]`)?
---
--- Anchored at segment 1 rather than pattern-matching the tail, because Poetry's
--- `[tool.poetry.dependencies]` also ends in "dependencies" and this adapter
--- claims the toml filetype. Returns the `deps` kind, or "patch" for the
--- override tables — whose keys are real crate names, so they are worth a docs
--- link, but are not dependencies of anything and never enter `deps`.
---
--- `[replace]` is deliberately absent: its keys carry a `:version` suffix
--- (`"foo:1.2.3" = { … }`), so they are not bare crate names.
---@param segs string[]
---@return string|nil kind
---@return string|nil single
local function section_role(segs)
  local n, head = #segs, segs[1]
  if not head then
    return nil
  end
  if head == "patch" and (n == 2 or n == 3) then
    return "patch", segs[3]
  end
  local at
  if DEP_TABLES[head] then
    at = 1
  elseif head == "target" and n >= 3 then
    at = 3
  elseif head == "workspace" and n >= 2 then
    at = 2
  end
  local kind = at and DEP_TABLES[segs[at]]
  if not kind or n > at + 1 then
    return nil
  end
  -- `[workspace.dependencies]` declares versions for members to inherit, not
  -- dependencies of the root package itself.
  return head == "workspace" and "workspace" or kind, segs[at + 1]
end

--- The key path and raw value text of a `key = value` line, or nil for blanks,
--- comments and continuation lines. The crate is always key path segment 1:
--- `libc.version = "0.2"` and `ffi.package = "cc"` are both legal, and cargo
--- resolves them to libc and to cc-renamed-ffi respectively (verified with
--- `cargo metadata --no-deps --offline`).
---@param line string
---@return string[]|nil key
---@return string|nil value
local function split_kv(line)
  if line:match("^%s*#") then
    return nil
  end
  local key, value = line:match("^([^=]+)=(.*)$")
  if not key then
    return nil
  end
  return split_path(key), value
end

--- The first quoted string of a value, i.e. the whole value of `foo = "1.0"`.
---@param value string
---@return string|nil
local function first_string(value)
  return value:match('^%s*"([^"]*)"') or value:match("^%s*'([^']*)'")
end

--- Read one field out of an inline table value. The leading class keeps
--- `features = ["…"]` and friends from matching a field name mid-word, and
--- covers both `{ version = "1" }` and `{version="1"}`.
---@param value string
---@param field string
---@return string|nil
local function inline_field(value, field)
  return value:match("[{,%s]" .. field .. '%s*=%s*"([^"]*)"')
    or value:match("[{,%s]" .. field .. "%s*=%s*'([^']*)'")
end

--- Fold one dependency line into `entry`, which may already hold fields set by
--- an earlier dotted-key line for the same crate.
---
--- `package = "…"` is the rename: `ffi = { package = "libc" }` is imported as
--- `ffi::` but documented as libc, so the alias and the published name are kept
--- apart — every URL below is built from the name, never the alias.
---@param entry table
---@param key string[]
---@param value string
local function absorb(entry, key, value)
  if #key == 1 then
    local bare = first_string(value)
    if bare then
      entry.version = bare
      return
    end
    entry.name = inline_field(value, "package") or entry.name
    entry.version = inline_field(value, "version") or entry.version
    entry.ws = entry.ws or value:match("[{,%s]workspace%s*=%s*true") ~= nil
  elseif key[2] == "package" then
    entry.name = first_string(value) or entry.name
  elseif key[2] == "version" then
    entry.version = first_string(value) or entry.version
  elseif key[2] == "workspace" then
    entry.ws = entry.ws or value:match("^%s*true") ~= nil
  end
end

--- Parse a Cargo.toml into its dependency entries.
---
--- Entries carry `alias` (the key, which is what the source code imports) and
--- `name` (the published crate, which is what docs.rs serves); they differ only
--- for a renamed dependency. `ws` marks `workspace = true` inheritance, whose
--- version lives in another file — see `workspace_table`.
---@param lines string[]
---@return { entries: table[], workspace: table<string, table>, is_workspace: boolean }
local function parse_manifest(lines)
  local out = { entries = {}, workspace = {}, is_workspace = false }
  local kind, single, index = nil, nil, {}
  for _, line in ipairs(lines) do
    local segs = header_path(line)
    if segs then
      out.is_workspace = out.is_workspace or segs[1] == "workspace"
      kind, single = section_role(segs)
      index = {}
      if kind and single and valid_name(single) then
        -- `[dependencies.foo]` — cargo's own published manifests use this form
        -- almost exclusively. Every key below it belongs to foo, so `version`
        -- must not be mistaken for a crate of its own.
        local entry = { alias = single, name = single, kind = kind }
        index[single] = entry
        out.entries[#out.entries + 1] = entry
      end
    elseif kind then
      local key, value = split_kv(line)
      local alias = single or (key and key[1])
      if key and valid_name(alias) then
        local entry = index[alias]
        if not entry then
          entry = { alias = alias, name = alias, kind = kind }
          index[alias] = entry
          out.entries[#out.entries + 1] = entry
        end
        -- Inside `[dependencies.foo]` the key path is the field itself
        -- (`package = "…"`), so shift it into the dotted-key shape absorb wants.
        absorb(entry, single and { alias, key[1] } or key, value)
      end
    end
  end
  for _, entry in ipairs(out.entries) do
    if entry.kind == "workspace" then
      out.workspace[entry.alias] = entry
    end
  end
  return out
end

--- Slurp `path` into lines, or nil when it cannot be read.
---@param path string
---@return string[]|nil
local function read_lines(path)
  local raw = state.read_file(path)
  return raw and vim.split(raw, "\n", { plain = true }) or nil
end

--- The `[workspace.dependencies]` table governing `root`, for resolving the
--- `foo.workspace = true` entries a member manifest is full of.
---
--- Walks up exactly as cargo does when it looks for the workspace root, and
--- stops at the first ancestor manifest that declares `[workspace]`. Membership
--- is not verified (cargo checks the members list, and honors an explicit
--- `package.workspace = "path"`), so a crate nested under an unrelated workspace
--- could pick up a version string that is not the one cargo would use — a
--- cosmetic column in a picker, traded against reading more manifests.
---@param root string
---@return table<string, table>
local function workspace_table(root)
  for dir in vim.fs.parents(vim.fs.joinpath(root, "Cargo.toml")) do
    if dir ~= root then
      local lines = read_lines(vim.fs.joinpath(dir, "Cargo.toml"))
      if lines then
        local parsed = parse_manifest(lines)
        if parsed.is_workspace then
          return parsed.workspace
        end
      end
    end
  end
  return {}
end

--- The rename declared for `alias` in the section opened at `head`, or for the
--- section itself when `alias` is nil (`[dependencies.foo]` … `package = "…"`).
---
--- Scanned from the header rather than from the cursor because a dependency
--- spelled in dotted keys is spread over several lines — `ffi.package = "cc"`
--- can sit below `ffi.version`, and the crate the cursor is on is cc either way.
---@param lines string[]
---@param head integer line of the section header
---@param alias string|nil
---@return string|nil
local function section_package(lines, head, alias)
  for i = head + 1, #lines do
    if header_path(lines[i]) then
      return nil
    end
    local key, value = split_kv(lines[i])
    local field
    if key and alias then
      field = key[1] == alias and key[2] or nil
    elseif key then
      field = #key == 1 and key[1] or nil
    end
    if field == "package" then
      return first_string(value)
    end
  end
  return nil
end

--- The crate the cursor is sitting on in a Cargo.toml.
---
--- Answers for a dependency line in any of cargo's spellings (`foo = "1"`,
--- `foo = { … }`, `foo.workspace = true`, and every line inside a
--- `[dependencies.foo]` table, including the header line itself), under any
--- dependency section — plain, dev, build, per-target and workspace.
---
--- A path-only dependency on an unpublished crate gets a docs.rs URL that will
--- 404. Knowing better would take a network round trip, which this keypress path
--- does not get to make.
---@param bufnr integer
---@param lnum integer 1-indexed, as cursor positions come
---@return DocCoord|nil
function M.manifest_line(bufnr, lnum)
  -- config.docs routes by filetype and Cargo.toml has no filetype of its own,
  -- so this is reached for every .toml in the tree. Only ours has crate names
  -- in it.
  local basename = buf_basename(bufnr)
  if basename and basename ~= "Cargo.toml" then
    return nil
  end
  -- buf_basename returns nil for an invalid buffer rather than throwing, so the
  -- guard above lets a dead bufnr through to here; get_lines would then raise.
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not lines[lnum] then
    return nil
  end

  -- Cursor on the header itself: `[dependencies.foo]` names foo directly.
  local segs = header_path(lines[lnum])
  if segs then
    local kind, single = section_role(segs)
    if not kind or not valid_name(single) then
      return nil
    end
    return { pkg = section_package(lines, lnum, nil) or single }
  end

  local head = lnum
  while head > 0 and not header_path(lines[head]) do
    head = head - 1
  end
  if head == 0 then
    return nil
  end
  local kind, single = section_role(header_path(lines[head]))
  if not kind then
    return nil
  end
  if single then
    return valid_name(single) and { pkg = section_package(lines, head, nil) or single } or nil
  end

  local key, value = split_kv(lines[lnum])
  if not key or not valid_name(key[1]) then
    return nil
  end
  local entry = { alias = key[1], name = key[1] }
  absorb(entry, key, value)
  if entry.name == entry.alias then
    entry.name = section_package(lines, head, entry.alias) or entry.name
  end
  return valid_name(entry.name) and { pkg = entry.name } or nil
end

--- Crate coordinates for the identifier under the cursor.
---
--- Only two things are knowable without the language server: the sysroot crates,
--- and an identifier that is literally one of this crate's declared
--- dependencies. `use unicode_width::…` is matched against the alias
--- `unicode-width` through the same `-` → `_` rule the URL uses, since source
--- spells the module path and the manifest spells the published name.
---
--- Anything else returns nil on purpose. Treating an unrecognized word as a
--- crate would send `let mut buffer` to docs.rs/buffer; the driver's search
--- fallback is the honest answer there.
---@param ctx DocCtx
---@return DocCoord|nil
function M.coord(ctx)
  local word = ctx and ctx.word
  if type(word) ~= "string" or word == "" then
    return nil
  end
  -- A dotted word in Rust is field or method access on a value, never a path:
  -- paths separate with `::`. The head of such a chain is a binding, so there is
  -- no crate anywhere in it.
  if word:find(".", 1, true) then
    return nil
  end
  -- Claiming the toml filetype means a pyproject.toml or a netlify.toml can
  -- land here too. Its keys are not crates, and a polyglot repo can easily have
  -- a Cargo.toml further up the tree for them to be matched against — `toml`
  -- and `regex` are package names in both ecosystems.
  local basename = buf_basename(ctx.bufnr)
  if basename and basename ~= "Cargo.toml" and basename:sub(-5) == ".toml" then
    return nil
  end
  if SYSROOT[word] then
    return { pkg = word, stdlib = true }
  end
  if not ctx.root then
    return nil
  end
  -- Re-read per press rather than cache: a Cargo.toml is a couple of KB, and a
  -- cache here would have to invalidate on every manifest edit to stay honest.
  local lines = read_lines(vim.fs.joinpath(ctx.root, "Cargo.toml"))
  if not lines then
    return nil
  end
  for _, entry in ipairs(parse_manifest(lines).entries) do
    if entry.alias == word or module_path(entry.alias) == word then
      return { pkg = entry.name }
    end
  end
  return nil
end

--- The version path segment for a docs.rs URL.
---
--- Cargo.toml states a REQUIREMENT, not a version, so `^1.0` and `~1.2.3` are
--- the normal shapes. docs.rs resolves a bare requirement in that slot
--- (`docs.rs/serde/1.0/serde/` answers 200), so the operator is stripped and the
--- remainder passed through — no lockfile is read and nothing is resolved here.
--- Anything that is not a plain dotted version after stripping (a comma-joined
--- range like `>=1.0, <2.0`, a git or path dependency) falls back to `latest`
--- rather than building a URL out of a shape docs.rs was never asked about.
---@param version string|nil
---@return string
function M._version_segment(version)
  if type(version) ~= "string" then
    return "latest"
  end
  local bare = version:gsub("^%s*[%^~=]%s*", ""):gsub("%s+$", "")
  if bare:match("^%d+[%d%.]*$") or bare:match("^%d+[%d%.]*%-[%w%.%-]+$") then
    return bare
  end
  return "latest"
end

--- Coordinates to a documentation URL.
---
--- `c.symbol` is ignored even when set: reconstructing an item's rustdoc path
--- from a name is exactly the guesswork rust-analyzer exists to replace here
--- (re-exports, `#![doc(html_root_url)]`), and a wrong deep link is worse than a
--- right crate root.
---@param c DocCoord
---@param _ctx DocCtx|nil unused — a crate URL needs no buffer context
---@return string|nil
function M.url(c, _ctx)
  if type(c) ~= "table" then
    return nil
  end
  local pkg = c.pkg
  if c.stdlib then
    pkg = pkg or "std"
    return valid_name(pkg) and ("https://doc.rust-lang.org/stable/" .. module_path(pkg) .. "/")
      or nil
  end
  if not valid_name(pkg) then
    return nil
  end
  return string.format(
    "https://docs.rs/%s/%s/%s/",
    pkg,
    M._version_segment(c.version),
    module_path(pkg)
  )
end

--- This crate's declared dependencies, straight out of Cargo.toml.
---
--- Manifest text only. `cargo metadata` would resolve the graph, which means a
--- registry it may have to fetch and a lock it may have to write — neither is
--- available to a picker that must open instantly and offline.
---
--- `name` is the published crate (a rename resolves to the real one, so the
--- picker's docs link lands), `version` is the requirement as declared — never
--- a resolved version, which would take the lockfile this deliberately does not
--- read — and `kind` is "direct" | "dev" | "build" | "workspace". A crate listed
--- in two sections appears once per section, which is what the manifest says.
---
--- Rows come back in manifest order; config.docs.deps owns the sorting.
---@param ctx DocCtx
---@return table[]|nil
function M.deps(ctx)
  local root = ctx and ctx.root
  if not root then
    return nil
  end
  local lines = read_lines(vim.fs.joinpath(root, "Cargo.toml"))
  if not lines then
    return nil
  end
  local parsed = parse_manifest(lines)

  -- Only pay for the upward walk when something actually inherits.
  local inherited = nil
  local function workspace_entry(alias)
    if next(parsed.workspace) then
      return parsed.workspace[alias]
    end
    inherited = inherited or workspace_table(root)
    return inherited[alias]
  end

  local out, seen = {}, {}
  local function emit(entry)
    local key = entry.name .. "\0" .. entry.kind
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = { name = entry.name, version = entry.version, kind = entry.kind }
    end
  end

  for _, entry in ipairs(parsed.entries) do
    if entry.kind ~= "patch" and entry.kind ~= "workspace" then
      if entry.ws then
        local ws = workspace_entry(entry.alias)
        if ws then
          entry.name = ws.name
          entry.version = ws.version
        end
      end
      emit(entry)
    end
  end
  -- A root manifest's own `[workspace.dependencies]` rows, minus any the root
  -- package also depends on directly (a single-crate workspace declares both).
  for _, entry in ipairs(parsed.entries) do
    if entry.kind == "workspace" and not seen[entry.name .. "\0direct"] then
      emit(entry)
    end
  end
  return #out > 0 and out or nil
end

return M
