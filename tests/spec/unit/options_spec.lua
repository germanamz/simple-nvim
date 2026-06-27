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

  it("disables soft-wrap globally so long lines scroll horizontally", function()
    require("config.options")
    assert.is_false(vim.opt.wrap:get())
    -- the diff-mode wrap override was removed along with global soft-wrap
    local autocmds = vim.api.nvim_get_autocmds({ event = "OptionSet", pattern = "diff" })
    assert.are.equal(0, #autocmds)
  end)

  it("disables auto hard-wrap in markdown without forcing soft-wrap", function()
    require("config.options")
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.opt_local.wrap = false
    vim.bo[buf].filetype = "markdown"

    -- soft-wrap is left off (disabled globally; long lines scroll horizontally)
    assert.is_false(vim.opt_local.wrap:get())
    -- 't' removed so a project's editorconfig max_line_length cannot trigger
    -- live auto-hard-wrap (the bundled markdown ftplugin sets it otherwise)
    assert.is_nil(vim.bo[buf].formatoptions:find("t", 1, true))
    -- textwidth left unset so .editorconfig / prettier own line length
    assert.are.equal(0, vim.bo[buf].textwidth)

    vim.api.nvim_win_close(win, true)
  end)

  it("enables prose spellcheck (camel-aware) in markdown buffers", function()
    require("config.options")
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "markdown"

    assert.is_true(vim.wo[win].spell)
    assert.are.equal("en", vim.bo[buf].spelllang)
    -- 'camel' splits CamelCase/identifier-ish words so code-flavored names raise
    -- fewer false positives than a whole-word check
    assert.are.equal("camel", vim.bo[buf].spelloptions)

    vim.api.nvim_win_close(win, true)
  end)

  it("binds <leader>bd to delete the current buffer", function()
    vim.g.mapleader = " "
    require("config.options")

    local found
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == " bd" then
        found = m
        break
      end
    end
    assert.is_not_nil(found)
    assert.is_not_nil(found.desc and found.desc:lower():find("delete buffer"))
  end)

  it("<leader>bd deletes the current buffer but keeps its window open", function()
    vim.g.mapleader = " "
    require("config.options")

    -- Two distinct listed buffers shown in one window, `second` on top so the
    -- previous (`first`) is the window's alternate. nvim_create_buf is used
    -- rather than :enew, which would reuse the same empty unnamed buffer.
    local first = vim.api.nvim_create_buf(true, false)
    local second = vim.api.nvim_create_buf(true, false)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, first)
    vim.api.nvim_win_set_buf(win, second)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" bd", true, false, true), "mx", false)

    -- Window survives and falls back to the previous buffer; the one we left is
    -- unloaded and unlisted (:bdelete unloads rather than wipes the buffer).
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.are.equal(first, vim.api.nvim_win_get_buf(win))
    assert.is_false(vim.api.nvim_buf_is_loaded(second))
    assert.are.equal(0, vim.fn.buflisted(second))
    assert.is_true(vim.api.nvim_buf_is_loaded(first))

    pcall(vim.api.nvim_buf_delete, first, { force = true })
  end)

  it("binds <Esc> to clear search highlight", function()
    require("config.options")

    local found
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == "<Esc>" then
        found = m
        break
      end
    end
    assert.is_not_nil(found)
    assert.is_not_nil(found.desc and found.desc:lower():find("clear search highlight"))
  end)

  it("<Esc> clears the search pattern and highlights", function()
    require("config.options")

    local keys = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)

    vim.opt.hlsearch = true
    vim.fn.setreg("/", "needle")
    vim.api.nvim_feedkeys(keys, "mx", false)

    assert.are.equal("", vim.fn.getreg("/"))
    assert.are.equal(0, vim.v.hlsearch)
  end)
end)
