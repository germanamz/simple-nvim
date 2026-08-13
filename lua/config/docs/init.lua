-- Documentation for the dependency under the cursor.
--
-- Two entry points: `gK` answers "what is this thing" for the symbol or import
-- the cursor sits on, and `<leader>kd` opens a picker over the packages this
-- project actually declares.
--
-- The split of labor is deliberate. Everything language-blind lives in
-- resolve.lua and runs against LSP servers that are already warm; everything
-- language-specific lives in a small adapter under adapters/. Most ecosystems
-- never need an adapter at all — gopls and rust-analyzer hand over better URLs
-- than we could build, version-pinned and symbol-anchored.
--
-- Two invariants hold everywhere below:
--
--   * The keypress never touches the network. Every path is a warm LSP, a file
--     on disk, or a local CLI. We build a URL and let the browser find the 404,
--     because a pre-flight check would lie: javadoc.io, cppreference, npmjs.com
--     and jsr.io all reject scripted clients, and Read the Docs answers 200 for
--     never-built stub pages.
--   * The keypress never blocks. Every resolver is async and the cascade is
--     driven by callbacks rather than buf_request_sync.

local M = {}

local resolve = require("config.docs.resolve")

---@class DocCoord
---@field pkg string|nil      -- package/module/crate identity
---@field symbol string|nil   -- member or qualified symbol, when known
---@field version string|nil  -- only ever a version the manifest already stated
---@field stdlib boolean|nil  -- routes to the language's own stdlib docs

---@class DocCtx
---@field bufnr integer
---@field root string|nil     -- dir holding the adapter's manifest, walked up from the buffer
---@field word string         -- identifier under the cursor, dots included
---@field line string         -- the cursor's line, for adapters that read syntax around it
---@field col integer         -- 0-indexed cursor column

---@class DocPage
---@field cmd string[]         -- argv rendering the COMPLETE page
---@field title string         -- what the panes are labelled with

---@class DocEntry
---@field label string         -- what the outline row reads
---@field lnum integer         -- 1-indexed line in the page this entry heads
---@field kind string          -- section|type|class|func|method|const|var
---@field parent integer|nil   -- index of the parent entry, giving the tree
---@field symbol string|nil    -- qualified name, for locate() and following

---@class DocAdapter
---@field ft string[]
---@field manifest string|string[]|nil
---@field prefer "local"|"web"|nil
---@field coord fun(ctx: DocCtx): DocCoord|nil
---@field url fun(c: DocCoord, ctx: DocCtx|nil): string|nil
---@field help_tag fun(ctx: DocCtx): string|nil
---@field manifest_line fun(bufnr: integer, lnum: integer): DocCoord|nil
---@field deps fun(ctx: DocCtx): table[]|nil
--- The viewer's half. An adapter that implements `page` reads in the two-pane
--- viewer; one that does not falls through to its web URL.
---@field page fun(c: DocCoord, ctx: DocCtx): DocPage|nil
---@field outline fun(lines: string[]): DocEntry[]
---@field xref fun(word: string, c: DocCoord, ctx: DocCtx): DocCoord|nil
---@field qualifiers fun(c: DocCoord, ctx: DocCtx, cb: fun(map: table<string, string>))
---@field locate fun(c: DocCoord, ctx: DocCtx, cb: fun(loc: {file: string, lnum: integer}|nil))

-- filetype -> adapter module basename. Static rather than derived by loading
-- every adapter and reading its `ft` field, so opening a Go file never pays to
-- require the Python and JS adapters. A unit test asserts this map and the
-- adapters' own `ft` lists agree, which is what keeps the duplication honest.
local BY_FT = {
  go = "go",
  gomod = "go",
  rust = "rust",
  python = "python",
  javascript = "js",
  javascriptreact = "js",
  typescript = "js",
  typescriptreact = "js",
  lua = "lua",
  c = "c",
  cpp = "c",
  objc = "c",
  objcpp = "c",
  terraform = "terraform",
}

-- Manifest basename -> adapter module. Keyed on the FILENAME, deliberately not
-- on the filetype: Cargo.toml and pyproject.toml are both `toml`, package.json
-- is `json`, and .terraform.lock.hcl is `hcl` — none of which BY_FT routes, so
-- a filetype-keyed table left the rust, js and terraform manifest_line
-- implementations unreachable. The manifest adapter is looked up independently
-- of the symbol adapter for the same reason: a Cargo.toml buffer has no
-- filetype adapter at all, but it does have a dependency on every other line.
local MANIFEST_FILE = {
  ["go.mod"] = "go",
  ["Cargo.toml"] = "rust",
  ["package.json"] = "js",
  ["pyproject.toml"] = "python",
  [".terraform.lock.hcl"] = "terraform",
}

---@type table<string, DocAdapter|false>
local loaded = {}

--- Load the adapter for a filetype, or nil when there isn't one.
---
--- pcall'd and memoized (including the failure): an adapter may legitimately
--- not exist — terraform ships only if its URL mapping turns out deterministic
--- — and a missing file must degrade to the language-blind cascade rather than
--- erroring out of the keymap.
---@param ft string
---@return DocAdapter|nil
local function load_adapter(name)
  if not name then
    return nil
  end
  if loaded[name] == nil then
    local ok, mod = pcall(require, "config.docs.adapters." .. name)
    loaded[name] = (ok and type(mod) == "table") and mod or false
  end
  return loaded[name] or nil
end

---@param ft string
---@return DocAdapter|nil
local function adapter_for(ft)
  return load_adapter(BY_FT[ft])
end

--- The adapter that owns this buffer's manifest, if the buffer IS one.
---@param bufnr integer
---@return DocAdapter|nil
local function manifest_adapter(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return load_adapter(MANIFEST_FILE[vim.fs.basename(name)])
end

--- The identifier under the cursor, dots included.
---
--- `<cword>` stops at the dot, which loses exactly the part that identifies the
--- package: on the `HandlerFunc` of `http.HandlerFunc` we need `http` too. Dots
--- are trimmed off the ends so a trailing `foo.` (mid-typing, or a sentence in
--- a comment) resolves as `foo`.
---@return string
function M._dotted_word()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  if not line:sub(col, col):match("[%w_%.]") then
    return vim.fn.expand("<cword>")
  end
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_%.]") do
    s = s - 1
  end
  while e < #line and line:sub(e + 1, e + 1):match("[%w_%.]") do
    e = e + 1
  end
  local word = line:sub(s, e)
  return (word:gsub("^%.+", ""):gsub("%.+$", ""))
end

--- Last-resort URL: a web search scoped to the language.
---
--- This is the honest answer for C++, Zig and the other ecosystems where the
--- docs URL is genuinely not computable. Low precision, but it always resolves,
--- which is what keeps `gK` from being a key that sometimes does nothing.
---@param ft string
---@param word string
---@return string
function M._search_url(ft, word)
  local query = vim.uri_encode(ft .. " " .. word, "rfc2396")
  return "https://duckduckgo.com/?q=" .. query
end

--- Build the context handed to every adapter function.
---@param bufnr integer
---@return DocCtx
local function build_ctx(bufnr)
  local ft = vim.bo[bufnr].filetype
  local ad = adapter_for(ft)
  local root = nil
  if ad and ad.manifest then
    -- Cached buffer-locally: the walk-up is a handful of fs_stat calls, but it
    -- runs on every press and the answer cannot change for the life of the
    -- buffer. vim.b clears itself when the buffer goes away.
    root = vim.b[bufnr].docs_root
    if root == nil then
      root = vim.fs.root(bufnr, ad.manifest) or false
      vim.b[bufnr].docs_root = root
    end
  end
  return {
    bufnr = bufnr,
    root = root or nil,
    word = M._dotted_word(),
    line = vim.api.nvim_get_current_line(),
    col = vim.api.nvim_win_get_cursor(0)[2],
  }
end

--- Run async steps in order, stopping at the first that yields a value.
---@param steps fun(cb: fun(value: any))[]
---@param done fun(value: any)
local function first_of(steps, done)
  local i = 0
  local function step()
    i = i + 1
    if not steps[i] then
      return done(nil)
    end
    steps[i](function(value)
      if value then
        done(value)
      else
        step()
      end
    end)
  end
  step()
end

--- Open whatever a resolver produced.
---
--- Two kinds of `file://` arrive here and they must not be treated alike.
--- clangd maps an #include onto the SDK header, which is source to read in a
--- buffer. rust-analyzer answers externalDocs with rustup's *generated HTML*
--- when the docs are on disk — `:edit` on that shows raw markup, so anything
--- HTML goes to the browser pane like every other docs page.
---@param target string
---@return boolean
function M._edits_in_buffer(target)
  return target:match("^file://") ~= nil and target:match("%.html?$") == nil
end

---@param target string
local function open_target(target)
  if M._edits_in_buffer(target) then
    vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(target)))
  else
    require("config.open_url").open(target)
  end
end

--- Resolve a documentation URL for the cursor position, language-blind first.
---@param ctx DocCtx
---@param ad DocAdapter|nil
---@param coord DocCoord|nil
---@param cb fun(url: string|nil)
local function resolve_url(ctx, ad, coord, cb)
  first_of({
    -- rust-analyzer's answer is authoritative and unreproducible: it resolves
    -- re-exports to the defining crate and honors #![doc(html_root_url)].
    function(next_)
      resolve.external_docs(ctx.bufnr, next_)
    end,
    -- gopls appends a version-pinned, symbol-anchored pkg.go.dev link to every
    -- symbol hover; lua_ls links the Lua manual; ts_ls surfaces MDN.
    function(next_)
      resolve.hover_url(ctx.bufnr, next_)
    end,
    function(next_)
      next_(ad and ad.url and coord and ad.url(coord, ctx) or nil)
    end,
    function(next_)
      resolve.document_link(ctx.bufnr, next_)
    end,
  }, cb)
end

--- Open docs for a package coordinate the picker chose.
---
--- Same local-first promise `gK` makes: when the adapter can render the whole
--- page offline (`go doc -all`, `pydoc`, `man`) it opens in the viewer, and the
--- hosted page stays one `o` away. Nothing here touches the LSP — a picker row
--- has no cursor position to ask about, and the buffer underneath belongs to
--- whatever you were editing.
---@param ad DocAdapter
---@param coord DocCoord
---@param ctx DocCtx
function M.open_coord(ad, coord, ctx)
  local ok_url, url = pcall(ad.url or function() end, coord, ctx)
  url = ok_url and url or nil

  local function web()
    if url then
      open_target(url)
    else
      vim.notify("docs: no documentation for " .. (coord.pkg or "?"), vim.log.levels.INFO)
    end
  end

  -- The page command can legitimately fail — `go doc` loads the whole module
  -- graph and any unresolvable require poisons it, and `man` exits nonzero when
  -- there is simply no page — so the web URL stays the fallback, not the plan.
  if ad.page then
    if ad.prefer == "local" or not url then
      return require("config.docs.viewer").open(ad, coord, ctx, { on_fail = web })
    end
  end
  web()
end

--- `gK` — documentation for the thing under the cursor.
function M.open_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local ad = adapter_for(ft)
  local ctx = build_ctx(bufnr)

  -- A manifest line names a dependency outright, which beats anything inferred
  -- from a symbol. Resolved off the filename rather than the filetype so a
  -- Cargo.toml is distinguishable from any other .toml, and so the coordinate
  -- goes back through the SAME adapter that produced it — go.mod's answer
  -- carries its version in `pkg` and only go.url knows how to spell that.
  local man = manifest_adapter(bufnr)
  if man and man.manifest_line then
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local ok, coord = pcall(man.manifest_line, bufnr, lnum)
    if ok and coord and man.url then
      local got, url = pcall(man.url, coord, ctx)
      if got and url then
        return open_target(url)
      end
    end
  end

  -- Neovim's own docs are not a URL. `:help` is better than any web page we
  -- could open for them, so it short-circuits the whole cascade.
  if ad and ad.help_tag then
    local tag = ad.help_tag(ctx)
    if tag then
      return vim.cmd.help(tag)
    end
  end

  local coord = ad and ad.coord and ad.coord(ctx) or nil

  local function search_instead()
    -- Never a silent no-op: say that we fell back, so a language with no docs
    -- host reads as "no direct link" rather than "the keymap is broken".
    vim.notify("docs: no direct link for " .. ctx.word .. ", searching", vim.log.levels.INFO)
    open_target(M._search_url(ft, ctx.word))
  end

  --- The URL cascade, run only once the local renderer has declined.
  local function web_cascade()
    resolve_url(ctx, ad, coord, function(url)
      if url then
        return open_target(url)
      end
      search_instead()
    end)
  end

  -- A nil coord reaches the viewer too: `page` declines it, `on_fail` fires,
  -- and the cascade asks gopls — which is exactly what answers the common
  -- `router.HandlerFunc` case the adapter deliberately will not guess at.
  if ad and ad.prefer == "local" and ad.page then
    return require("config.docs.viewer").open(ad, coord, ctx, { on_fail = web_cascade })
  end

  resolve_url(ctx, ad, coord, function(url)
    if url then
      return open_target(url)
    end
    if ad and ad.page then
      return require("config.docs.viewer").open(ad, coord, ctx, { on_fail = search_instead })
    end
    search_instead()
  end)
end

--- `<leader>kd` — pick a declared dependency and open its docs.
function M.pick()
  require("config.docs.picker").open()
end

--- Test seam: drop memoized adapters so a spec can swap one in.
function M._reset()
  loaded = {}
end

--- Test seam: the filetype -> adapter module map.
---@return table<string, string>
function M._by_ft()
  return BY_FT
end

function M.setup()
  require("config.open_url").setup()
  vim.keymap.set("n", "gK", M.open_at_cursor, { desc = "Docs for symbol under cursor" })
  vim.keymap.set("n", "<leader>kd", M.pick, { desc = "Docs: pick a dependency" })
end

return M
