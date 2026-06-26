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

  -- The preview belongs to its file: it is shown only while that file is on
  -- screen, hides when the editor window swaps to another file, and restores
  -- when the file comes back. These need a real preview pane, so they require
  -- glow; without it they no-op (consistent with the rest of this file).
  it("auto-hides on switch away and restores on return", function()
    if vim.fn.executable("glow") ~= 1 then
      return
    end
    local wait = require("tests.helpers.wait")
    vim.cmd("only")
    vim.cmd("enew")
    local a = vim.api.nvim_get_current_buf()
    vim.bo[a].filetype = "markdown"
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "# A", "", "alpha" })
    local b = vim.api.nvim_create_buf(true, false)
    vim.bo[b].filetype = "markdown"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "# B", "", "beta" })

    local mp = require("config.markdown_preview")
    local base = #vim.api.nvim_list_wins()

    mp.open(a)
    wait.wait_for(function()
      return #vim.api.nvim_list_wins() == base + 1
    end, 2000, "preview window never opened")

    -- Swap the editor window to B: A leaves view -> preview hides.
    vim.cmd("buffer " .. b)
    wait.wait_for(function()
      return #vim.api.nvim_list_wins() == base
    end, 2000, "preview did not auto-hide when its file left the window")

    -- Swap back to A: preview restores alongside it.
    vim.cmd("buffer " .. a)
    wait.wait_for(function()
      return #vim.api.nvim_list_wins() == base + 1
    end, 2000, "preview did not restore when its file returned")

    mp.close(a)
    assert.are.equal(base, #vim.api.nvim_list_wins())
    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("closing the preview disables it: switching back does not restore", function()
    if vim.fn.executable("glow") ~= 1 then
      return
    end
    local wait = require("tests.helpers.wait")
    vim.cmd("only")
    vim.cmd("enew")
    local a = vim.api.nvim_get_current_buf()
    vim.bo[a].filetype = "markdown"
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "# A" })
    local b = vim.api.nvim_create_buf(true, false)
    vim.bo[b].filetype = "markdown"

    local mp = require("config.markdown_preview")
    local base = #vim.api.nvim_list_wins()

    mp.open(a)
    wait.wait_for(function()
      return #vim.api.nvim_list_wins() == base + 1
    end, 2000, "preview window never opened")

    -- A real close (as <leader>mp / :q on the pane does) forgets the file.
    mp.close(a)
    assert.are.equal(base, #vim.api.nvim_list_wins())

    -- Switching away and back must NOT bring the preview back.
    vim.cmd("buffer " .. b)
    vim.cmd("buffer " .. a)
    vim.wait(100)
    assert.are.equal(base, #vim.api.nvim_list_wins())

    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)
end)
