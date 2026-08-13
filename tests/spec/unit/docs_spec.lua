local resolve = require("config.docs.resolve")
local docs = require("config.docs")
local deps = require("config.docs.deps")
local go = require("config.docs.adapters.go")
local python = require("config.docs.adapters.python")

-- The language-blind half of the docs feature. Everything under test here is a
-- pure function over a string or a table, so none of it needs a live LSP: the
-- hover payloads below are verbatim shapes captured from gopls, lua_ls, HLS and
-- ts_ls, which is what the extraction rules were written against.
describe("config.docs.resolve.extract_url", function()
  it("takes the markdown link gopls appends to a symbol hover", function()
    local hover = table.concat({
      "```go",
      "func ToUpper(s string) string",
      "```",
      "",
      "ToUpper returns s with all Unicode letters mapped to their upper case.",
      "",
      "[`strings.ToUpper` on pkg.go.dev](https://pkg.go.dev/strings#ToUpper)",
    }, "\n")
    assert.equals("https://pkg.go.dev/strings#ToUpper", resolve.extract_url(hover))
  end)

  it("prefers the last link, since the doc link is appended after the body", function()
    local hover = table.concat({
      "See also [Reader](https://example.com/intra-doc-reference).",
      "",
      "[`cobra.Command` on pkg.go.dev](https://pkg.go.dev/github.com/spf13/cobra@v1.10.2#Command)",
    }, "\n")
    assert.equals(
      "https://pkg.go.dev/github.com/spf13/cobra@v1.10.2#Command",
      resolve.extract_url(hover)
    )
  end)

  -- HLS emits [Documentation] followed by [Source]. "Last link wins" would pick
  -- the source listing, which is the one thing in the payload that is not docs.
  it("skips a Source link so HLS resolves to Documentation", function()
    local hover = "[Documentation](https://hackage.haskell.org/package/base/docs/Data-List.html)\n"
      .. "[Source](https://hackage.haskell.org/package/base/src/Data.List.html)"
    assert.equals(
      "https://hackage.haskell.org/package/base/docs/Data-List.html",
      resolve.extract_url(hover)
    )
  end)

  -- lua_ls links the manual over plain http, so an https-only pattern loses it.
  it("accepts plain http", function()
    local hover = "[View documents](http://www.lua.org/manual/5.4/manual.html#pdf-string.format)"
    assert.equals(
      "http://www.lua.org/manual/5.4/manual.html#pdf-string.format",
      resolve.extract_url(hover)
    )
  end)

  -- ts_ls renders a JSDoc @see as a bare URL with no brackets around it.
  it("falls back to a bare URL when there is no markdown link", function()
    local hover = "Creates a debounced function.\n\nhttps://lodash.com/docs/4.17.15#debounce"
    assert.equals("https://lodash.com/docs/4.17.15#debounce", resolve.extract_url(hover))
  end)

  it("returns nil for a hover with no URL at all", function()
    assert.is_nil(resolve.extract_url("function foo(bar: string): void"))
    assert.is_nil(resolve.extract_url(""))
    assert.is_nil(resolve.extract_url(nil))
  end)
end)

describe("config.docs._dotted_word", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  ---@param line string
  ---@param col integer 0-indexed
  local function word_at(line, col)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, col })
    return docs._dotted_word()
  end

  -- <cword> stops at the dot, which drops the half that names the package.
  it("keeps the package qualifier when the cursor is on the member", function()
    assert.equals("http.HandlerFunc", word_at("var h http.HandlerFunc", 11))
  end)

  it("keeps the qualifier when the cursor is on the package", function()
    assert.equals("http.HandlerFunc", word_at("var h http.HandlerFunc", 6))
  end)

  it("spans a longer chain", function()
    assert.equals("vim.lsp.buf.hover", word_at("  vim.lsp.buf.hover()", 12))
  end)

  it("trims a trailing dot left by a half-typed chain", function()
    assert.equals("vim.lsp", word_at("vim.lsp.", 4))
  end)

  it("falls back to <cword> when the cursor is not on an identifier", function()
    assert.equals("", word_at("   ", 1))
  end)
end)

describe("config.docs._search_url", function()
  it("escapes the query", function()
    local url = docs._search_url("cpp", "std::vector")
    assert.is_truthy(url:match("^https://duckduckgo%.com/%?q="))
    assert.is_nil(url:match(" "), "spaces must be percent-encoded")
  end)
end)

-- Two very different things arrive as file:// URIs. clangd hands back an SDK
-- header (source, belongs in a buffer); rust-analyzer hands back rustup's
-- generated HTML (belongs in the browser, or `:edit` shows raw markup).
describe("config.docs._edits_in_buffer", function()
  it("edits a header clangd resolved from an #include", function()
    assert.is_true(docs._edits_in_buffer("file:///usr/include/stdio.h"))
  end)

  it("browses rustup's generated HTML rather than editing it", function()
    local uri =
      "file:///Users/x/.rustup/toolchains/stable/share/doc/rust/html/alloc/string/struct.String.html"
    assert.is_false(docs._edits_in_buffer(uri))
    assert.is_false(docs._edits_in_buffer("file:///tmp/docs/index.htm"))
  end)

  it("browses anything that is not a file URI", function()
    assert.is_false(docs._edits_in_buffer("https://docs.rs/serde/latest/serde/"))
  end)
end)

-- The picker reads a version out of the manifest, so pinning costs nothing
-- there. This is the "free half" only: no lockfile is parsed and nothing is
-- resolved, so a manifest that states a range still yields a range.
describe("adapter version pinning", function()
  local go = require("config.docs.adapters.go")
  local rust = require("config.docs.adapters.rust")

  it("pins a go.mod version onto the package page", function()
    assert.equals(
      "https://pkg.go.dev/github.com/julienschmidt/httprouter@v1.3.0",
      go.url({ pkg = "github.com/julienschmidt/httprouter", version = "v1.3.0" })
    )
  end)

  it("leaves a versionless coordinate unpinned", function()
    assert.equals("https://pkg.go.dev/net/http", go.url({ pkg = "net/http" }))
  end)

  -- manifest_line encodes module identity as pkg@version and needs the /mod/
  -- page; appending a second @version there would corrupt the path.
  it("does not double-append onto a manifest coordinate", function()
    assert.equals(
      "https://pkg.go.dev/mod/github.com/spf13/cobra@v1.10.2",
      go.url({ pkg = "github.com/spf13/cobra@v1.10.2", version = "v1.10.2" })
    )
  end)

  it("strips a cargo requirement operator, which docs.rs resolves", function()
    assert.equals("1.0", rust._version_segment("^1.0"))
    assert.equals("1.2.3", rust._version_segment("~1.2.3"))
    assert.equals("1.0.219", rust._version_segment("1.0.219"))
    assert.equals("1.0.0-alpha.1", rust._version_segment("1.0.0-alpha.1"))
  end)

  it("falls back to latest for a shape docs.rs was never asked about", function()
    assert.equals("latest", rust._version_segment(">=1.0, <2.0"))
    assert.equals("latest", rust._version_segment("*"))
    assert.equals("latest", rust._version_segment(nil))
  end)
end)

-- The outline parsers are the whole reason the viewer can navigate, and all
-- three are pure functions over page text — so they are tested against the
-- shapes their tools really emit, captured from `go doc -all net/http`,
-- `python -m pydoc json` and `man 3 printf` on this machine.
describe("config.docs.adapters.go.outline", function()
  -- Trimmed to the structures that matter, spacing preserved exactly: `go doc`
  -- indents prose by four and struct bodies by a tab, and the parser leans on
  -- declarations being the only thing at column 0.
  local PAGE = vim.split(
    table.concat({
      'package http // import "net/http"',
      "",
      "Package http provides HTTP client and server implementations.",
      "",
      "CONSTANTS",
      "",
      "const (",
      '\tMethodGet     = "GET"',
      '\tMethodHead    = "HEAD"',
      ")",
      "    Common HTTP methods.",
      "",
      "VARIABLES",
      "",
      "var (",
      "\t// ErrNotSupported indicates that a feature is not supported.",
      '\tErrNotSupported = &ProtocolError{"feature not supported"}',
      ")",
      "",
      "FUNCTIONS",
      "",
      "func Get(url string) (resp *Response, err error)",
      "    Get issues a GET to the specified URL.",
      "",
      "TYPES",
      "",
      "type Client struct {",
      "\tTransport RoundTripper",
      "}",
      "    A Client is an HTTP client.",
      "",
      "func (c *Client) Do(req *Request) (*Response, error)",
      "    Do sends an HTTP request.",
      "",
      "type Header map[string][]string",
      "",
      "func (h Header) Get(key string) string",
      "    Get gets the first value associated with the given key.",
    }, "\n"),
    "\n"
  )

  local function find(entries, label, kind)
    for i, e in ipairs(entries) do
      if e.label == label and (not kind or e.kind == kind) then
        return i, e
      end
    end
  end

  it("nests a method under its receiver type, not under the preceding entry", function()
    local out = go.outline(PAGE)
    local client_i = find(out, "Client", "type")
    local _, do_ = find(out, "Do", "method")
    assert.equals(client_i, do_.parent)
    assert.equals("Client.Do", do_.symbol)
  end)

  -- `Get` is both a package function and a method on two different types. The
  -- receiver is what tells them apart, and getting this wrong silently files
  -- Header.Get under Client.
  it("keeps same-named methods on different types apart", function()
    local out = go.outline(PAGE)
    local header_i = find(out, "Header", "type")
    local symbols = {}
    for _, e in ipairs(out) do
      if e.label == "Get" then
        symbols[#symbols + 1] = e.symbol
      end
    end
    assert.same({ "Get", "Client.Get" and "Header.Get" or nil }, { symbols[1], symbols[2] })
    local _, hget = find(out, "Get", "method")
    assert.equals(header_i, hget.parent)
  end)

  -- A method's signature also starts with `(`. Reading that as a `const (`
  -- block opener made the parser swallow every declaration after the first
  -- method — net/http fell from 196 entries to 64.
  it("does not mistake a method's receiver for a const block", function()
    local out = go.outline(PAGE)
    assert.is_truthy(find(out, "Header", "type"))
    assert.is_truthy(find(out, "Get", "method"))
  end)

  it("collapses a const group to one row named for its first member", function()
    local out = go.outline(PAGE)
    local _, group = find(out, "MethodGet …")
    assert.equals("const", group.kind)
    assert.is_nil(find(out, "MethodHead"))
  end)

  -- The first line inside net/http's `var (` block is a comment, and taking it
  -- as the member name labels the row `//`.
  it("skips comment lines when naming a var group", function()
    local out = go.outline(PAGE)
    assert.is_truthy(find(out, "ErrNotSupported …"))
  end)

  it("reports the line each entry heads, so the viewer can scroll to it", function()
    local out = go.outline(PAGE)
    local _, client = find(out, "Client", "type")
    assert.equals("type Client struct {", PAGE[client.lnum])
  end)
end)

describe("config.docs.adapters.go source location", function()
  -- Deliberately run through grep, not vim.fn.match. The pattern is a POSIX
  -- ERE handed to `grep -E`, and Vim's regex engine reads several of these
  -- constructs differently — testing it here would assert the wrong dialect
  -- and pass on patterns grep rejects.
  ---@param pattern string
  ---@param text string
  ---@return boolean
  local function greps(pattern, text)
    local res = vim.system({ "grep", "-qE", pattern }, { stdin = text, text = true }):wait(5000)
    return res.code == 0
  end

  -- The loose form `\([^)]*\*?Client[^)]*\)` also matches `(cc *ClientConn)`,
  -- which resolved net/http.Client.Do into httputil against real GOROOT.
  it("anchors a receiver so a longer type name cannot match", function()
    local pattern = go._decl_pattern("Client.Do")
    assert.is_true(greps(pattern, "func (c *Client) Do(req *Request) error {"))
    assert.is_false(greps(pattern, "func (cc *ClientConn) Do(req *http.Request) error {"))
  end)

  it("matches a generic receiver", function()
    assert.is_true(greps(go._decl_pattern("N.n"), "func (r *N[C]) n() {  }"))
  end)

  it("accepts any declaration keyword for a bare symbol", function()
    local pattern = go._decl_pattern("Client")
    assert.is_true(greps(pattern, "type Client struct {"))
    assert.is_true(greps(pattern, "func Client() {"))
    -- A longer name that merely starts the same must not match.
    assert.is_false(greps(pattern, "type ClientConn struct {"))
  end)

  -- Anchored at column 0, so a mention inside a function body is not a
  -- declaration.
  it("ignores a reference that is not at the start of a line", function()
    assert.is_false(greps(go._decl_pattern("Client"), "\tvar c type Client struct{}"))
  end)

  it("declines a symbol that is not an identifier", function()
    assert.is_nil(go._decl_pattern("net/http"))
    assert.is_nil(go._decl_pattern(nil))
  end)
end)

describe("config.docs.adapters.go.xref", function()
  it("declines a bare qualifier with no import map to resolve it against", function()
    assert.is_nil(go.xref("url.Values", { pkg = "net/http" }, {}))
  end)

  it("resolves a qualifier through the page's imports", function()
    local coord = go.xref("url.Values", { pkg = "net/http" }, { qualifiers = { url = "net/url" } })
    assert.same({ pkg = "net/url", symbol = "Values", stdlib = true }, coord)
  end)

  it("takes a full import path without needing the map", function()
    assert.same(
      { pkg = "github.com/go-chi/chi/v5", stdlib = false },
      go.xref("github.com/go-chi/chi/v5", { pkg = "net/http" }, {})
    )
  end)
end)

describe("config.docs.adapters.python.outline", function()
  local PAGE = vim.split(
    table.concat({
      "Help on package json:",
      "",
      "NAME",
      "    json",
      "",
      "CLASSES",
      "    builtins.object",
      "        json.encoder.JSONEncoder",
      "",
      "    class JSONEncoder(builtins.object)",
      "     |  JSONEncoder(*, skipkeys=False)",
      "     |  ",
      "     |  Extensible JSON encoder. Call encode(o) to get a string.",
      "     |  ",
      "     |  Methods defined here:",
      "     |  ",
      "     |  __init__(self, *, skipkeys=False)",
      "     |      Constructor for JSONEncoder.",
      "     |  ",
      "     |  encode(self, o)",
      "     |      Return a JSON string representation.",
      "     |  ",
      "     |  ----------------------------------------------------------",
      "     |  Methods inherited from builtins.object:",
      "     |  ",
      "     |  __delattr__(self, name, /)",
      "     |      Implement delattr(self, name).",
      "",
      "FUNCTIONS",
      "    dumps(obj, *, skipkeys=False)",
      "        Serialize obj to a JSON formatted str.",
      "",
      "FILE",
      "    /usr/lib/python3.10/json/__init__.py",
    }, "\n"),
    "\n"
  )

  local function labels(entries, kind)
    local out = {}
    for _, e in ipairs(entries) do
      if e.kind == kind then
        out[#out + 1] = e.label
      end
    end
    return out
  end

  it("qualifies symbols with the module pydoc names in its NAME section", function()
    local out = python.outline(PAGE)
    for _, e in ipairs(out) do
      if e.label == "JSONEncoder" then
        assert.equals("json.JSONEncoder", e.symbol)
      end
      if e.label == "dumps" then
        assert.equals("json.dumps", e.symbol)
      end
    end
  end)

  -- Every class inherits object's dunders. Listing them buries the two or three
  -- methods the class actually defines.
  it("takes only members defined here, never inherited ones", function()
    local out = python.outline(PAGE)
    assert.same({ "__init__", "encode" }, labels(out, "method"))
  end)

  -- Class-body prose sits in the same `|` gutter at the same indent and says
  -- "Call encode(o) to get a string", which a shape-only test reads as a method.
  it("does not read prose in the class gutter as a method", function()
    local out = python.outline(PAGE)
    local count = 0
    for _, e in ipairs(out) do
      if e.label == "encode" then
        count = count + 1
      end
    end
    assert.equals(1, count)
  end)

  it("nests methods under their class", function()
    local out = python.outline(PAGE)
    local cls = nil
    for i, e in ipairs(out) do
      if e.kind == "class" then
        cls = i
      end
      if e.kind == "method" then
        assert.equals(cls, e.parent)
      end
    end
  end)

  -- The inheritance tree at the top of CLASSES is indented the same as the real
  -- `class X(...)` lines but carries no `class` keyword.
  it("ignores the inheritance tree above the class definitions", function()
    assert.same({ "JSONEncoder" }, labels(python.outline(PAGE), "class"))
  end)
end)

describe("config.docs.adapters.c", function()
  local PAGE = vim.split(
    table.concat({
      "PRINTF(3)                Library Functions Manual                PRINTF(3)",
      "",
      "NAME",
      "     printf -- formatted output conversion",
      "",
      "SYNOPSIS",
      "     int printf(const char *restrict format, ...);",
      "",
      "RETURN VALUES",
      "     These functions return the number of characters printed.",
      "",
      "SEE ALSO",
      "     fprintf(3), scanf(3), printf(1)",
    }, "\n"),
    "\n"
  )

  it("outlines the page's sections and nothing else", function()
    local out = require("config.docs.adapters.c").outline(PAGE)
    assert.same(
      { "NAME", "SYNOPSIS", "RETURN VALUES", "SEE ALSO" },
      vim.tbl_map(function(e)
        return e.label
      end, out)
    )
  end)

  -- The running header repeats the page name in caps, but carries digits and
  -- parens that an all-caps-and-spaces match cannot accept.
  it("does not take the running header for a section", function()
    local out = require("config.docs.adapters.c").outline(PAGE)
    for _, e in ipairs(out) do
      assert.is_nil(e.label:match("PRINTF"))
    end
  end)

  it("follows a SEE ALSO reference", function()
    local c = require("config.docs.adapters.c")
    assert.same(
      { symbol = "fprintf" },
      c.xref("fprintf", {}, { line = "     fprintf(3), scanf(3)" })
    )
  end)

  -- Without the section-number gate, <CR> anywhere in the prose would spawn
  -- `man` on an English word.
  it("declines a name in prose and a call in the synopsis", function()
    local c = require("config.docs.adapters.c")
    assert.is_nil(c.xref("printf", {}, { line = "     These functions return..." }))
    assert.is_nil(
      c.xref("printf", {}, { line = "     int printf(const char *restrict format, ...);" })
    )
  end)
end)

describe("config.docs.viewer", function()
  local viewer = require("config.docs.viewer")

  -- Three columns need real width. Squeezing them into a narrow terminal is
  -- what the tab fallback exists to avoid.
  it("splits when there is room and takes a tab when there is not", function()
    assert.equals("split", viewer._layout(200).mode)
    assert.equals("tab", viewer._layout(120).mode)
    assert.equals("tab", viewer._layout(nil).mode)
  end)

  local ENTRIES = {
    { label = "TYPES", lnum = 1, kind = "section" },
    { label = "Client", lnum = 2, kind = "type", parent = 1, symbol = "Client" },
    { label = "Do", lnum = 3, kind = "method", parent = 2, symbol = "Client.Do" },
    { label = "Header", lnum = 4, kind = "type", parent = 1, symbol = "Header" },
    { label = "Do", lnum = 5, kind = "method", parent = 4, symbol = "Header.Do" },
    { label = "Get", lnum = 6, kind = "func", parent = 1, symbol = "Get" },
  }

  it("indents the outline by parent depth", function()
    local lines = viewer._render_outline(ENTRIES, nil)
    assert.same({ "TYPES", "  Client", "    Do", "  Header", "    Do", "  Get" }, lines)
  end)

  it("renders a filtered outline flat and fully qualified", function()
    local lines = viewer._render_outline(ENTRIES, { 3, 5 })
    assert.same({ "  Client.Do", "  Header.Do" }, lines)
  end)

  it("prefers an exact symbol over a bare label", function()
    assert.equals(5, viewer._find_entry(ENTRIES, "Header.Do"))
  end)

  -- `Get` in net/http is the package function; asking for the method means
  -- writing Client.Get.
  it("prefers a type or func over a method on a bare name", function()
    assert.equals(6, viewer._find_entry(ENTRIES, "Get"))
    assert.equals(2, viewer._find_entry(ENTRIES, "Client"))
  end)

  it("falls back to a method when nothing else carries the name", function()
    assert.equals(3, viewer._find_entry(ENTRIES, "Do"))
  end)

  -- `Do` is a method on two types. Sitting on the declaration line resolves the
  -- ambiguity that a label match cannot.
  it("uses the cursor's own line to disambiguate a duplicated name", function()
    assert.equals(5, viewer._entry_at(ENTRIES, 5, "Do"))
    assert.equals(3, viewer._entry_at(ENTRIES, 3, "Do"))
  end)

  -- The cursor can be on the declaration line but pointing at a parameter type
  -- rather than the name being declared.
  it("declines the line's entry when the cursor is on a different word", function()
    assert.is_nil(viewer._entry_at(ENTRIES, 3, "Request"))
  end)

  -- One table binds the keys and renders `?`. These assert the table itself is
  -- coherent; the e2e spec checks that what it declares is what gets bound.
  it("documents every key it declares", function()
    for _, group in ipairs(viewer.KEYS) do
      assert.is_truthy(group.title)
      assert.is_truthy(({ outline = true, content = true, both = true })[group.pane])
      for _, key in ipairs(group.keys) do
        assert.is_truthy(key.keys ~= nil and key.keys ~= "", "a key row needs a spelling")
        assert.is_truthy(key.help ~= nil and key.help ~= "", key.keys .. " needs help text")
      end
    end
  end)

  -- A second mapping of the same lhs on the same buffer silently wins, so the
  -- earlier one becomes a key the panel promises and nothing performs.
  it("never binds one lhs twice on the same pane", function()
    local seen = { outline = {}, content = {} }
    for _, group in ipairs(viewer.KEYS) do
      for _, key in ipairs(group.keys) do
        if key.fn then
          local panes = group.pane == "both" and { "outline", "content" } or { group.pane }
          for _, pane in ipairs(panes) do
            for _, lhs in ipairs(key.lhs or { key.keys }) do
              assert.is_nil(seen[pane][lhs], ("%s is bound twice in the %s pane"):format(lhs, pane))
              seen[pane][lhs] = true
            end
          end
        end
      end
    end
  end)

  it("renders every declared key into the help panel", function()
    local lines = table.concat(viewer._help_lines("content"), "\n")
    for _, group in ipairs(viewer.KEYS) do
      assert.is_truthy(lines:find(group.title, 1, true), group.title .. " missing from the panel")
      for _, key in ipairs(group.keys) do
        assert.is_truthy(lines:find(key.keys, 1, true), key.keys .. " missing from the panel")
        assert.is_truthy(lines:find(key.help, 1, true), key.help .. " missing from the panel")
      end
    end
  end)

  -- The marker is the only thing separating "keys you can press now" from "keys
  -- the other pane has".
  it("marks only the pane the cursor is in", function()
    local outline = table.concat(viewer._help_lines("outline"), "\n")
    assert.is_truthy(outline:find("▸ Outline pane", 1, true))
    assert.is_nil(outline:find("▸ Content pane", 1, true))

    local content = table.concat(viewer._help_lines("content"), "\n")
    assert.is_truthy(content:find("▸ Content pane", 1, true))
    assert.is_nil(content:find("▸ Outline pane", 1, true))
  end)

  it("survives a parent cycle rather than hanging the render", function()
    local cyclic = { { label = "a", lnum = 1, parent = 2 }, { label = "b", lnum = 2, parent = 1 } }
    assert.is_truthy(viewer._depth(cyclic, 1) <= 32)
  end)
end)

describe("config.docs.deps", function()
  it("sinks indirect dependencies below direct ones", function()
    local rows = {
      { name = "zlib", lang = "go", kind = "indirect" },
      { name = "cobra", lang = "go", kind = "direct" },
      { name = "abseil", lang = "go", kind = "indirect" },
      { name = "afero", lang = "go", kind = "direct" },
    }
    deps.sort(rows)
    assert.same(
      { "afero", "cobra", "abseil", "zlib" },
      vim.tbl_map(function(r)
        return r.name
      end, rows)
    )
  end)

  it("labels indirect rows so the picker does not read as a flat list", function()
    local direct =
      deps.format({ name = "serde", version = "1.0.219", lang = "rust", kind = "direct" })
    local indirect =
      deps.format({ name = "syn", version = "2.0.0", lang = "rust", kind = "indirect" })
    assert.is_truthy(direct:match("serde"))
    assert.is_truthy(indirect:match("indirect"))
  end)

  it("tolerates a row with no version", function()
    assert.is_truthy(deps.format({ name = "requests", lang = "python" }):match("requests"))
  end)

  -- The Go adapter emits all 187 standard library packages. Ranked purely
  -- alphabetically they opened the picker on `archive/tar` and pushed the first
  -- real dependency to row 75, which is what this ordering exists to prevent.
  it("ranks chosen deps above dev, indirect and stdlib", function()
    local rows = {
      { name = "archive/tar", lang = "go", kind = "stdlib" },
      { name = "zod", lang = "go", kind = "indirect" },
      { name = "testify", lang = "go", kind = "dev" },
      { name = "httprouter", lang = "go", kind = "direct" },
    }
    deps.sort(rows)
    assert.same(
      { "httprouter", "testify", "zod", "archive/tar" },
      vim.tbl_map(function(r)
        return r.name
      end, rows)
    )
  end)

  it("treats a row with no kind as direct", function()
    local rows = {
      { name = "b", lang = "go", kind = "stdlib" },
      { name = "a", lang = "go" },
    }
    deps.sort(rows)
    assert.equals("a", rows[1].name)
  end)

  it("labels every non-direct kind, not just indirect", function()
    assert.is_truthy(deps.format({ name = "fmt", lang = "go", kind = "stdlib" }):match("stdlib"))
    assert.is_truthy(deps.format({ name = "vitest", lang = "js", kind = "dev" }):match("dev"))
    assert.is_nil(deps.format({ name = "serde", lang = "rust", kind = "direct" }):match("direct"))
  end)
end)

-- The filetype -> adapter map in config.docs is written by hand so that opening
-- a Go file never requires the Python and JS adapters. This is the test that
-- keeps the duplication from drifting: every filetype the map routes must be
-- one the adapter itself claims.
describe("config.docs adapter registry", function()
  it("agrees with each adapter's own ft list", function()
    for ft, name in pairs(docs._by_ft()) do
      local ok, ad = pcall(require, "config.docs.adapters." .. name)
      if ok and type(ad) == "table" then
        assert.is_table(ad.ft, name .. " adapter must declare ft")
        assert.is_true(
          vim.tbl_contains(ad.ft, ft),
          ("config.docs routes %s to the %s adapter, which does not claim it"):format(ft, name)
        )
      end
    end
  end)

  it("only exposes contract fields", function()
    local allowed = {
      ft = true,
      manifest = true,
      prefer = true,
      coord = true,
      url = true,
      help_tag = true,
      manifest_line = true,
      deps = true,
      -- The viewer's half. `cmd` is deliberately absent: `page` replaced it
      -- when the float was retired, and an adapter still carrying one would be
      -- shipping a renderer nothing calls.
      page = true,
      outline = true,
      xref = true,
      qualifiers = true,
      locate = true,
    }
    local seen = {}
    for _, name in pairs(docs._by_ft()) do
      if not seen[name] then
        seen[name] = true
        local ok, ad = pcall(require, "config.docs.adapters." .. name)
        if ok and type(ad) == "table" then
          for key in pairs(ad) do
            assert.is_true(
              allowed[key] or key:match("^_") ~= nil,
              ("%s adapter exposes %s"):format(name, key)
            )
          end
          if ad.prefer then
            assert.is_true(ad.prefer == "local" or ad.prefer == "web")
          end
        end
      end
    end
  end)
end)
