local hover = require("config.docs.hover")
local devdocs = require("config.docs.devdocs")

local FIXTURES = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "fixtures",
  "devdocs"
)

-- Hover markdown exactly as clangd and pyright returned it on 2026-09-15.
local HOVERS = {
  clangd_push_back = [[
### instance-method `push_back`

provided by `<vector>`

---
→ `void`

Parameters:

- `value_type && __x (aka int &&)`

---
```cpp
// In vector<int>
public: void push_back(value_type &&__x)
```]],
  clangd_to_string = [[
### function `to_string`

provided by `<string>`

---
→ `string (aka basic_string<char>)`

Parameters:

- `int __val`

---
```cpp
// In namespace std
string to_string(int __val)
```]],
  clangd_memcpy_macro = [[
### macro `memcpy`

provided by `<string.h>`

---
```cpp
#define memcpy(...) __memcpy_chk_func(__VA_ARGS__)

// Expands to
__builtin___memcpy_chk(b, "abc", 4, __builtin_object_size(b, 0))
```]],
  clangd_documented = [[
### function `abAppend`

---
→ `void`

Parameters:

- `struct abuf * ab`

Append `len` bytes of `s` to the buffer, growing it as needed.

---
```cpp
void abAppend(struct abuf *ab, const char *s, int len)
```]],
  pyright_len = [[
```python
(function) def len(
    obj: Sized,
    /
) -> int
```]],
  pyright_join = [[
```python
(function) def join(
    a: LiteralString,
    /,
    *paths: LiteralString
) -> LiteralString
```
---
Join two or more pathname components, inserting '/' as needed.]],
}

local function lines(key)
  return vim.split(HOVERS[key], "\n", { plain = true })
end

describe("config.docs.hover._has_prose", function()
  it("sees no documentation in clangd's template for undocumented symbols", function()
    assert.is_false(hover._has_prose("clangd", lines("clangd_push_back")))
    assert.is_false(hover._has_prose("clangd", lines("clangd_to_string")))
    assert.is_false(hover._has_prose("clangd", lines("clangd_memcpy_macro")))
  end)

  it("sees a doc comment clangd rendered", function()
    assert.is_true(hover._has_prose("clangd", lines("clangd_documented")))
  end)

  it("tells a pyright signature from a pyright docstring", function()
    assert.is_false(hover._has_prose("pyright", lines("pyright_len")))
    assert.is_true(hover._has_prose("pyright", lines("pyright_join")))
  end)

  -- A server whose template this does not know is assumed to have said
  -- something, so a misread leaves the hover alone instead of bolting docs on.
  it("treats an unknown server's hover as documented", function()
    assert.is_true(hover._has_prose("gopls", { "```go", "func F()", "```" }))
  end)
end)

describe("config.docs.hover._compose", function()
  local base = { "```cpp", "void f()", "```" }

  it("appends a labelled excerpt under a rule", function()
    local out = hover._compose(base, { label = "man · read(3p)", lines = { "a", "b" } })
    assert.same({ "```cpp", "void f()", "```", "---", "*man · read(3p)*", "", "a", "b" }, out)
  end)

  it("points at gK when the excerpt was cut", function()
    local out = hover._compose(base, { label = "L", lines = { "a" }, truncated = true })
    assert.same({ "*gK: full page*" }, { out[#out] })
    assert.equals("", out[#out - 1])
  end)

  it("shows a hint in place of an excerpt", function()
    local out = hover._compose(base, { hint = "No docs installed — :DocsInstall cpp" })
    assert.same(
      { "```cpp", "void f()", "```", "---", "*No docs installed — :DocsInstall cpp*" },
      out
    )
  end)

  it("leaves the hover alone with nothing to add", function()
    assert.same(base, hover._compose(base, nil))
  end)
end)

describe("config.docs.hover._brief", function()
  local notify

  before_each(function()
    devdocs._reset()
    devdocs._root = FIXTURES
    hover._reset()
    notify = vim.notify
  end)

  after_each(function()
    devdocs._root = nil
    devdocs._reset()
    vim.notify = notify
  end)

  local function provider(candidates)
    return {
      server = "clangd",
      candidates = function(_, cb)
        cb(candidates)
      end,
    }
  end

  local function brief_for(p)
    local got, called = nil, false
    hover._brief(p, {}, function(b)
      got, called = b, true
    end)
    assert.is_true(called)
    return got
  end

  it("takes the first candidate an installed bundle can document", function()
    local b = brief_for(provider({
      { slug = "rust", name = "std::vec::Vec" },
      { slug = "cpp", name = "std::nope" },
      { slug = "cpp", name = "std::vector::push_back" },
    }))
    assert.equals("cppreference · std::vector::push_back", b.label)
    assert.truthy(b.lines[1]:find("Appends the given element", 1, true))
  end)

  it("names every missing bundle when nothing installed could answer", function()
    local b = brief_for(provider({
      { slug = "nope1", name = "x" },
      { slug = "nope2", name = "x" },
      { slug = "nope1", name = "y" },
    }))
    assert.same({ hint = "No docs installed — :DocsInstall nope1 nope2" }, b)
  end)

  it("adds nothing when installed bundles simply lack the name", function()
    assert.is_nil(brief_for(provider({ { slug = "cpp", name = "std::nope" } })))
    assert.is_nil(brief_for(provider(nil)))
  end)

  it("survives a provider that throws, and warns once", function()
    local warnings = 0
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then
        warnings = warnings + 1
      end
    end
    local broken = {
      server = "clangd",
      candidates = function()
        error("boom")
      end,
    }
    assert.is_nil(brief_for(broken))
    assert.is_nil(brief_for(broken))
    assert.equals(1, warnings)
  end)
end)
