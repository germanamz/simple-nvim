local mp = require("config.markdown_preview")

local function t(line)
  return mp._transform_wikilinks({ line })[1]
end

describe("config.markdown_preview", function()
  describe("_transform_wikilinks", function()
    -- Anchor destination so glow shows only the link text (no temp-path URL tail).
    it("converts a bare wikilink, keeping the target text", function()
      assert.are.equal("[My Note](#)", t("[[My Note]]"))
    end)

    it("converts an aliased wikilink, using the alias as link text", function()
      assert.are.equal("[Display](#)", t("[[notes/path|Display]]"))
    end)

    it("keeps the target text verbatim for bare links (slashes, spaces)", function()
      assert.are.equal("[a/b c](#)", t("[[a/b c]]"))
    end)

    it("keeps parentheses in the displayed text", function()
      assert.are.equal("[x (y)](#)", t("[[x (y)]]"))
    end)

    it("converts multiple wikilinks on one line", function()
      assert.are.equal("[a](#) and [b](#)", t("[[a]] and [[b]]"))
    end)

    it("leaves text without wikilinks unchanged", function()
      assert.are.equal("just [a](b) and text", t("just [a](b) and text"))
    end)

    it("does not rewrite wikilinks inside inline code", function()
      assert.are.equal("see `[[raw]]` here", t("see `[[raw]]` here"))
    end)

    it("rewrites outside but not inside an inline code span on the same line", function()
      assert.are.equal("[a](#) `[[b]]`", t("[[a]] `[[b]]`"))
    end)

    it("does not rewrite wikilinks inside fenced code blocks", function()
      local out = mp._transform_wikilinks({ "```", "[[raw]]", "```" })
      assert.are.same({ "```", "[[raw]]", "```" }, out)
    end)
  end)

  describe("_frontmatter_lines", function()
    it("returns 0 when there is no frontmatter", function()
      assert.are.equal(0, mp._frontmatter_lines({ "# Heading", "body" }))
    end)

    it("counts both fences of a frontmatter block", function()
      -- closing --- on line 4 -> 4 leading frontmatter lines
      assert.are.equal(
        4,
        mp._frontmatter_lines({ "---", "title: x", "tags: [a]", "---", "", "# H" })
      )
    end)

    it("returns 0 when the opening line is not a fence", function()
      assert.are.equal(0, mp._frontmatter_lines({ "", "---", "title: x", "---" }))
    end)

    it("returns 0 for an unterminated frontmatter block", function()
      assert.are.equal(0, mp._frontmatter_lines({ "---", "title: x", "# H" }))
    end)
  end)
end)
