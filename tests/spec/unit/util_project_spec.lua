-- Pins util.project: the "is this directory an independent project root"
-- predicate. config.lsp_root asks it about tsconfig/jsconfig, config.js_toolchain
-- about package.json — one implementation so the two cannot drift apart.
local project = require("util.project")

describe("util.project.is_root", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local function touch(name)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write("{}\n")
    f:close()
  end

  it("is false for nil", function()
    assert.is_false(project.is_root(nil, { "package.json" }))
  end)

  it("is false when no marker is present", function()
    assert.is_false(project.is_root(dir, { "package.json" }))
  end)

  it("is true when the single marker is present", function()
    touch("package.json")
    assert.is_true(project.is_root(dir, { "package.json" }))
  end)

  it("is true when any one of several markers is present", function()
    touch("jsconfig.json")
    assert.is_true(project.is_root(dir, { "tsconfig.json", "jsconfig.json" }))
  end)

  it("is false for an empty marker list", function()
    touch("package.json")
    assert.is_false(project.is_root(dir, {}))
  end)

  it("is true when the marker is a directory, not a file", function()
    vim.fn.mkdir(dir .. "/package.json", "p")
    assert.is_true(project.is_root(dir, { "package.json" }))
  end)
end)
