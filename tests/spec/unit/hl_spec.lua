-- util.hl is the shared colour recipe behind the three nvim-tree decorators
-- (grey git-ignored, blue dot-folders, teal symlinks). Pins the pure channel
-- blend and the define_dim resolution — explicit colour, source-group hue, and
-- the fallback link when no colour is resolvable.
local hl = require("util.hl")

describe("util.hl.blend", function()
  it("blends channel-wise at the midpoint", function()
    assert.are.equal("#808080", hl.blend(0xffffff, 0x000000, 0.5))
  end)

  it("alpha=1 keeps the foreground unchanged", function()
    assert.are.equal("#123456", hl.blend(0x123456, 0x000000, 1))
  end)

  it("alpha=0 collapses to the background", function()
    assert.are.equal("#abcdef", hl.blend(0x123456, 0xabcdef, 0))
  end)

  it("reproduces the dot-folder blue recipe (#0969da @ .85 over white)", function()
    assert.are.equal("#2e80e0", hl.blend(0x0969da, 0xffffff, 0.85))
  end)
end)

describe("util.hl.define_dim", function()
  local orig_normal

  before_each(function()
    -- define_dim reads Normal's background live; the unit harness has no
    -- colorscheme, so pin a known background and restore it afterwards.
    orig_normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    vim.api.nvim_set_hl(0, "Normal", { bg = "#000000" })
  end)

  after_each(function()
    vim.api.nvim_set_hl(0, "Normal", orig_normal)
    pcall(vim.api.nvim_set_hl, 0, "HlSpecTmp", {})
    pcall(vim.api.nvim_set_hl, 0, "HlSpecSrc", {})
  end)

  it("blends an explicit colour toward Normal's background", function()
    hl.define_dim("HlSpecTmp", { color = "#ffffff", alpha = 0.5 })
    assert.are.equal(0x808080, vim.api.nvim_get_hl(0, { name = "HlSpecTmp", link = false }).fg)
  end)

  it("derives the base hue from a source group's foreground", function()
    vim.api.nvim_set_hl(0, "HlSpecSrc", { fg = "#ffffff" })
    hl.define_dim("HlSpecTmp", { source = "HlSpecSrc", alpha = 1 })
    assert.are.equal(0xffffff, vim.api.nvim_get_hl(0, { name = "HlSpecTmp", link = false }).fg)
  end)

  it("links the fallback group when no base colour resolves", function()
    -- Undefined source (no fg) and no explicit colour -> fall back to the link.
    hl.define_dim("HlSpecTmp", { source = "HlSpecNoSuchGroup", fallback = "NonText" })
    assert.are.equal("NonText", vim.api.nvim_get_hl(0, { name = "HlSpecTmp", link = true }).link)
  end)
end)
