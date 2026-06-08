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

  describe("chain_at", function()
    -- function (rows 0..6) containing a sibling if (1..2) and the cursor's
    -- if (3..5); cursor on row 4.
    local blocks = {
      { s = 0, e = 6, col = 0 }, -- 1: function
      { s = 1, e = 2, col = 2 }, -- 2: sibling if
      { s = 3, e = 5, col = 2 }, -- 3: cursor's if
    }

    it("returns the innermost containing block as active", function()
      local chain = bg.chain_at(blocks, 4)
      assert.are.equal(3, chain.active)
    end)

    it("includes the parent in the chain set", function()
      local chain = bg.chain_at(blocks, 4)
      assert.is_true(chain.set[1]) -- function (parent)
      assert.is_true(chain.set[3]) -- the if (innermost)
    end)

    it("excludes sibling blocks the cursor is not inside", function()
      local chain = bg.chain_at(blocks, 4)
      assert.is_nil(chain.set[2]) -- sibling if
    end)

    it("has no active block when the cursor is outside every block", function()
      local chain = bg.chain_at(blocks, 10)
      assert.is_nil(chain.active)
    end)

    it("picks the deeper block on an extent tie via larger col", function()
      local tied = {
        { s = 0, e = 2, col = 0 },
        { s = 0, e = 2, col = 2 },
      }
      assert.are.equal(2, bg.chain_at(tied, 1).active)
    end)
  end)

  describe("guides_at", function()
    local blocks = {
      { s = 0, e = 6, col = 0 }, -- function
      { s = 1, e = 2, col = 2 }, -- sibling if
      { s = 3, e = 5, col = 2 }, -- cursor's if
    }
    local chain = bg.chain_at(blocks, 4) -- active=3, set={1,3}

    it("classifies the innermost block as active and the parent as chain", function()
      -- row 4, indented past col 2 (e.g. body at col 4)
      local guides = bg.guides_at(blocks, chain, 4, 4)
      assert.are.same({
        { col = 0, tier = "chain" }, -- function
        { col = 2, tier = "active" }, -- cursor's if
      }, guides)
    end)

    it("marks a sibling block's guide as dim", function()
      -- row 2 is inside the sibling if (block 2) and the function (block 1)
      local guides = bg.guides_at(blocks, chain, 2, 4)
      assert.are.same({
        { col = 0, tier = "chain" }, -- function (in chain)
        { col = 2, tier = "dim" }, -- sibling if (not in chain)
      }, guides)
    end)

    it("omits a guide when the line's indent does not reach past its col", function()
      -- row 4, indent only 2 → the col-2 guide is gated out (cell has code),
      -- but the col-0 function guide still draws.
      local guides = bg.guides_at(blocks, chain, 4, 2)
      assert.are.same({ { col = 0, tier = "chain" } }, guides)
    end)

    it("draws every covering guide on a blank line (math.huge indent)", function()
      local guides = bg.guides_at(blocks, chain, 4, math.huge)
      assert.are.equal(2, #guides)
    end)

    it("returns dim guides when there is no chain", function()
      local guides = bg.guides_at(blocks, nil, 4, 4)
      assert.are.same({
        { col = 0, tier = "dim" },
        { col = 2, tier = "dim" },
      }, guides)
    end)
  end)
end)
