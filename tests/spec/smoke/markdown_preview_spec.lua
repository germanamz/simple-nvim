local nvim_env = require("tests.helpers.nvim_env")

-- Glow-agnostic: these assert wiring and lifecycle, not glow's rendered output,
-- so they pass whether or not the `glow` binary is installed on the test machine.
describe("smoke: markdown preview (glow)", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  it("requires config.markdown_preview cleanly", function()
    package.loaded["config.markdown_preview"] = nil
    local ok, err = pcall(require, "config.markdown_preview")
    assert.is_true(ok, "failed to require: " .. tostring(err))
  end)

  it("registers the <leader>m markdown group in which-key", function()
    local spec = require("plugins.which-key")[1].opts.spec
    local found
    for _, entry in ipairs(spec) do
      if entry[1] == "<leader>m" then
        found = entry
      end
    end
    assert.is_not_nil(found, "no <leader>m group entry in which-key spec")
    assert.are.equal("markdown", found.group)
  end)

  it("maps buffer-local <leader>mp with a desc in markdown buffers", function()
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "markdown"
    local map = vim.fn.maparg("<leader>mp", "n", false, true)
    assert.is_false(vim.tbl_isempty(map), "<leader>mp not mapped in markdown buffer")
    assert.are.equal("Toggle markdown preview", map.desc)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("open then close returns to the baseline window count without error", function()
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Title", "", "some text" })
    local mp = require("config.markdown_preview")
    local before = #vim.api.nvim_list_wins()
    assert.has_no.errors(function()
      mp.open(buf)
      mp.close(buf)
    end)
    assert.are.equal(before, #vim.api.nvim_list_wins())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
