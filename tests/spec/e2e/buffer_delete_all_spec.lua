local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- <leader>bad closes every buffer without unsaved changes. Modified buffers
-- survive with the window still on them; when nothing real is left, the view
-- falls back to the nvim-tree explorer, mirroring <leader>bd's last-buffer
-- behavior.
describe("e2e: <leader>bad close-all-saved", function()
  local root, prev_cwd

  local function write_file(path, contents)
    local fd = assert(io.open(path, "w"))
    fd:write(contents)
    fd:close()
  end

  local function listed_bufs()
    return vim.tbl_filter(function(b)
      return vim.bo[b].buflisted
    end, vim.api.nvim_list_bufs())
  end

  -- Guard before feeding "<leader>bad": with no mapping the raw keys fall
  -- through to normal-mode b/a/d and `a` enters insert mode, which kills the
  -- headless busted child instead of failing the assertion.
  local function feed_bad()
    assert.are_not.equal("", vim.fn.maparg("<leader>bad", "n"))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" bad", true, false, true), "mx", false)
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    require("lazy").load({ plugins = { "nvim-tree.lua" } })
  end)

  after_each(function()
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("closes every saved buffer and falls back to the tree", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/a.lua", "return 1\n")
    write_file(dir .. "/b.lua", "return 2\n")
    vim.fn.chdir(dir)

    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.lua"))
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/b.lua"))
    assert.are.equal(2, #listed_bufs())

    feed_bad()

    local api = require("nvim-tree.api")
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open after closing every saved buffer")

    -- Everything saved is gone (including throwaway [No Name] buffers) and we
    -- land on just the tree window.
    assert.are.equal(0, #listed_bufs())
    assert.are.equal(1, #vim.api.nvim_list_wins())
    assert.are.equal("NvimTree", vim.bo[vim.api.nvim_get_current_buf()].filetype)
  end)

  it("keeps buffers with unsaved changes open (no tree)", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/a.lua", "return 1\n")
    write_file(dir .. "/b.lua", "return 2\n")
    vim.fn.chdir(dir)

    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.lua"))
    local a_buf = vim.api.nvim_get_current_buf()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/b.lua"))
    local b_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b_buf, 0, -1, false, { "return 2", "-- edited" })
    assert.is_true(vim.bo[b_buf].modified)

    local win = vim.api.nvim_get_current_win()
    feed_bad()

    -- The saved buffer closes, the dirty one survives with the window still on
    -- it, and the tree never appears.
    assert.is_false(vim.api.nvim_buf_is_loaded(a_buf))
    assert.is_true(vim.bo[b_buf].buflisted)
    assert.is_true(vim.bo[b_buf].modified)
    assert.are.equal(b_buf, vim.api.nvim_win_get_buf(win))
    assert.is_false(require("nvim-tree.api").tree.is_visible())
  end)
end)
