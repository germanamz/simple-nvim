-- Name a Python symbol for config.docs.hover: which DevDocs Python bundle
-- documents it, and under what index name.
--
-- The gap this fills is narrow and specific. pyright's hover already carries a
-- docstring whenever there is Python source to read one from (`os.path.join`
-- shows posixpath.py's). What it cannot document is anything implemented in C
-- — `len`, `print`, `str.split`, `math.sqrt` — because typeshed's stubs have no
-- docstrings and there is no source behind them. So the gate is: pyright's
-- declaration lands in a typeshed *stdlib* stub.
--
-- The index names follow the Python docs: `len()`, `str.split()`,
-- `os.path.join()`, `sys.maxsize`. A stub gives the module and, through its
-- class nesting, the qualified name; the dotted name as written in the buffer
-- is the fallback for the handful of modules typeshed routes elsewhere
-- (`os.path` is declared in `posixpath.pyi`).
local M = {}

--- The server whose hover this provider completes.
M.server = "pyright"

--- The module a typeshed stdlib stub declares, or nil for any other file.
---@param path string|nil
---@return string|nil
function M._stub_module(path)
  if type(path) ~= "string" then
    return nil
  end
  local rest = path:match("/typeshed[^/]*/stdlib/(.+)%.pyi$")
  if not rest then
    return nil
  end
  rest = rest:gsub("/__init__$", "")
  return (rest:gsub("/", "."))
end

--- The qualified name declared at `range` in a stub: enclosing classes, outer
--- first, then the name itself.
---
--- An upward indentation scan rather than a parse. Stubs are formatted
--- consistently and carry no docstrings or multi-line strings, so the first
--- line above at a smaller indent is always the enclosing block: a `class`
--- names a scope, while an `if sys.version_info` only moves the threshold.
---@param lines string[]
---@param range { start: { line: integer, character: integer }, ["end"]: { character: integer } }
---@return string[]|nil
function M._qualname(lines, range)
  local row = range.start.line + 1
  local line = lines[row]
  if not line then
    return nil
  end
  local name = line:sub(range.start.character + 1, range["end"].character)
  if not name:match("^[%a_][%w_]*$") then
    return nil
  end
  local parts = { name }
  local indent = #line:match("^%s*")
  for i = row - 1, 1, -1 do
    if indent == 0 then
      break
    end
    local above = lines[i]
    if above:match("%S") and not above:match("^%s*[#@]") then
      local depth = #above:match("^%s*")
      if depth < indent then
        local class = above:match("^%s*class%s+([%a_][%w_]*)")
        if class then
          table.insert(parts, 1, class)
        end
        indent = depth
      end
    end
  end
  return parts
end

--- Index names to try, in order, each as a callable and then as an attribute.
---@param module string
---@param parts string[]
---@param dotted string|nil
---@return string[]
function M._names(module, parts, dotted)
  local out, seen = {}, {}
  local function add(base)
    for _, name in ipairs({ base .. "()", base }) do
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  local qualified = table.concat(parts, ".")
  add(module == "builtins" and qualified or (module .. "." .. qualified))
  if type(dotted) == "string" and dotted:match("^[%a_][%w_%.]*$") then
    add(dotted)
  end
  return out
end

--- The Python bundle to read: the project's version if installed, else the
--- nearest installed one (the newer on a tie), else the exact slug, so the
--- install hint names the version the project actually runs.
---@param want string|nil  -- "3.12"
---@param installed string[]
---@return string|nil
function M._pick_slug(want, installed)
  local function number(major, minor)
    return tonumber(major) * 1000 + tonumber(minor)
  end
  local wmajor, wminor = (want or ""):match("^(%d+)%.(%d+)")
  local target = wmajor and number(wmajor, wminor)

  local best, best_dist, best_version
  for _, slug in ipairs(installed) do
    local major, minor = slug:match("^python~(%d+)%.(%d+)$")
    if major then
      local version = number(major, minor)
      local dist = target and math.abs(version - target) or 0
      if not best or dist < best_dist or (dist == best_dist and version > best_version) then
        best, best_dist, best_version = slug, dist, version
      end
    end
  end
  if best then
    return best
  end
  return wmajor and ("python~" .. wmajor .. "." .. wminor) or nil
end

-- interpreter path -> "3.12", or false when it could not be asked.
---@type table<string, string|false>
local versions = {}

--- Ask an interpreter its version, once per session.
---@param exe string|nil
---@param cb fun(version: string|nil)
function M._version(exe, cb)
  if not exe then
    return cb(nil)
  end
  if versions[exe] ~= nil then
    return cb(versions[exe] or nil)
  end
  local cmd = { exe, "-c", "import sys; print('%d.%d' % sys.version_info[:2])" }
  local ok = pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(res)
    local version = res.code == 0 and vim.trim(res.stdout or ""):match("^(%d+%.%d+)$") or nil
    versions[exe] = version or false
    vim.schedule(function()
      cb(version)
    end)
  end)
  if not ok then
    versions[exe] = false
    cb(nil)
  end
end

---@param ctx { bufnr: integer, client: vim.lsp.Client, params: table, dotted: string }
---@param cb fun(candidates: table[]|nil)
function M.candidates(ctx, cb)
  local sent = ctx.client:request("textDocument/declaration", ctx.params, function(err, result)
    if err or type(result) ~= "table" then
      return cb(nil)
    end
    -- Location | Location[] | LocationLink[]
    local loc = (result.uri or result.targetUri) and result or result[1]
    local uri = type(loc) == "table" and (loc.uri or loc.targetUri)
    local range = type(loc) == "table" and (loc.targetSelectionRange or loc.range)
    local path = type(uri) == "string" and vim.uri_to_fname(uri)
    local module = M._stub_module(path or nil)
    if not module or type(range) ~= "table" then
      return cb(nil)
    end
    local read, lines = pcall(vim.fn.readfile, path)
    local parts = read and M._qualname(lines, range)
    if not parts then
      return cb(nil)
    end

    local names = M._names(module, parts, ctx.dotted)
    local adapter = require("config.docs.adapters.python")
    local exe = adapter._interpreter({
      bufnr = ctx.bufnr,
      root = vim.fs.root(ctx.bufnr, adapter.manifest),
    })
    M._version(exe, function(version)
      local slug = M._pick_slug(version, require("config.docs.devdocs").installed_slugs())
      if not slug then
        return cb(nil)
      end
      cb(vim.tbl_map(function(name)
        return { slug = slug, name = name }
      end, names))
    end)
  end, ctx.bufnr)
  if not sent then
    cb(nil)
  end
end

return M
