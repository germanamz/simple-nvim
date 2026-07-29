-- Pins the two pure seams of the sticky ancestor-folder header: the ancestor
-- walk (_ancestors) and the visibility filter (_pinned). Both take plain values
-- and return plain values, so neither needs a running nvim-tree — the live
-- render, the extmark copy, and the overlay lifetime are exercised in e2e.
--
-- The filter is a port of nvim-treesitter-context's mode="cursor" rule: an
-- ancestor is pinned once it is no longer visible, where "visible" accounts for
-- the rows the header will itself cover. That self-reference is what produces
-- the cascade case below, and it is the behaviour most worth pinning.
local ctx = require("config.nvim_tree_context")

describe("config.nvim_tree_context", function()
  describe("_ancestors (cursor node -> ancestor buffer lines)", function()
    -- A tree whose root has no entry in line_of, exactly as the real map
    -- behaves: core.get_nodes_starting_line() starts the map BELOW the root
    -- header row, so the root node is never a value in it.
    local function fixture()
      local root = {}
      local apps = { parent = root }
      local src = { parent = apps }
      local comps = { parent = src }
      local file = { parent = comps }
      return file, { [apps] = 2, [src] = 3, [comps] = 4, [file] = 5 }, root
    end

    it("returns the ancestor lines root-most first", function()
      local file, line_of = fixture()
      assert.are.same({ 2, 3, 4 }, ctx._ancestors(file, line_of))
    end)

    it("stops before a parent that has no line, so the root row is excluded", function()
      local file, line_of, root = fixture()
      assert.is_nil(line_of[root])
      local lines = ctx._ancestors(file, line_of)
      assert.are.equal(3, #lines, "root row leaked into the chain: " .. vim.inspect(lines))
    end)

    it("returns an empty chain for a nil node", function()
      local _, line_of = fixture()
      assert.are.same({}, ctx._ancestors(nil, line_of))
    end)

    it("returns an empty chain for a top-level node", function()
      local _, line_of, root = fixture()
      assert.are.same({}, ctx._ancestors({ parent = root }, line_of))
    end)
  end)

  describe("_pinned (ancestor lines -> header height)", function()
    it("pins nothing while the whole chain is still on screen", function()
      -- topline 1: no ancestor has scrolled off, so the header is empty and
      -- costs zero rows.
      assert.are.equal(0, ctx._pinned({ 2, 3, 4 }, 1, 6))
    end)

    it("pins an ancestor that has scrolled above the viewport", function()
      -- line 2 is above topline 3; line 10 is far below the one-row header.
      assert.are.equal(1, ctx._pinned({ 2, 10 }, 3, 30))
    end)

    it("cascades: a pinned row covers the next ancestor, pulling it in", function()
      -- topline 4, so `2` and `3` are off-screen. Pinning them makes the header
      -- two rows tall, which covers line 4 — so line 4 is pinned too.
      assert.are.equal(3, ctx._pinned({ 2, 3, 4 }, 4, 30))
    end)

    it("never grows tall enough to cover the cursor row", function()
      -- cap = cursor_line - topline = 1, so the cascade above stops at one row.
      assert.are.equal(1, ctx._pinned({ 2, 3, 4 }, 4, 5))
    end)

    it("pins nothing when the cursor sits on the top row", function()
      assert.are.equal(0, ctx._pinned({ 2, 3, 4 }, 4, 4))
    end)

    it("pins nothing for an empty chain", function()
      assert.are.equal(0, ctx._pinned({}, 40, 60))
    end)
  end)
end)
