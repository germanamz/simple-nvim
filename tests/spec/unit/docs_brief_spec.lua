-- The providers behind `K`'s documentation excerpts. They only NAME the symbol:
-- which DevDocs bundle to look in and under what index name. The LSP payloads
-- below are the shapes clangd and pyright returned on 2026-09-15 for the
-- symbols named, trimmed to the fields the providers read.

local SDK =
  "file:///Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include"

describe("config.docs.brief.c", function()
  local c = require("config.docs.brief.c")

  -- `memcpy` in C on macOS is a fortify macro. clangd answers with the builtin
  -- it expands to AND the macro, in that order.
  local memcpy = {
    {
      name = "__builtin___memcpy_chk",
      containerName = vim.NIL,
      declarationRange = { uri = SDK .. "/secure/_string.h" },
    },
    { name = "memcpy", containerName = vim.NIL, usr = "c:@macro@memcpy" },
  }

  it("names a C function in the c bundle, then the POSIX and Linux man pages", function()
    local got = c._from_symbols("c", memcpy, "memcpy", "/Users/me/src/kilo")
    assert.same({
      { slug = "c", name = "memcpy" },
      { slug = "man", name = "memcpy (3p)" },
      { slug = "man", name = "memcpy (2)" },
      { slug = "man", name = "memcpy (3)" },
    }, got)
  end)

  it("never offers library docs for a symbol the project declares", function()
    local own = {
      {
        name = "abAppend",
        containerName = vim.NIL,
        declarationRange = { uri = "file:///Users/me/src/kilo/kilo.c" },
      },
    }
    assert.is_nil(c._from_symbols("c", own, "abAppend", "/Users/me/src/kilo"))
  end)

  it("declines when clangd has no symbol", function()
    assert.is_nil(c._from_symbols("c", {}, "x", "/r"))
    assert.is_nil(c._from_symbols("c", nil, "x", "/r"))
  end)

  it("names a C++ std member by its qualified name, hinted by its header", function()
    local push_back = {
      {
        name = "push_back",
        containerName = "std::vector::",
        declarationRange = { uri = SDK .. "/c%2B%2B/v1/__vector/vector.h" },
      },
    }
    local got = c._from_symbols("cpp", push_back, "push_back", "/r")
    assert.same({ slug = "cpp", name = "std::vector::push_back", hint = "vector" }, got[1])
    assert.equals(1, #got)
  end)

  it("hints a free std function with the header it lives in", function()
    local to_string = {
      {
        name = "to_string",
        containerName = "std::",
        declarationRange = { uri = SDK .. "/c%2B%2B/v1/string" },
      },
    }
    local got = c._from_symbols("cpp", to_string, "to_string", "/r")
    assert.same({ slug = "cpp", name = "std::to_string", hint = "string" }, got[1])
  end)

  it("tries std:: and then C for an unqualified function in C++", function()
    local got = c._from_symbols("cpp", memcpy, "memcpy", "/r")
    assert.same({ slug = "cpp", name = "std::memcpy" }, got[1])
    assert.same({ slug = "c", name = "memcpy" }, got[2])
  end)

  it("leaves non-std C++ namespaces alone", function()
    local fmt = {
      {
        name = "format",
        containerName = "fmt::",
        declarationRange = { uri = "file:///opt/homebrew/include/fmt/format.h" },
      },
    }
    assert.is_nil(c._from_symbols("cpp", fmt, "format", "/r"))
  end)

  it("strips libc++'s inline namespace if a server reports it", function()
    local v = { { name = "size", containerName = "std::__1::vector::" } }
    assert.equals("std::vector::size", c._from_symbols("cpp", v, "size", "/r")[1].name)
  end)
end)

describe("config.docs.brief.python", function()
  local py = require("config.docs.brief.python")
  local TYPESHED =
    "/Users/me/.local/share/nvim/mason/packages/pyright/node_modules/pyright/dist/typeshed-fallback"

  it("derives the module from a typeshed stdlib stub path", function()
    assert.equals("builtins", py._stub_module(TYPESHED .. "/stdlib/builtins.pyi"))
    assert.equals("os.path", py._stub_module(TYPESHED .. "/stdlib/os/path.pyi"))
    assert.equals("json", py._stub_module(TYPESHED .. "/stdlib/json/__init__.pyi"))
  end)

  -- Third-party packages ship their own source, which pyright already reads
  -- docstrings from; a stub outside typeshed's stdlib is not ours to document.
  it("declines anything that is not a stdlib stub", function()
    assert.is_nil(py._stub_module("/p/.venv/lib/python3.12/site-packages/foo/bar.pyi"))
    assert.is_nil(py._stub_module(TYPESHED .. "/stdlib/os/path.py"))
    assert.is_nil(py._stub_module(TYPESHED .. "/stubs/requests/requests/api.pyi"))
    assert.is_nil(py._stub_module(nil))
  end)

  local stub = {
    "import sys",
    "class str(Sequence[str]):",
    "    @overload",
    "    def __new__(cls, object: object = ...) -> Self: ...",
    "    if sys.version_info >= (3, 9):",
    "        def removeprefix(self, prefix: str, /) -> str: ...",
    "    def split(  # type: ignore[misc]",
    "        self, sep: str | None = None, maxsplit: SupportsIndex = -1",
    "    ) -> list[str]: ...",
    "",
    "def len(obj: Sized, /) -> int: ...",
  }

  local function at(line, first, last)
    return {
      start = { line = line, character = first },
      ["end"] = { line = line, character = last },
    }
  end

  it("qualifies a method with its enclosing classes", function()
    assert.same({ "str", "split" }, py._qualname(stub, at(6, 8, 13)))
    -- Nested under an `if` inside the class body: the `if` is not a scope.
    assert.same({ "str", "removeprefix" }, py._qualname(stub, at(5, 12, 24)))
  end)

  it("leaves a top-level function unqualified", function()
    assert.same({ "len" }, py._qualname(stub, at(10, 4, 7)))
  end)

  it("names a builtin the way the Python docs index does", function()
    assert.same(
      { "str.split()", "str.split", "s.split()", "s.split" },
      py._names("builtins", { "str", "split" }, "s.split")
    )
  end)

  -- typeshed routes os.path through posixpath, which the docs never mention;
  -- the dotted name as written in the buffer is what finds `os.path.join()`.
  it("falls back to the dotted name as written", function()
    local names = py._names("posixpath", { "join" }, "os.path.join")
    assert.equals("posixpath.join()", names[1])
    assert.truthy(vim.tbl_contains(names, "os.path.join()"))
  end)

  it("picks the bundle for the project's Python version", function()
    assert.equals("python~3.10", py._pick_slug("3.10", { "cpp", "python~3.10" }))
    -- Equidistant: the newer documentation wins.
    assert.equals("python~3.12", py._pick_slug("3.11", { "python~3.10", "python~3.12" }))
    assert.equals("python~3.10", py._pick_slug("3.13", { "python~3.10" }))
    -- Nothing installed: name the exact bundle so the hint says what to install.
    assert.equals("python~3.13", py._pick_slug("3.13", {}))
    -- No version known: the newest installed, or nothing to suggest.
    assert.equals("python~3.12", py._pick_slug(nil, { "python~3.9", "python~3.12" }))
    assert.is_nil(py._pick_slug(nil, {}))
  end)
end)
