-- Where do the docs for the resource block under the cursor live?
--
-- terraform-ls is already attached to these buffers, and it still cannot answer
-- this. The only registry URLs in the server binary are
-- `registry.terraform.io/providers/%s/%s/%s/docs` and `.../providers/%s/latest`
-- (both the provider INDEX, never a per-resource page), so hover and
-- documentLink fall through to nothing useful and the URL has to be built here.
--
-- The slug rule
-- -------------
-- A registry doc page is
-- /providers/<namespace>/<name>/<version>/docs/<category>/<slug>, where
-- <category> is literally "resources" or "data-sources" — the same two strings
-- the registry's own v2/provider-docs API reports — and <slug> is the resource
-- type with its provider prefix stripped: aws_s3_bucket -> s3_bucket.
--
-- That rule was measured, not assumed. Of the 1626 resource types in
-- hashicorp/aws 6.38.0's schema (`terraform providers schema -json`, run
-- offline against the copy already in .terraform), 1620 have a doc slug exactly
-- equal to the stripped name, and there are zero doc slugs that are not one of
-- them. Data sources land the same way: 645 of 648. Every miss is aws_alb* /
-- aws_alb_listener*, the legacy aliases of aws_lb*, which the registry really
-- does not document — so returning nil for those is the correct answer rather
-- than a gap to paper over, and the driver's search fallback handles them.
--
-- The prefix is a LOCAL NAME, not the provider's name
-- ---------------------------------------------------
-- The prefix stripped above is the provider's *local name* — the key in
-- required_providers — which is only conventionally equal to the registry name.
-- Two consequences, both real:
--
--   * The namespace can never be guessed from the prefix. github_* resources
--     are documented under integrations/github, not github/github, and
--     docker_* under kreuzwerker/docker. So the prefix buys the slug and
--     nothing else; the namespace comes from required_providers, then the
--     lockfile, then Terraform's own documented implied address.
--   * hashicorp/google-beta declares local name `google`, so google_* types
--     resolve to whichever of google / google-beta the config actually
--     declares. Both providers document the same type, so either page answers
--     the question; there is nothing to disambiguate and nothing to fix.
--
-- No version resolution
-- ---------------------
-- The version segment is always "latest", never the pin sitting in the
-- lockfile. The registry accepts `latest` in that slot (it is the form
-- terraform-ls itself emits), so reading a version would buy a cosmetically
-- more precise URL and a second way to be wrong when .terraform.lock.hcl has
-- drifted from .terraform — which it already has in one repo on this machine,
-- where the lockfile lists only hashicorp/aws while .terraform still holds
-- kreuzwerker/docker from an older init. The lockfile is read for identity
-- (namespace) and, in `deps`, for display. Never to build a path segment.
--
-- Builtins are not registry providers
-- -----------------------------------
-- terraform_data and terraform_remote_state come from the built-in provider
-- terraform.io/builtin/terraform, have no namespace, appear in no lockfile, and
-- are documented on developer.hashicorp.com under paths that share no shape
-- with the registry's. They are routed as `stdlib` for exactly that reason. Any
-- other terraform_* type resolves to nil rather than to a fabricated path.

local M = {}

M.ft = { "terraform" }
M.manifest = ".terraform.lock.hcl"

local REGISTRY = "https://registry.terraform.io/providers/"

-- The built-in provider's two documented types. Hand-mapped because these pages
-- are hand-written prose in the language manual, not generated per-resource
-- pages: the paths are unrelated to each other and to the type names, so there
-- is no rule here to derive, only a table to keep honest.
local BUILTIN = {
  terraform_data = "https://developer.hashicorp.com/terraform/language/resources/terraform-data",
  terraform_remote_state = "https://developer.hashicorp.com/terraform/language/state/remote-state-data",
}

-- Block kinds worth walking up to. Nested blocks (`endpoints {}` inside a
-- provider, `lifecycle {}` inside a resource) are stepped over rather than
-- matched, so the cursor can sit anywhere inside a block and still resolve.
local ADDRESSABLE = {
  resource = "resources",
  data = "data-sources",
  provider = false, -- provider blocks address the docs index, with no category
}

--- Split a resource/data type into its provider local name and its doc slug.
---
--- Types are always <local_name>_<rest>; a type with no underscore has no slug
--- to speak of and yields nil rather than an empty trailing path segment.
---@param tf_type string  e.g. "aws_s3_bucket"
---@return string|nil local_name, string|nil slug
function M._split_type(tf_type)
  if type(tf_type) ~= "string" then
    return nil, nil
  end
  local name, slug = tf_type:match("^([%a][%w%-]*)_(.+)$")
  if not name or slug == "" then
    return nil, nil
  end
  return name, slug
end

--- Normalize a provider source address to the "<namespace>/<name>" the registry
--- URL wants.
---
--- Addresses are [<HOSTNAME>/]<NAMESPACE>/<TYPE>. A two-part address is
--- implicitly public. A three-part one names its host explicitly, and if that
--- host is not the public registry — a private Terraform Enterprise mirror, say
--- — then registry.terraform.io has no page for it at all and guessing one
--- would send the browser somewhere actively misleading.
---@param source string
---@return string|nil
function M._normalize_source(source)
  if type(source) ~= "string" or source == "" then
    return nil
  end
  local parts = vim.split(source, "/", { plain = true })
  if #parts == 2 then
    return source
  end
  if #parts == 3 then
    if parts[1] ~= "registry.terraform.io" then
      return nil
    end
    return parts[2] .. "/" .. parts[3]
  end
  return nil
end

--- local name -> source address, read from a .tf source's required_providers.
---
--- Scoped to the required_providers block before looking for `source`, because
--- a bare scan would also collect `module "x" { source = "./s3" }` — a
--- filesystem path, not a provider address, and the corpus this was written
--- against is full of them.
---
--- %b{} rather than a hand-rolled brace counter: it balances the interpolation
--- braces in a `"${var.x}"` value for free.
---@param src string
---@return table<string, string>
function M._required_providers(src)
  local out = {}
  if type(src) ~= "string" then
    return out
  end
  local block = src:match("required_providers%s*(%b{})")
  if not block then
    return out
  end
  for name, obj in block:gmatch("([%a][%w_%-]*)%s*=%s*(%b{})") do
    local source = obj:match('source%s*=%s*"([^"]+)"')
    if source then
      out[name] = source
    end
  end
  return out
end

--- Provider address -> version, read from a .terraform.lock.hcl source.
---
--- The `hashes = [...]` list is bracketed, not braced, so %b{} still lands on
--- the provider block's own extent.
---@param src string
---@return table<string, string>
function M._lock_providers(src)
  local out = {}
  if type(src) ~= "string" then
    return out
  end
  for addr, body in src:gmatch('provider%s+"([^"]+)"%s*(%b{})') do
    out[addr] = body:match('version%s*=%s*"([^"]+)"') or ""
  end
  return out
end

--- Read a file, preferring a loaded buffer's contents so unsaved edits to a
--- required_providers block still resolve.
---@param path string
---@return string|nil
local function read_source(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

--- Resolve a provider local name to "<namespace>/<name>".
---
--- Three sources, most specific first:
---
---   1. required_providers in the buffer's OWN directory. A Terraform module is
---      a directory, so that is the scope the declaration actually governs —
---      and it is the only source that is right for a shared module vendored
---      under a root that pins something else.
---   2. The lockfile at ctx.root, matched on the address's type segment. This
---      is what rescues integrations/github and kreuzwerker/docker in the very
---      common case of a module directory with no required_providers of its own
---      (all four modules in the corpus this was built against are like that).
---   3. Terraform's documented implied address, registry.terraform.io/hashicorp/
---      <LOCAL NAME>, used when a provider is required without a source. It is
---      the language's own rule, not a guess of ours.
---@param local_name string
---@param ctx table
---@return string|nil
local function resolve_source(local_name, ctx)
  -- Guard on the buffer NAME, not on the dirname derived from it: fnamemodify
  -- turns "" into ".", so an unnamed buffer used to glob Neovim's cwd and pick
  -- up whatever providers.tf happened to be sitting there — a scratch buffer
  -- could resolve to a namespace no file in the project ever declared.
  local bufname = vim.api.nvim_buf_is_valid(ctx.bufnr) and vim.api.nvim_buf_get_name(ctx.bufnr)
    or ""
  if bufname ~= "" then
    local dir = vim.fn.fnamemodify(bufname, ":h")
    for _, path in ipairs(vim.fn.glob(dir .. "/*.tf", false, true)) do
      local src = read_source(path)
      local declared = src and M._required_providers(src)[local_name]
      if declared then
        return M._normalize_source(declared)
      end
    end
  end

  if ctx.root then
    local lock = read_source(ctx.root .. "/" .. M.manifest)
    if lock then
      for addr in pairs(M._lock_providers(lock)) do
        -- Match on the address's trailing type segment: the lockfile records
        -- no local names, and outside google-beta the two are the same string.
        if addr:match("([^/]+)$") == local_name then
          return M._normalize_source(addr)
        end
      end
    end
  end

  return "hashicorp/" .. local_name
end

--- The innermost resource/data/provider block containing the cursor.
---@param bufnr integer
---@return string|nil kind, string|nil label
local function enclosing_block(bufnr)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, lang = "terraform" })
  if not ok or not node then
    return nil, nil
  end
  while node do
    if node:type() == "block" then
      local id = node:child(0)
      local kind = id and id:type() == "identifier" and vim.treesitter.get_node_text(id, bufnr)
        or nil
      if kind and ADDRESSABLE[kind] ~= nil then
        -- The first string_lit is the addressing label: the type for
        -- resource/data, the local name for provider.
        for child in node:iter_children() do
          if child:type() == "string_lit" then
            -- Parenthesized so gsub's replacement count does not leak out as a
            -- third return value onto callers that destructure two.
            return kind, (vim.treesitter.get_node_text(child, bufnr):gsub('"', ""))
          end
        end
        return nil, nil
      end
    end
    node = node:parent()
  end
  return nil, nil
end

--- Fallback block scan for when no terraform parser is available.
---
--- Bounded by a closing brace in column 0: under `terraform fmt` that can only
--- be the end of a top-level block, so the scan cannot walk backwards out of
--- the cursor's own block and report the previous one.
---@param bufnr integer
---@param lnum integer  1-indexed
---@return string|nil kind, string|nil label
local function scan_block(bufnr, lnum)
  for i = lnum, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if not line then
      break
    end
    local kind, label = line:match('^(%a+)%s+"([^"]+)"')
    if kind and ADDRESSABLE[kind] ~= nil then
      return kind, label
    end
    if i < lnum and line:match("^}") then
      return nil, nil
    end
  end
  return nil, nil
end

--- Coordinates for the block under the cursor.
---
--- `symbol` carries the docs-relative path ("resources/s3_bucket") rather than
--- the type as written, so `url` stays a pure string join with no second lookup
--- of the category. A provider block has no symbol at all and addresses the
--- provider's docs index.
---@param ctx table
---@return table|nil
function M.coord(ctx)
  local kind, label = enclosing_block(ctx.bufnr)
  if not kind then
    kind, label = scan_block(ctx.bufnr, vim.api.nvim_win_get_cursor(0)[1])
  end
  if not kind or not label or label == "" then
    return nil
  end

  if kind == "provider" then
    local source = resolve_source(label, ctx)
    return source and { pkg = source } or nil
  end

  -- Built-in types are checked before the prefix split, since "terraform" would
  -- otherwise resolve as a local name and produce hashicorp/terraform. `pkg` is
  -- the built-in provider's real type name, so a driver that falls through to a
  -- search still has an accurate term rather than a nil.
  if BUILTIN[label] then
    return { pkg = "terraform", symbol = label, stdlib = true }
  end
  if label:match("^terraform_") then
    return nil
  end

  local local_name, slug = M._split_type(label)
  if not local_name then
    return nil
  end
  local source = resolve_source(local_name, ctx)
  if not source then
    return nil
  end
  return { pkg = source, symbol = ADDRESSABLE[kind] .. "/" .. slug }
end

--- Coordinates -> a docs URL.
---@param c table
---@param _ctx table|nil
---@return string|nil
function M.url(c, _ctx)
  if not c then
    return nil
  end
  if c.stdlib then
    return BUILTIN[c.symbol]
  end
  if not c.pkg then
    return nil
  end
  local base = REGISTRY .. c.pkg .. "/latest/docs"
  return c.symbol and (base .. "/" .. c.symbol) or base
end

--- Cursor on a `provider "registry.terraform.io/hashicorp/aws"` line of the
--- lockfile, or anywhere in that provider's block.
---
--- Scans upward so a cursor parked on the `version` line — the one line in the
--- block anybody actually reads — resolves to the same provider.
---@param bufnr integer
---@param lnum integer  1-indexed
---@return table|nil
function M.manifest_line(bufnr, lnum)
  for i = lnum, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if not line then
      break
    end
    local addr = line:match('^provider%s+"([^"]+)"')
    if addr then
      local source = M._normalize_source(addr)
      return source and { pkg = source } or nil
    end
  end
  return nil
end

--- Providers recorded in the lockfile, for the picker.
---
--- Straight parse of the manifest: no `terraform providers` invocation, which
--- would need an initialized .terraform and, on a stale one, fails outright
--- ("Inconsistent dependency lock file") rather than degrading.
---@param ctx table
---@return table[]|nil
function M.deps(ctx)
  if not ctx.root then
    return nil
  end
  local lock = read_source(ctx.root .. "/" .. M.manifest)
  if not lock then
    return nil
  end
  local out = {}
  for addr, version in pairs(M._lock_providers(lock)) do
    out[#out + 1] =
      { name = M._normalize_source(addr) or addr, version = version, kind = "provider" }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return #out > 0 and out or nil
end

return M
