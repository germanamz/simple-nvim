local bg = require("config.block_guides")

describe("config.block_guides", function()
  describe("_indent_width", function()
    it("counts leading spaces", function()
      assert.are.equal(4, bg._indent_width("    code", 2))
    end)

    it("returns 0 for no indentation", function()
      assert.are.equal(0, bg._indent_width("code", 2))
    end)

    it("expands a leading tab to the next tab stop", function()
      assert.are.equal(4, bg._indent_width("\tcode", 4))
    end)

    it("mixes spaces then a tab, snapping to the tab stop", function()
      -- 2 spaces (w=2), then a tab advances to the next multiple of 4 → 4
      assert.are.equal(4, bg._indent_width("  \tcode", 4))
    end)

    it("stops at the first non-whitespace character", function()
      assert.are.equal(2, bg._indent_width("  x  y", 2))
    end)
  end)
end)
