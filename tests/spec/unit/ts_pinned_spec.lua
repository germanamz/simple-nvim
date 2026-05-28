describe("config.ts_pinned", function()
  local M

  before_each(function()
    package.loaded["config.ts_pinned"] = nil
    package.loaded["nvim-treesitter.parsers"] = nil
    M = require("config.ts_pinned")
  end)

  after_each(function()
    package.loaded["nvim-treesitter.parsers"] = nil
  end)

  it("overrides install_info.revision for known parsers", function()
    local parsers = {
      lua = { install_info = { revision = "old-lua" } },
      python = { install_info = { revision = "old-py" } },
    }
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.apply({ lua = "new-lua", python = "new-py" })

    assert.are.equal("new-lua", parsers.lua.install_info.revision)
    assert.are.equal("new-py", parsers.python.install_info.revision)
  end)

  it("ignores revisions for parsers not in the registry", function()
    local parsers = { lua = { install_info = { revision = "old-lua" } } }
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.apply({ lua = "new-lua", nosuchlang = "whatever" })

    assert.are.equal("new-lua", parsers.lua.install_info.revision)
    assert.is_nil(parsers.nosuchlang)
  end)

  it("skips parsers that have no install_info", function()
    local parsers = { lua = {} }
    package.loaded["nvim-treesitter.parsers"] = parsers

    assert.has_no.errors(function()
      M.apply({ lua = "new-lua" })
    end)
    assert.is_nil(parsers.lua.install_info)
  end)

  it("no-ops when nvim-treesitter.parsers cannot be required", function()
    package.loaded["nvim-treesitter.parsers"] = nil
    package.preload["nvim-treesitter.parsers"] = function()
      error("not installed")
    end

    assert.has_no.errors(function()
      M.apply({ lua = "new-lua" })
    end)

    package.preload["nvim-treesitter.parsers"] = nil
  end)
end)
