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

  it("numbers consecutive prose paragraphs separated by blanks", function()
    local starts = compute_for({
      "First paragraph",
      "still first",
      "",
      "Second paragraph",
      "",
      "Third paragraph",
    })
    assert.are.same({ [1] = 1, [4] = 2, [6] = 3 }, starts)
  end)

  it("skips ATX headings", function()
    local starts = compute_for({
      "# Heading",
      "",
      "Paragraph one",
      "",
      "## Subheading",
      "",
      "Paragraph two",
    })
    assert.are.same({ [3] = 1, [7] = 2 }, starts)
  end)

  it("skips Setext headings (text + === / ---)", function()
    local starts = compute_for({
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
    assert.are.same({ [4] = 1, [9] = 2 }, starts)
  end)

  it("skips fenced code blocks", function()
    local starts = compute_for({
      "Para one",
      "",
      "```",
      "code line",
      "more code",
      "```",
      "",
      "Para two",
    })
    assert.are.same({ [1] = 1, [8] = 2 }, starts)
  end)

  it("skips list items", function()
    local starts = compute_for({
      "Para one",
      "",
      "- item a",
      "- item b",
      "",
      "1. ordered",
      "",
      "Para two",
    })
    assert.are.same({ [1] = 1, [8] = 2 }, starts)
  end)

  it("skips block quotes", function()
    local starts = compute_for({
      "Para one",
      "",
      "> quoted",
      "",
      "Para two",
    })
    assert.are.same({ [1] = 1, [5] = 2 }, starts)
  end)

  it("skips tables", function()
    local starts = compute_for({
      "Para one",
      "",
      "| a | b |",
      "|---|---|",
      "| 1 | 2 |",
      "",
      "Para two",
    })
    assert.are.same({ [1] = 1, [7] = 2 }, starts)
  end)

  it("skips horizontal rules", function()
    local starts = compute_for({
      "Para one",
      "",
      "---",
      "",
      "***",
      "",
      "Para two",
    })
    assert.are.same({ [1] = 1, [7] = 2 }, starts)
  end)

  it("sets colorcolumn=81 on the current window", function()
    vim.api.nvim_set_current_buf(bufnr)
    compute_for({ "line one", "line two", "line three" })
    assert.are.equal("81", vim.wo.colorcolumn)
  end)

  it("sets ColorColumn bg darker than Normal so it stands apart from CursorLine", function()
    vim.api.nvim_set_hl(0, "Normal", { bg = "#202020" })
    package.loaded["config.markdown_paragraphs"] = nil
    require("config.markdown_paragraphs")
    local hl = vim.api.nvim_get_hl(0, { name = "ColorColumn", link = false })
    assert.is_not_nil(hl.bg)
    local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    assert.is_true(hl.bg < normal_bg)
  end)

  it("sets a custom statuscolumn on the current window", function()
    vim.api.nvim_set_current_buf(bufnr)
    compute_for({ "para" })
    assert.is_truthy(vim.wo.statuscolumn:find("_markdown_paragraph_marker", 1, true))
    assert.is_true(vim.w.markdown_writing_active)
  end)

  it("detach_window restores statuscolumn, clears colorcolumn, and clears the active flag", function()
    vim.api.nvim_set_current_buf(bufnr)
    compute_for({ "para" })
    mp.detach_window()
    assert.are.equal("", vim.wo.statuscolumn)
    assert.are.equal("", vim.wo.colorcolumn)
    assert.is_nil(vim.w.markdown_writing_active)
  end)

  describe("frontmatter_end", function()
    local function set(lines)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      return mp.frontmatter_end(bufnr)
    end

    it("returns 0 when buffer has no frontmatter", function()
      assert.are.equal(0, set({ "Body line", "Another" }))
    end)

    it("returns the line of the closing --- when frontmatter is present", function()
      assert.are.equal(
        4,
        set({
          "---",
          "title: Hello",
          "tags: [a, b]",
          "---",
          "",
          "Body",
        })
      )
    end)

    it("returns 0 for unclosed frontmatter", function()
      assert.are.equal(0, set({ "---", "title: Hello", "Body without close" }))
    end)

    it("returns 0 when --- is not on line 1", function()
      assert.are.equal(0, set({ "", "---", "title: Hello", "---" }))
    end)
  end)

  it("ignores frontmatter when numbering paragraphs", function()
    local starts = compute_for({
      "---",
      "title: My Post",
      "tags: [nvim, mdx]",
      "---",
      "",
      "First body paragraph.",
      "",
      "Second body paragraph.",
    })
    assert.are.same({ [6] = 1, [8] = 2 }, starts)
  end)
end)
