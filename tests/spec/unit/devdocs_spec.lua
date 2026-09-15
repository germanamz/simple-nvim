local devdocs = require("config.docs.devdocs")

-- The fixture bundles under tests/fixtures/devdocs were trimmed from the real
-- DevDocs downloads of 2026-09-15: the index keeps only the entries these specs
-- name, and each page keeps the markup around the part an excerpt reads. The
-- shapes are verbatim, which is the point — every excerpt rule below was
-- written against what DevDocs actually ships, not against a guess at it.
local FIXTURES = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "fixtures",
  "devdocs"
)

describe("config.docs.devdocs store", function()
  before_each(function()
    devdocs._reset()
    devdocs._root = FIXTURES
  end)

  after_each(function()
    devdocs._root = nil
    devdocs._reset()
  end)

  it("knows which bundles are on disk", function()
    assert.is_true(devdocs.installed("cpp"))
    assert.is_false(devdocs.installed("rust"))
    assert.same({ "c", "cpp", "man", "python~3.10" }, devdocs.installed_slugs())
  end)

  it("looks a name up in a bundle's index", function()
    assert.equals(
      "container/vector/push_back",
      devdocs.lookup("cpp", "std::vector::push_back").path
    )
    assert.is_nil(devdocs.lookup("cpp", "nope"))
    assert.is_nil(devdocs.lookup("rust", "std::vec::Vec"))
  end)

  -- std::to_string is three pages in cppreference: the <string> overloads and
  -- two <stacktrace> ones. The declaring header is what tells them apart.
  it("disambiguates a name with several pages by the declaring header", function()
    assert.equals(
      "string/basic_string/to_string",
      devdocs.lookup("cpp", "std::to_string", "string").path
    )
    assert.equals(
      "utility/basic_stacktrace/to_string",
      devdocs.lookup("cpp", "std::to_string").path
    )
  end)

  it("builds the hosted URL for every bundle family", function()
    local function url(slug, name)
      return devdocs.url(slug, devdocs.lookup(slug, name))
    end
    assert.equals(
      "https://en.cppreference.com/w/cpp/container/vector/push_back",
      url("cpp", "std::vector::push_back")
    )
    assert.equals("https://en.cppreference.com/w/c/memory/realloc", url("c", "realloc"))
    assert.equals("https://man7.org/linux/man-pages/man3/read.3p.html", url("man", "read (3p)"))
    assert.equals(
      "https://docs.python.org/3.10/library/stdtypes.html#str.split",
      url("python~3.10", "str.split()")
    )
    assert.is_nil(devdocs.url("rust", { name = "x", path = "x" }))
  end)

  it("labels an excerpt with its source", function()
    local function label(slug, name)
      return devdocs.label(slug, devdocs.lookup(slug, name))
    end
    assert.equals("cppreference · std::vector::push_back", label("cpp", "std::vector::push_back"))
    assert.equals("cppreference · realloc", label("c", "realloc"))
    assert.equals("man · read(3p)", label("man", "read (3p)"))
    assert.equals("python 3.10 · str.split()", label("python~3.10", "str.split()"))
  end)
end)

describe("config.docs.devdocs html -> markdown", function()
  it("decodes named and numeric entities", function()
    assert.equals("<T> 'a' — & x", devdocs._decode("&lt;T&gt; &#39;a&#39; &#x2014; &amp; x"))
    -- An entity it does not know is left alone rather than eaten.
    assert.equals("&bogus;", devdocs._decode("&bogus;"))
  end)

  it("turns a paragraph with inline code and links into one markdown paragraph", function()
    local blocks =
      devdocs._blocks('<p>Appends <code>value</code> to\n  <a href="end">the end</a>.</p>', "cpp")
    assert.same({ { kind = "para", text = "Appends `value` to the end." } }, blocks)
  end)

  -- cppreference writes `reserve(size() + 1)` as five adjacent <code> runs.
  it("merges adjacent code spans", function()
    local blocks = devdocs._blocks("<p><code>reserve</code><code>(</code><code>size</code></p>")
    assert.equals("`reserve(size`", blocks[1].text)
  end)

  it("keeps preformatted code verbatim under the requested language", function()
    local blocks =
      devdocs._blocks('<pre data-language="c">int main()\n{\n    return 0;\n}\n</pre>', "cpp")
    assert.same({
      { kind = "code", lang = "cpp", lines = { "int main()", "{", "    return 0;", "}" } },
    }, blocks)
  end)

  it("makes headings and list-like divs their own blocks", function()
    local blocks = devdocs._blocks(
      '<h3 id="Parameters">Parameters</h3> <div class="t-li1">\n<span class="t-li">a)</span> expand</div>'
    )
    assert.same({
      { kind = "heading", text = "Parameters" },
      { kind = "para", text = "a) expand" },
    }, blocks)
  end)

  -- std::to_string lists its overloads as inline `<span class="t-li">N)</span>`
  -- markers inside one cell, not as divs; each marker starts a new item.
  it("starts a new paragraph at each inline list marker", function()
    local blocks = devdocs._blocks(
      '<td> <span class="t-li">1)</span> first. <span class="t-li">2)</span> second. </td>'
    )
    assert.same({
      { kind = "para", text = "1) first." },
      { kind = "para", text = "2) second." },
    }, blocks)
  end)

  -- DevDocs' highlighter drops the space between keyword tokens, so the page
  -- itself spells `unsigned char` as two adjacent spans.
  it("separates adjacent type-keyword spans", function()
    local blocks = devdocs._blocks(
      '<p>arrays of <span class="kt">unsigned</span><span class="kt">char</span>.</p>'
    )
    assert.equals("arrays of unsigned char.", blocks[1].text)
  end)

  it("does not put emphasis markers inside a code span", function()
    local blocks = devdocs._blocks("<p>Let <code><i>buf</i></code> be</p>")
    assert.equals("Let `buf` be", blocks[1].text)
  end)

  it("reduces an unknown tag to its text", function()
    local blocks = devdocs._blocks('<p>x <span class="t-mark-rev">(since C++11)</span></p>')
    assert.equals("x (since C++11)", blocks[1].text)
  end)

  it("wraps paragraphs at the render width", function()
    local long = string.rep("word ", 40)
    local lines, truncated = devdocs._render({ { kind = "para", text = long } }, 25)
    assert.is_false(truncated)
    assert.is_true(#lines > 1)
    for _, line in ipairs(lines) do
      assert.is_true(vim.api.nvim_strwidth(line) <= devdocs.WIDTH)
    end
  end)

  it("stops at a block boundary when the next block would not fit", function()
    local ten = string.rep(string.rep("x", 79) .. " ", 10)
    local blocks = {
      { kind = "para", text = ten },
      { kind = "para", text = ten },
      { kind = "para", text = ten },
    }
    local lines, truncated = devdocs._render(blocks, 25)
    assert.is_true(truncated)
    -- Two ten-line paragraphs and the blank line between them.
    assert.equals(21, #lines)
  end)

  it("does not end a truncated excerpt on a heading with nothing under it", function()
    local ten = string.rep(string.rep("x", 79) .. " ", 10)
    local blocks = {
      { kind = "para", text = ten },
      { kind = "heading", text = "Return value" },
      { kind = "para", text = ten .. ten },
    }
    local lines, truncated = devdocs._render(blocks, 25)
    assert.is_true(truncated)
    assert.equals(10, #lines)
  end)

  it("hard-cuts a first block longer than the cap and closes its fence", function()
    local code = {}
    for i = 1, 40 do
      code[i] = "line " .. i
    end
    local lines, truncated = devdocs._render({ { kind = "code", lang = "c", lines = code } }, 25)
    assert.is_true(truncated)
    assert.equals(25, #lines)
    assert.equals("```c", lines[1])
    assert.equals("```", lines[25])
  end)
end)

describe("config.docs.devdocs excerpts", function()
  local max_lines

  before_each(function()
    devdocs._reset()
    devdocs._root = FIXTURES
    max_lines = devdocs.MAX_LINES
  end)

  after_each(function()
    devdocs._root = nil
    devdocs.MAX_LINES = max_lines
    devdocs._reset()
  end)

  --- The excerpt for a name, plus its lines joined into one space-normalized
  --- string so an assertion is not at the mercy of where a line wrapped.
  ---@return table|nil, string
  local function excerpt(slug, name, hint)
    local ex = devdocs.excerpt(slug, devdocs.lookup(slug, name, hint))
    local flat = ex and table.concat(ex.lines, " "):gsub("%s+", " ") or ""
    return ex, flat
  end

  local function has(flat, needle)
    assert(flat:find(needle, 1, true), ("expected %q in:\n%s"):format(needle, flat))
  end

  local function lacks(flat, needle)
    assert(not flat:find(needle, 1, true), ("did not expect %q in:\n%s"):format(needle, flat))
  end

  describe("cppreference", function()
    it("keeps the lead and the parameters, and drops the signature and the rest", function()
      devdocs.MAX_LINES = 200
      local ex, flat = excerpt("cpp", "std::vector::push_back")
      assert.is_not_nil(ex)
      has(flat, "Appends the given element `value` to the end of the container.")
      assert.is_true(vim.tbl_contains(ex.lines, "**Parameters**"))
      has(flat, "`value` — the value of the element to append")
      lacks(flat, "void push_back( const T& value );")
      lacks(flat, "Amortized constant")
      lacks(flat, "#include <iomanip>")
    end)

    it("drops the header table and keeps the return value section", function()
      devdocs.MAX_LINES = 200
      local ex, flat = excerpt("cpp", "std::to_string", "string")
      assert.is_not_nil(ex)
      lacks(flat, "Defined in header")
      assert.is_true(vim.tbl_contains(ex.lines, "**Return value**"))
    end)

    it("caps a long lead and says so", function()
      local ex = excerpt("c", "realloc")
      assert.is_true(ex.truncated)
      assert.is_true(#ex.lines <= devdocs.MAX_LINES)
      assert.truthy(ex.lines[1]:find("Reallocates the given area of memory", 1, true))
    end)
  end)

  describe("sphinx", function()
    it("takes one method's entry and stops at its own end", function()
      devdocs.MAX_LINES = 200
      local ex, flat = excerpt("python~3.10", "str.split()")
      assert.is_not_nil(ex)
      has(flat, "Return a list of the words in the string")
      lacks(flat, "Return a list of the lines in the string")
      lacks(flat, "version of *object*")
    end)

    it("takes a class's own entry", function()
      local _, flat = excerpt("python~3.10", "str")
      has(flat, "version of *object*")
    end)

    it("does not bleed into the neighbouring functions", function()
      local _, flat = excerpt("python~3.10", "len()")
      has(flat, "Return the length (the number of items) of an object.")
      lacks(flat, "Return an iterator object")
      lacks(flat, "Print objects")
    end)
  end)

  describe("man", function()
    -- malloc(3) documents five functions under one DESCRIPTION, each in its own
    -- indented subsection. `realloc` should get its subsection and no other.
    it("takes the function's own subsection of a grouped page", function()
      devdocs.MAX_LINES = 200
      local ex, flat = excerpt("man", "realloc (3)")
      assert.is_not_nil(ex)
      has(flat, "allocate and free dynamic memory")
      has(flat, "The **realloc**() function changes the size of the memory block")
      has(flat, "If *ptr* is NULL, then the call is equivalent to *malloc(size)*")
      lacks(flat, "The **free**() function frees")
      lacks(flat, "**calloc**() function allocates")
      lacks(flat, "**reallocarray**() function changes")
      assert.is_true(vim.tbl_contains(ex.lines, "**Return value**"))
      has(flat, "The **realloc**() and **reallocarray**() functions return NULL")
      lacks(flat, "The **free**() function returns no value")
    end)

    it("skips the POSIX prolog", function()
      local _, flat = excerpt("man", "read (3p)")
      lacks(flat, "POSIX Programmer's Manual")
      has(flat, "pread, read — read from a file")
      has(flat, "The *read*() function shall attempt to read")
    end)

    it("yields nothing for an entry whose page is not on disk", function()
      assert.is_nil(devdocs.excerpt("man", devdocs.lookup("man", "tcsetattr (3)")))
    end)
  end)
end)
