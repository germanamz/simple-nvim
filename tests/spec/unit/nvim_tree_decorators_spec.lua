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
