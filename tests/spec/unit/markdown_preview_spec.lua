local mp = require("config.markdown_preview")

local function t(line)
  return mp._transform_links({ line })[1]
end

describe("config.markdown_preview", function()
  describe("_transform_links (wikilinks)", function()
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

    it("leaves plain text without links unchanged", function()
      assert.are.equal("just some text", t("just some text"))
    end)

    it("does not rewrite wikilinks inside inline code", function()
      assert.are.equal("see `[[raw]]` here", t("see `[[raw]]` here"))
    end)

    it("rewrites outside but not inside an inline code span on the same line", function()
      assert.are.equal("[a](#) `[[b]]`", t("[[a]] `[[b]]`"))
    end)

    it("does not rewrite wikilinks inside fenced code blocks", function()
      local out = mp._transform_links({ "```", "[[raw]]", "```" })
      assert.are.same({ "```", "[[raw]]", "```" }, out)
    end)
  end)

  -- glow appends a markdown link's destination as a visible URL tail, resolving a
  -- relative path against the temp file's directory -- a noisy absolute temp path
  -- for links to sibling docs. Local-file destinations are rewritten to a bare
  -- anchor (`#`) so glow shows just the link text; real URLs and in-doc anchors
  -- are kept, since those tails are meaningful.
  describe("_transform_links (standard links)", function()
    it("neutralizes a relative file-link destination", function()
      assert.are.equal("[PRODUCT.md](#)", t("[PRODUCT.md](PRODUCT.md)"))
    end)

    it("neutralizes a relative subpath destination", function()
      assert.are.equal("[cli docs](#)", t("[cli docs](docs/cli/)"))
    end)

    it("neutralizes a ./ or ../ relative destination", function()
      assert.are.equal("[up](#)", t("[up](../sibling.md)"))
    end)

    it("neutralizes an absolute file-path destination", function()
      assert.are.equal("[p](#)", t("[p](/var/folders/x/PRODUCT.md)"))
    end)

    it("keeps an http(s) URL destination", function()
      assert.are.equal("[ex](https://example.com)", t("[ex](https://example.com)"))
    end)

    it("keeps a mailto: destination", function()
      assert.are.equal("[me](mailto:a@b.com)", t("[me](mailto:a@b.com)"))
    end)

    it("keeps a pure in-doc fragment anchor", function()
      assert.are.equal("[h](#heading)", t("[h](#heading)"))
    end)

    it("leaves images (![alt](src)) unchanged", function()
      assert.are.equal("![alt](img.png)", t("![alt](img.png)"))
    end)

    it("neutralizes multiple file links on one line", function()
      assert.are.equal("[a](#) and [b](#)", t("[a](a.md) and [b](b.md)"))
    end)

    it("preserves surrounding text around a file link", function()
      assert.are.equal("see [a](#) here", t("see [a](b.md) here"))
    end)

    it("does not rewrite a file link inside an inline code span", function()
      assert.are.equal("use `[a](b.md)` verbatim", t("use `[a](b.md)` verbatim"))
    end)

    it("does not rewrite a file link inside a fenced code block", function()
      local out = mp._transform_links({ "```", "[a](b.md)", "```" })
      assert.are.same({ "```", "[a](b.md)", "```" }, out)
    end)

    it("handles a wikilink and a file link on the same line", function()
      assert.are.equal("[a](#) and [b](#)", t("[[a]] and [b](b.md)"))
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
