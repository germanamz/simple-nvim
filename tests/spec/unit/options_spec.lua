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
      pattern = { "markdown", "mdx" },
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

  it("applies textwidth=80 and 't' formatoption to markdown buffers", function()
    require("config.options")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "markdown"

    assert.are.equal(80, vim.bo[buf].textwidth)
    assert.is_not_nil(vim.bo[buf].formatoptions:find("t", 1, true))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("binds <leader>w to rewrap on markdown buffers", function()
    vim.g.mapleader = " "
    require("config.options")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "markdown"

    local found
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == " w" then
        found = m
        break
      end
    end
    assert.is_not_nil(found)
    assert.is_not_nil(found.desc and found.desc:lower():find("rewrap"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("<leader>w rewraps prose but leaves table rows untouched", function()
    vim.g.mapleader = " "
    require("config.options")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("new")
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "markdown"

    local long = string.rep("word ", 30)
    local table_row = "| col1 that is intentionally quite long | col2 also rather lengthy here |"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      long,
      "",
      table_row,
      table_row,
      "",
      long,
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == " w" then
        cb = m.callback
        break
      end
    end
    assert.is_function(cb)
    cb()

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local saw_table = 0
    local max_prose_width = 0
    for _, l in ipairs(lines) do
      if l == table_row then
        saw_table = saw_table + 1
      elseif not l:match("^%s*$") and not l:match("^%s*|") then
        if #l > max_prose_width then
          max_prose_width = #l
        end
      end
    end
    assert.are.equal(2, saw_table)
    assert.is_true(max_prose_width <= 80, "prose width was " .. max_prose_width)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("<leader>w leaves fenced code blocks untouched even without a formatter", function()
    vim.g.mapleader = " "
    require("config.options")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("new")
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "markdown"

    local long = string.rep("word ", 30)
    -- Use a fence tag with no FORMATTERS entry so the block contents stay
    -- byte-identical regardless of which formatters happen to be installed.
    local code = {
      "```nosuchlang",
      "x   =   1",
      "if  x>0  :   pass",
      "```",
    }
    local input = { long, "" }
    for _, l in ipairs(code) do
      table.insert(input, l)
    end
    table.insert(input, "")
    table.insert(input, long)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, input)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == " w" then
        cb = m.callback
        break
      end
    end
    assert.is_function(cb)
    cb()

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    for _, l in ipairs(code) do
      assert.is_not_nil(joined:find(l, 1, true), "lost code line: " .. l)
    end
    -- The two code-body lines must still be on their own lines (i.e. not
    -- swept into a wrapped prose paragraph).
    local saw_body_line = 0
    for _, l in ipairs(lines) do
      if l == "x   =   1" or l == "if  x>0  :   pass" then
        saw_body_line = saw_body_line + 1
      end
    end
    assert.are.equal(2, saw_body_line)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
