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

-- decorator() registers a ColorScheme re-highlight autocmd. It must live in a
-- named augroup (clear = true): a package.loaded reset plus re-require empties
-- the module-scope Decorator memo, and an ungrouped autocmd would stack a
-- duplicate instead of replacing.
describe("config.nvim_tree_git.decorator ColorScheme registration", function()
  local saved_api

  local function colorscheme_count()
    return #vim.api.nvim_get_autocmds({ event = "ColorScheme" })
  end

  before_each(function()
    saved_api = package.loaded["nvim-tree.api"]
    package.loaded["nvim-tree.api"] = {
      Decorator = {
        extend = function()
          return {}
        end,
      },
    }
  end)

  after_each(function()
    package.loaded["nvim-tree.api"] = saved_api
    package.loaded["config.nvim_tree_git"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_git_hl")
  end)

  it("keeps exactly one autocmd across a package.loaded reload", function()
    local baseline = colorscheme_count()
    require("config.nvim_tree_git").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())

    package.loaded["config.nvim_tree_git"] = nil
    require("config.nvim_tree_git").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())
  end)
end)
