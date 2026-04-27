describe("config.options", function()
  before_each(function()
    package.loaded["config.options"] = nil
    vim.env.REMOTE_CONTAINERS = nil
    vim.env.CODESPACES = nil
    vim.env.SSH_TTY = nil
    vim.g.clipboard = nil
    pcall(vim.api.nvim_clear_autocmds, { event = "OptionSet", pattern = "diff" })
    pcall(vim.api.nvim_clear_autocmds, {
      event = "FileType",
      pattern = { "DiffviewFiles", "DiffviewFileHistory" },
    })
  end)

  it("sets indentation to 2-space expandtab", function()
    require("config.options")
    assert.are.equal(2, vim.opt.shiftwidth:get())
    assert.is_true(vim.opt.expandtab:get())
  end)

  it("enables case-insensitive smart search", function()
    require("config.options")
    assert.is_true(vim.opt.ignorecase:get())
    assert.is_true(vim.opt.smartcase:get())
  end)

  it("enables 24-bit colors", function()
    require("config.options")
    assert.is_true(vim.opt.termguicolors:get())
  end)

  it("includes unnamedplus in clipboard", function()
    require("config.options")
    assert.is_true(vim.tbl_contains(vim.opt.clipboard:get(), "unnamedplus"))
  end)

  it("renders leading whitespace with middle-dot", function()
    require("config.options")
    assert.are.equal("·", vim.opt.listchars:get().lead)
  end)

  it("enables OSC 52 clipboard inside a container", function()
    vim.env.REMOTE_CONTAINERS = "true"
    require("config.options")
    assert.are.equal("OSC 52", vim.g.clipboard.name)
  end)

  it("does not set OSC 52 outside containers/SSH", function()
    if vim.uv.fs_stat("/.dockerenv") then
      pending("running inside Docker; OSC 52 fallback expected")
      return
    end
    require("config.options")
    if vim.g.clipboard then
      assert.are_not.equal("OSC 52", vim.g.clipboard.name)
    end
  end)

  it("forces wrap on when diff mode toggles on", function()
    require("config.options")
    local autocmds = vim.api.nvim_get_autocmds({ event = "OptionSet", pattern = "diff" })
    assert.are.equal(1, #autocmds)
    local callback = autocmds[1].callback
    assert.is_function(callback)

    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    vim.opt_local.wrap = false

    -- OptionSet is suppressed in headless plenary (fires only post-VimEnter),
    -- so invoke the callback directly with v:option_new mocked.
    local orig_v = vim.v
    vim.v = setmetatable({ option_new = "1" }, { __index = orig_v })
    local ok, err = pcall(callback, {})
    vim.v = orig_v

    assert.is_true(ok, tostring(err))
    assert.is_true(vim.opt_local.wrap:get())
    vim.api.nvim_win_close(win, true)
  end)
end)
