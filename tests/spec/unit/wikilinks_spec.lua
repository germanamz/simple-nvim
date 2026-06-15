local wl = require("config.wikilinks")

describe("config.wikilinks", function()
  describe("_wikilink_at", function()
    -- "see [[a/b]] end"  -> [[a/b]] spans columns 5..11
    local line = "see [[a/b]] end"

    it("returns the inner target when the column is inside the link", function()
      assert.are.equal("a/b", wl._wikilink_at(line, 6))
    end)

    it("matches on the opening and closing brackets", function()
      assert.are.equal("a/b", wl._wikilink_at(line, 5))
      assert.are.equal("a/b", wl._wikilink_at(line, 11))
    end)

    it("returns nil when the column is outside any link", function()
      assert.is_nil(wl._wikilink_at(line, 1))
      assert.is_nil(wl._wikilink_at(line, 13))
    end)

    it("picks the link under the cursor when there are several", function()
      local l = "[[one]] and [[two]]"
      assert.are.equal("one", wl._wikilink_at(l, 3))
      assert.are.equal("two", wl._wikilink_at(l, 15))
    end)

    it("returns nil when the line has no wikilink", function()
      assert.is_nil(wl._wikilink_at("just [a](b) text", 7))
    end)
  end)

  describe("_normalize_target", function()
    it("appends .md to a bare path target", function()
      assert.are.equal("tickets/spcx-watch.md", wl._normalize_target("tickets/spcx-watch"))
    end)

    it("drops the alias", function()
      assert.are.equal(
        "food/meals/chicken-salad.md",
        wl._normalize_target("food/meals/chicken-salad|Chicken salad")
      )
    end)

    it("drops a heading anchor", function()
      assert.are.equal("notes/x.md", wl._normalize_target("notes/x#some-heading"))
    end)

    it("drops both heading and alias", function()
      assert.are.equal("notes/x.md", wl._normalize_target("notes/x#heading|Alias"))
    end)

    it("keeps an explicit extension as-is", function()
      assert.are.equal("assets/diagram.png", wl._normalize_target("assets/diagram.png"))
    end)

    it("returns nil for an empty target", function()
      assert.is_nil(wl._normalize_target("|just an alias"))
    end)
  end)

  describe("_links_in_lines", function()
    it("extracts display text (alias or raw target) and resolved target", function()
      local got = wl._links_in_lines({
        "see [[lola/product]] and [[food/x|Tasty]] here",
      })
      assert.are.same({
        { display = "lola/product", target = "lola/product.md" },
        { display = "Tasty", target = "food/x.md" },
      }, got)
    end)

    it("skips wikilinks inside fenced code", function()
      assert.are.same({}, wl._links_in_lines({ "```", "[[raw]]", "```" }))
    end)
  end)

  describe("_match_at", function()
    -- rendered preview line; "lola/product" spans cols 6..17
    local links = {
      { display = "lola/product", target = "lola/product.md" },
      { display = "food/x", target = "food/x.md" },
    }
    local line = "docs lola/product and food/x end"

    it("returns the link whose display covers the cursor column", function()
      local m = wl._match_at(links, line, 8)
      assert.are.equal(1, #m)
      assert.are.equal("lola/product.md", m[1].target)
    end)

    it("returns empty when the cursor is on plain prose", function()
      assert.are.same({}, wl._match_at(links, line, 1))
    end)

    it("matches the second link when the cursor is on it", function()
      local m = wl._match_at(links, line, 24)
      assert.are.equal("food/x.md", m[1].target)
    end)
  end)
end)
