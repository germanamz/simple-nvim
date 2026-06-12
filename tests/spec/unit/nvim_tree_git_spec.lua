-- Pins the pure directory-marker aggregation of the nvim-tree git decorator:
-- ancestors of a changed file get a marker, worktree changes dominating
-- base-only ones. (The decorator class itself needs a loaded nvim-tree, so it
-- is exercised by the smoke suite, not here.)
local nvim_tree_git = require("config.nvim_tree_git")

describe("config.nvim_tree_git._dir_markers", function()
  it("marks every ancestor directory of a changed file", function()
    local dirs = nvim_tree_git._dir_markers({ ["a/b/c.lua"] = " M" })
    assert.are.same({
      ["a"] = "SmartFilesModified",
      ["a/b"] = "SmartFilesModified",
    }, dirs)
  end)

  it("does not mark anything for top-level files", function()
    assert.are.same({}, nvim_tree_git._dir_markers({ ["c.lua"] = "??" }))
  end)

  it("marks base-only subtrees with the base group", function()
    local dirs = nvim_tree_git._dir_markers({ ["a/c.lua"] = "bM" })
    assert.are.same({ ["a"] = "SmartFilesBase" }, dirs)
  end)

  it("lets a worktree change dominate a base-only sibling", function()
    local dirs = nvim_tree_git._dir_markers({
      ["a/base.lua"] = "bA",
      ["a/work.lua"] = "MM",
    })
    assert.are.same({ ["a"] = "SmartFilesModified" }, dirs)
  end)
end)
