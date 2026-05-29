local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: which-key LSP keymap labels", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  -- Neovim 0.11 ships the default `gr*` LSP keymaps without a `desc`, so
  -- which-key falls back to the raw Lua function. The plugin spec relabels them
  -- via opts.spec; assert those entries are present so the labels don't silently
  -- regress to function references.
  it("relabels the default gr* LSP keymaps via opts.spec", function()
    local spec = require("plugins.which-key")[1].opts.spec
    local by_lhs = {}
    for _, entry in ipairs(spec) do
      by_lhs[entry[1]] = entry
    end

    assert.are.equal("lsp", (by_lhs["gr"] or {}).group)
    assert.are.equal("Code action", (by_lhs["gra"] or {}).desc)
    assert.are.equal("Rename", (by_lhs["grn"] or {}).desc)
    assert.are.equal("References", (by_lhs["grr"] or {}).desc)
    assert.are.equal("Implementation", (by_lhs["gri"] or {}).desc)
    assert.are.equal("Type definition", (by_lhs["grt"] or {}).desc)
    assert.are.equal("Document symbols", (by_lhs["gO"] or {}).desc)
  end)
end)
