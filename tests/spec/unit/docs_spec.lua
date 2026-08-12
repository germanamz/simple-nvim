local resolve = require("config.docs.resolve")
local docs = require("config.docs")
local deps = require("config.docs.deps")

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

-- open_floating_preview leaves the float unfocused and only enters it on a
-- SECOND call through the same focus_id — undiscoverable from gK and impossible
-- from the picker, which left `go doc` output you could see but not search.
describe("config.docs float", function()
  it("enters the float so / and n reach the docs", function()
    local src_win = vim.api.nvim_get_current_win()
    docs._render_cmd({ "echo", "alpha\nbeta\ngamma" }, function(cb)
      cb(nil)
    end, function() end)
    vim.wait(5000, function()
      return vim.api.nvim_get_current_win() ~= src_win
    end, 20)

    local win = vim.api.nvim_get_current_win()
    assert.are_not.equals(src_win, win)
    assert.are_not.equals("", vim.api.nvim_win_get_config(win).relative)

    local buf = vim.api.nvim_win_get_buf(win)
    assert.same({ "alpha", "beta", "gamma" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(1, vim.fn.maparg("q", "n", false, true).buffer)

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
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
      cmd = true,
      help_tag = true,
      manifest_line = true,
      deps = true,
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
