describe("config.markdown_paragraphs", function()
  local mp
  local bufnr

  before_each(function()
    package.loaded["config.markdown_paragraphs"] = nil
    mp = require("config.markdown_paragraphs")
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  local function compute_for(lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    mp.attach(bufnr)
    return mp.get_starts(bufnr)
  end

  local function b(path, n)
    return { path = path, paragraph = n }
  end

  local function h(path)
    return { path = path }
  end

  it("numbers consecutive prose paragraphs separated by blanks", function()
    local data = compute_for({
      "First paragraph",
      "still first",
      "",
      "Second paragraph",
      "",
      "Third paragraph",
    })
    assert.are.same({ [1] = b({}, 1), [4] = b({}, 2), [6] = b({}, 3) }, data.blocks)
    assert.are.same({}, data.headings)
  end)

  it("increments § on H2 and resets ¶ within each section", function()
    local data = compute_for({
      "Pre-section paragraph.",
      "",
      "## First section",
      "",
      "Paragraph in §1",
      "",
      "## Second section",
      "",
      "Paragraph in §2",
    })
    assert.are.same({ [1] = b({}, 1), [5] = b({ 1 }, 1), [9] = b({ 2 }, 1) }, data.blocks)
    assert.are.same({ [3] = h({ 1 }), [7] = h({ 2 }) }, data.headings)
  end)

  it("ignores H1 entirely", function()
    local data = compute_for({
      "# Title",
      "",
      "Para before any H2",
      "",
      "## Section",
      "",
      "Para inside §1",
    })
    assert.are.same({ [3] = b({}, 1), [7] = b({ 1 }, 1) }, data.blocks)
    assert.are.same({ [5] = h({ 1 }) }, data.headings)
  end)

  it("H3 opens a §N.M nested scope with its own ¶ counter", function()
    local data = compute_for({
      "## §1",
      "",
      "Para in §1",
      "",
      "### §1.1",
      "",
      "Para under §1.1",
      "",
      "Another under §1.1",
      "",
      "### §1.2",
      "",
      "Para under §1.2",
    })
    assert.are.same({
      [3] = b({ 1 }, 1),
      [7] = b({ 1, 1 }, 1),
      [9] = b({ 1, 1 }, 2),
      [13] = b({ 1, 2 }, 1),
    }, data.blocks)
    assert.are.same({
      [1] = h({ 1 }),
      [5] = h({ 1, 1 }),
      [11] = h({ 1, 2 }),
    }, data.headings)
  end)

  it("resets sibling counters per parent (no cross-H2 leakage)", function()
    local data = compute_for({
      "## A",
      "",
      "### A.1",
      "",
      "### A.2",
      "",
      "## B",
      "",
      "### B.1",
    })
    assert.are.same({
      [1] = h({ 1 }),
      [3] = h({ 1, 1 }),
      [5] = h({ 1, 2 }),
      [7] = h({ 2 }),
      [9] = h({ 2, 1 }),
    }, data.headings)
  end)

  it("nests H2 → H3 → H4 → H5 → H6", function()
    local data = compute_for({
      "## §1",
      "### §1.1",
      "#### §1.1.1",
      "##### §1.1.1.1",
      "###### §1.1.1.1.1",
      "",
      "Deepest paragraph",
    })
    assert.are.same({
      [1] = h({ 1 }),
      [2] = h({ 1, 1 }),
      [3] = h({ 1, 1, 1 }),
      [4] = h({ 1, 1, 1, 1 }),
      [5] = h({ 1, 1, 1, 1, 1 }),
    }, data.headings)
    assert.are.same({ [7] = b({ 1, 1, 1, 1, 1 }, 1) }, data.blocks)
  end)

  it("level-skipping pads missing components with 0 (§N..K)", function()
    local data = compute_for({
      "## A",
      "",
      "#### Skip H3",
      "",
      "Paragraph under the H4",
    })
    assert.are.same({
      [1] = h({ 1 }),
      [3] = h({ 1, 0, 1 }),
    }, data.headings)
    assert.are.same({ [5] = b({ 1, 0, 1 }, 1) }, data.blocks)
  end)

  it("paragraph between H2 and its first H3 belongs to the H2 scope", function()
    local data = compute_for({
      "## §1",
      "",
      "Para in §1 (before any H3)",
      "",
      "### §1.1",
      "",
      "Para in §1.1",
    })
    assert.are.same({
      [3] = b({ 1 }, 1),
      [7] = b({ 1, 1 }, 1),
    }, data.blocks)
  end)

  it("ignores a setext H1 (===) but numbers a setext H2 (---) like an ATX H2", function()
    local data = compute_for({
      "Title",
      "=====",
      "",
      "Paragraph one",
      "",
      "Subtitle",
      "--------",
      "",
      "Paragraph two",
    })
    -- "Title"/"=====" is H1 -> ignored (delete-only). "Subtitle"/"--------" is a
    -- setext H2 -> opens §1 (its title line is the heading), so "Paragraph two"
    -- lands in §1, not as a bare ¶3.
    assert.are.same({ [4] = b({}, 1), [9] = b({ 1 }, 1) }, data.blocks)
    assert.are.same({ [6] = h({ 1 }) }, data.headings)
  end)

  it("advances § across successive setext H2 headings", function()
    local data = compute_for({
      "Alpha",
      "-----",
      "",
      "Body in section one",
      "",
      "Beta",
      "----",
      "",
      "Body in section two",
    })
    assert.are.same({ [4] = b({ 1 }, 1), [9] = b({ 2 }, 1) }, data.blocks)
    assert.are.same({ [1] = h({ 1 }), [6] = h({ 2 }) }, data.headings)
  end)

  it("counts fenced code blocks as one ¶", function()
    local data = compute_for({
      "Para one",
      "",
      "```",
      "code line",
      "more code",
      "```",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2), [8] = b({}, 3) }, data.blocks)
  end)

  it("counts a list separated by blanks as its own ¶", function()
    local data = compute_for({
      "Para one",
      "",
      "- item a",
      "- item b",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2), [6] = b({}, 3) }, data.blocks)
  end)

  it("counts a list with no preceding blank as part of the prior paragraph", function()
    local data = compute_for({
      "Intro line",
      "- item a",
      "- item b",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [5] = b({}, 2) }, data.blocks)
  end)

  it("counts non-scratchpad blockquotes as ¶", function()
    local data = compute_for({
      "Para one",
      "",
      "> a regular quote",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2), [5] = b({}, 3) }, data.blocks)
  end)

  it("skips scratchpad blockquotes", function()
    local data = compute_for({
      "Para one",
      "",
      "> Mental Note: remember to add an example",
      "> about the dot-com era.",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [6] = b({}, 2) }, data.blocks)
  end)

  it("recognizes all four scratchpad first-token forms", function()
    local data = compute_for({
      "> TODO: do this",
      "",
      "> Note to self: foo",
      "",
      "> Draft note: bar",
      "",
      "> Mental Note: baz",
      "",
      "Real paragraph",
    })
    assert.are.same({ [9] = b({}, 1) }, data.blocks)
  end)

  it("treats HTML comments like blank lines", function()
    local data = compute_for({
      "Para one",
      "<!-- comment -->",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2) }, data.blocks)
  end)

  it("treats multi-line HTML comments like blank lines", function()
    local data = compute_for({
      "Para one",
      "<!--",
      "  long",
      "  comment",
      "-->",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [6] = b({}, 2) }, data.blocks)
  end)

  it("counts MDX components spanning blanks as a single ¶", function()
    local data = compute_for({
      "Para one",
      "",
      "<Aside>",
      "Inner content that would otherwise be its own ¶",
      "",
      "More content inside the component",
      "</Aside>",
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2), [9] = b({}, 3) }, data.blocks)
  end)

  it("counts self-closing MDX as one ¶", function()
    local data = compute_for({
      "Para one",
      "",
      '<Image src="foo.png" />',
      "",
      "Para two",
    })
    assert.are.same({ [1] = b({}, 1), [3] = b({}, 2), [5] = b({}, 3) }, data.blocks)
  end)

  it("does not let an unclosed lowercase void tag swallow following ¶ numbers", function()
    -- <img> has no close on its line, so it leaves MDX tag balance at +1. Only
    -- PascalCase components open the multi-line swallow; a lowercase HTML tag
    -- must NOT, or every following block loses its ¶ marker.
    local data = compute_for({
      "Para one",
      "",
      '<img src="cat.png">',
      "",
      "Para two",
      "",
      "Para three",
    })
    assert.are.same({
      [1] = b({}, 1),
      [3] = b({}, 2),
      [5] = b({}, 3),
      [7] = b({}, 4),
    }, data.blocks)
  end)

  it("continues numbering after a scratchpad inside a section", function()
    local data = compute_for({
      "## §1",
      "",
      "First paragraph inside §1.",
      "",
      "Second paragraph inside §1.",
      "",
      "> Mental Note: skipped",
      "",
      "Third paragraph in §1.",
    })
    assert.are.same({
      [3] = b({ 1 }, 1),
      [5] = b({ 1 }, 2),
      [9] = b({ 1 }, 3),
    }, data.blocks)
    assert.are.same({ [1] = h({ 1 }) }, data.headings)
  end)

  it("matches the spec's worked example", function()
    local data = compute_for({
      "---",
      "title: 'Example post'",
      "date: '2026-05-16'",
      "published: false",
      "---",
      "",
      "First body paragraph, wrapped over",
      "two physical lines.",
      "",
      "A second body paragraph before any",
      "H2 heading.",
      "",
      "## But why X?",
      "",
      "First paragraph inside §1, before any",
      "H3.",
      "",
      "### A subhead",
      "",
      "First paragraph under the H3.",
      "",
      "Second paragraph under the H3, which",
      "spans two lines.",
      "",
      "> Mental Note: remember to add an example here",
      "> about the dot-com era.",
      "",
      "Third paragraph under §1.1, written",
      "after the scratchpad.",
      "",
      "### Another subhead",
      "",
      "First paragraph under the second H3.",
      "",
      "## How can you catch up?",
      "",
      "First paragraph in §2.",
      "",
      "### A subhead in §2",
      "",
      "First paragraph here — note the index",
      "reset; this is §2.1, not §1.3.",
      "",
      "> Mental Note: outline only, not",
      "> written yet.",
    })
    assert.are.same({
      [7] = b({}, 1),
      [10] = b({}, 2),
      [15] = b({ 1 }, 1),
      [20] = b({ 1, 1 }, 1),
      [22] = b({ 1, 1 }, 2),
      [28] = b({ 1, 1 }, 3),
      [33] = b({ 1, 2 }, 1),
      [37] = b({ 2 }, 1),
      [41] = b({ 2, 1 }, 1),
    }, data.blocks)
    assert.are.same({
      [13] = h({ 1 }),
      [18] = h({ 1, 1 }),
      [31] = h({ 1, 2 }),
      [35] = h({ 2 }),
      [39] = h({ 2, 1 }),
    }, data.headings)
  end)

  it("does not set a colorcolumn ruler in writing mode", function()
    vim.api.nvim_set_current_buf(bufnr)
    vim.wo.colorcolumn = ""
    compute_for({ "line one", "line two", "line three" })
    -- the 80-column ruler was removed; writing mode no longer sets colorcolumn
    assert.are.equal("", vim.wo.colorcolumn)
  end)

  it("sets a custom statuscolumn on the current window", function()
    vim.api.nvim_set_current_buf(bufnr)
    compute_for({ "para" })
    assert.is_truthy(vim.wo.statuscolumn:find("_markdown_paragraph_marker", 1, true))
    assert.is_true(vim.w.markdown_writing_active)
  end)

  it(
    "detach_window restores statuscolumn, clears colorcolumn, and clears the active flag",
    function()
      vim.api.nvim_set_current_buf(bufnr)
      compute_for({ "para" })
      mp.detach_window()
      assert.are.equal("", vim.wo.statuscolumn)
      assert.are.equal("", vim.wo.colorcolumn)
      assert.is_nil(vim.w.markdown_writing_active)
    end
  )

  describe("marker", function()
    it("renders bare ¶N in the pre-section region", function()
      compute_for({ "para" })
      vim.g.statusline_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_buf(bufnr)
      vim.v.lnum = 1
      local s = mp.marker()
      assert.is_truthy(s:find("¶1", 1, true))
      assert.is_falsy(s:find("§", 1, true))
    end)

    it("renders §N¶M for in-section paragraphs", function()
      compute_for({
        "## §1",
        "",
        "Para in §1",
      })
      vim.g.statusline_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_buf(bufnr)
      vim.v.lnum = 3
      local s = mp.marker()
      assert.is_truthy(s:find("§1", 1, true))
      assert.is_truthy(s:find("¶1", 1, true))
    end)

    it("renders dotted §N.M¶K for nested paragraphs", function()
      compute_for({
        "## §1",
        "",
        "### §1.1",
        "",
        "Para in §1.1",
      })
      vim.g.statusline_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_buf(bufnr)
      vim.v.lnum = 5
      local s = mp.marker()
      assert.is_truthy(s:find("§1.1", 1, true))
      assert.is_truthy(s:find("¶1", 1, true))
    end)

    it("renders the heading's path on the heading line", function()
      compute_for({
        "## §1",
        "",
        "### §1.1",
      })
      vim.g.statusline_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_buf(bufnr)
      vim.v.lnum = 3
      local s = mp.marker()
      assert.is_truthy(s:find("§1.1", 1, true))
      assert.is_falsy(s:find("¶", 1, true))
    end)

    it("renders blank padding for non-block lines", function()
      compute_for({
        "## §1",
        "",
        "Para",
      })
      vim.g.statusline_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_buf(bufnr)
      vim.v.lnum = 2
      local s = mp.marker()
      assert.is_truthy(s:match("^%s+$"))
    end)
  end)

  it("ignores frontmatter when numbering paragraphs", function()
    local data = compute_for({
      "---",
      "title: My Post",
      "tags: [nvim, mdx]",
      "---",
      "",
      "First body paragraph.",
      "",
      "Second body paragraph.",
    })
    assert.are.same({ [6] = b({}, 1), [8] = b({}, 2) }, data.blocks)
  end)

  describe("_advance_heading", function()
    it("numbers sequential H2 siblings", function()
      local path, counters = {}, {}
      mp._advance_heading(path, counters, 2)
      assert.are.same({ 1 }, path)
      mp._advance_heading(path, counters, 2)
      assert.are.same({ 2 }, path)
    end)

    it("nests H3 under the current H2 and resets deeper levels on the next H2", function()
      local path, counters = {}, {}
      mp._advance_heading(path, counters, 2)
      mp._advance_heading(path, counters, 3)
      assert.are.same({ 1, 1 }, path)
      mp._advance_heading(path, counters, 3)
      assert.are.same({ 1, 2 }, path)
      mp._advance_heading(path, counters, 2)
      assert.are.same({ 2 }, path)
    end)

    it("fills skipped intermediate levels with zero", function()
      local path, counters = {}, {}
      mp._advance_heading(path, counters, 4)
      assert.are.same({ 0, 0, 1 }, path)
    end)
  end)

  describe("_render_markers", function()
    it("pads markers to a common width and returns the blank pad", function()
      local markers, empty = mp._render_markers(
        { [2] = { path = { 1 }, paragraph = 3 } },
        { [1] = { path = { 1 } } }
      )
      -- Heading lines carry the brighter MarkdownSectionAnchor group; block ¶
      -- counts stay dim (Comment).
      assert.are.equal("%#MarkdownSectionAnchor#§1    %*", markers[1])
      assert.are.equal("%#Comment#§1¶3  %*", markers[2])
      assert.are.equal("      ", empty)
    end)

    it("renders a pre-heading block as just ¶n", function()
      local markers = mp._render_markers({ [1] = { path = {}, paragraph = 1 } }, {})
      assert.are.equal("%#Comment#¶1    %*", markers[1])
    end)
  end)
end)
