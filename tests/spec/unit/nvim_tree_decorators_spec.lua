-- Pins the pure node predicates behind the nvim-tree decorators. The Decorator
-- classes need a loaded nvim-tree, so their construction and rendered colours
-- are exercised by the e2e suite (nvim_tree_decorators_spec); here we test the
-- FIELD-ONLY dispatch that decides which nodes get coloured. Field-only is the
-- point: a custom decorator is handed a sanitized api-node clone without the
-- Node metatable, so a node method (e.g. node:is_dotfile()) is nil and crashes.
local dotfolder = require("config.nvim_tree_dotfolder")
local symlink = require("config.nvim_tree_symlink")

describe("config.nvim_tree_dotfolder._is_dotfolder", function()
  it("matches a dot-prefixed directory", function()
    assert.is_true(dotfolder._is_dotfolder({ type = "directory", absolute_path = "/p/.git" }))
    assert.is_true(
      dotfolder._is_dotfolder({ type = "directory", absolute_path = "/deep/nest/.github" })
    )
  end)

  it("tolerates a trailing slash on the directory path", function()
    assert.is_true(dotfolder._is_dotfolder({ type = "directory", absolute_path = "/p/.cache/" }))
  end)

  it("does NOT match a dot-FILE (files keep their colour)", function()
    assert.is_false(dotfolder._is_dotfolder({ type = "file", absolute_path = "/p/.gitignore" }))
  end)

  it("does NOT match a plain directory", function()
    assert.is_false(dotfolder._is_dotfolder({ type = "directory", absolute_path = "/p/lua" }))
  end)

  it("does NOT match a dot-prefixed symlink (type 'link', not 'directory')", function()
    assert.is_false(dotfolder._is_dotfolder({ type = "link", absolute_path = "/p/.link" }))
  end)

  it("is defensive against a missing absolute_path", function()
    assert.is_false(dotfolder._is_dotfolder({ type = "directory" }))
  end)
end)

describe("config.nvim_tree_symlink._is_symlink", function()
  it("matches file and directory links alike (both report type 'link')", function()
    assert.is_true(symlink._is_symlink({ type = "link", absolute_path = "/p/file-link" }))
    assert.is_true(symlink._is_symlink({ type = "link", absolute_path = "/p/dir-link" }))
  end)

  it("does NOT match regular files or directories", function()
    assert.is_false(symlink._is_symlink({ type = "file", absolute_path = "/p/x.lua" }))
    assert.is_false(symlink._is_symlink({ type = "directory", absolute_path = "/p/d" }))
  end)
end)

-- The factory's builder registers a ColorScheme re-highlight autocmd. It must
-- live in a per-decorator named augroup (clear = true): a package.loaded reset
-- plus re-require rebuilds the closure, and an ungrouped autocmd would stack a
-- duplicate instead of replacing.
describe("config.nvim_tree_hl_decorator ColorScheme registration", function()
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
    package.loaded["config.nvim_tree_hl_decorator"] = nil
    package.loaded["config.nvim_tree_dotfolder"] = nil
    package.loaded["config.nvim_tree_symlink"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_hl_NvimTreeHiddenFolderHL")
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_hl_NvimTreeSymlinkMark")
  end)

  it("keeps exactly one autocmd across a package.loaded reload", function()
    local baseline = colorscheme_count()
    require("config.nvim_tree_dotfolder").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())

    package.loaded["config.nvim_tree_hl_decorator"] = nil
    package.loaded["config.nvim_tree_dotfolder"] = nil
    require("config.nvim_tree_dotfolder").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())
  end)

  it("keeps sibling decorators independent (augroup unique per spec)", function()
    local baseline = colorscheme_count()
    require("config.nvim_tree_dotfolder").decorator()
    require("config.nvim_tree_symlink").decorator()
    assert.are.equal(baseline + 2, colorscheme_count())
  end)
end)
