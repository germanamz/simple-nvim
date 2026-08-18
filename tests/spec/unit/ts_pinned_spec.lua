describe("config.ts_pinned", function()
  local M

  before_each(function()
    package.loaded["config.ts_pinned"] = nil
    package.loaded["nvim-treesitter.parsers"] = nil
    M = require("config.ts_pinned")
  end)

  after_each(function()
    package.loaded["nvim-treesitter.parsers"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "ts_pinned")
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

  it("applies revisions when nvim-treesitter fires User TSUpdate", function()
    -- install() reload_parsers() throws away anything written before the call,
    -- then fires this event. Applying on the event is the only thing the
    -- installer actually sees.
    local parsers = { lua = { install_info = { revision = "old-lua" } } }
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.setup({ lua = "new-lua" })
    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })

    assert.are.equal("new-lua", parsers.lua.install_info.revision)
  end)

  it("re-applies on every TSUpdate, not just the first", function()
    local parsers = { lua = { install_info = { revision = "old-lua" } } }
    package.loaded["nvim-treesitter.parsers"] = parsers
    M.setup({ lua = "new-lua" })

    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })
    parsers.lua.install_info.revision = "clobbered-by-reload"
    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })

    assert.are.equal("new-lua", parsers.lua.install_info.revision)
  end)
end)

describe("config.ts_pinned out-of-tree parsers", function()
  local M

  before_each(function()
    package.loaded["config.ts_pinned"] = nil
    package.loaded["nvim-treesitter.parsers"] = nil
    M = require("config.ts_pinned")
  end)

  after_each(function()
    package.loaded["nvim-treesitter.parsers"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "ts_pinned")
  end)

  local FGA_URL = "https://github.com/matoous/tree-sitter-fga"

  it("registers a parser nvim-treesitter has no entry for, at the pinned revision", function()
    local parsers = { lua = { install_info = { revision = "old-lua" } } }
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.apply({ lua = "new-lua", fga = "fga-rev" }, { fga = { url = FGA_URL } })

    assert.are.same({ url = FGA_URL, revision = "fga-rev" }, parsers.fga.install_info)
    assert.are.equal("new-lua", parsers.lua.install_info.revision)
  end)

  it("does not register an out-of-tree parser that has no pin", function()
    -- The pin file is the single source of truth for WHICH parsers get
    -- installed; a url with no revision must not sneak a parser in unpinned.
    local parsers = {}
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.apply({}, { fga = { url = FGA_URL } })

    assert.is_nil(parsers.fga)
  end)

  it("leaves an out-of-tree entry alone once upstream ships one, but still pins it", function()
    -- If nvim-treesitter later adds the parser itself, the bundled entry (its
    -- url, tier, maintainers) wins; only the revision is ours.
    local parsers = {
      fga = {
        install_info = { url = "https://upstream/tree-sitter-fga", revision = "bundled" },
        tier = 2,
      },
    }
    package.loaded["nvim-treesitter.parsers"] = parsers

    M.apply({ fga = "fga-rev" }, { fga = { url = FGA_URL } })

    assert.are.equal("https://upstream/tree-sitter-fga", parsers.fga.install_info.url)
    assert.are.equal("fga-rev", parsers.fga.install_info.revision)
    assert.are.equal(2, parsers.fga.tier)
  end)

  it(
    "never marks an out-of-tree parser as tier 4 (install() skips 'unsupported' entries)",
    function()
      local parsers = {}
      package.loaded["nvim-treesitter.parsers"] = parsers

      M.apply({ fga = "fga-rev" }, { fga = { url = FGA_URL } })

      assert.is_not.equal(4, parsers.fga.tier)
    end
  )

  it("registers out-of-tree parsers on every User TSUpdate", function()
    -- reload_parsers() rebuilds the table from the plugin's source, which has
    -- no fga entry, so registration has to happen on the event, like the pins.
    local parsers = {}
    package.loaded["nvim-treesitter.parsers"] = parsers
    M.setup({ fga = "fga-rev" }, { fga = { url = FGA_URL } })

    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })
    assert.are.equal("fga-rev", parsers.fga.install_info.revision)

    parsers.fga = nil -- what a reload does
    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })
    assert.are.same({ url = FGA_URL, revision = "fga-rev" }, parsers.fga.install_info)
  end)
end)
