local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- <leader>bd deletes the current buffer without collapsing its window. The
-- interesting case is the *last* listed buffer: instead of stranding the user
-- on an empty [No Name] buffer (or quitting nvim), it falls back to the
-- nvim-tree explorer — the same default view `nvim .` opens.
describe("e2e: <leader>bd last-buffer fallback", function()
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

  it("opens nvim-tree when deleting the last listed buffer", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/only.lua", "return 1\n")
    vim.fn.chdir(dir)

    -- Reduce the editor to exactly one listed buffer: wipe everything, then edit
    -- the lone file (reuses the empty unnamed buffer, so the count stays at one).
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/only.lua"))
    local file_buf = vim.api.nvim_get_current_buf()
    assert.are.equal(1, #listed_bufs())

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" bd", true, false, true), "mx", false)

    local api = require("nvim-tree.api")
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open after deleting the last buffer")

    -- The file buffer is unloaded and we land on just the tree window, matching
    -- the single-window layout `nvim .` produces.
    assert.is_false(vim.api.nvim_buf_is_loaded(file_buf))
    assert.are.equal(1, #vim.api.nvim_list_wins())
    assert.are.equal("NvimTree", vim.bo[vim.api.nvim_get_current_buf()].filetype)
  end)

  it("goes to the tree past a lingering empty [No Name] buffer", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/only.lua", "return 1\n")
    vim.fn.chdir(dir)

    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/only.lua"))
    local file_buf = vim.api.nvim_get_current_buf()
    -- Leave an empty, unnamed [No Name] buffer listed alongside the file — the
    -- state you get after opening a file from the tree without reusing the
    -- startup buffer.
    vim.cmd("enew")
    vim.cmd("buffer " .. file_buf)
    assert.are.equal(2, #listed_bufs())

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" bd", true, false, true), "mx", false)

    local api = require("nvim-tree.api")
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open when closing the last real file")

    -- Straight to the tree — no intermediate stop on the empty buffer — and the
    -- throwaway [No Name] buffers are swept up.
    assert.is_false(vim.api.nvim_buf_is_loaded(file_buf))
    assert.are.equal(1, #vim.api.nvim_list_wins())
    assert.are.equal("NvimTree", vim.bo[vim.api.nvim_get_current_buf()].filetype)
    assert.are.equal(0, #listed_bufs())
  end)

  it("does not move the window off a modified buffer when the delete is refused", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/a.lua", "return 1\n")
    write_file(dir .. "/b.lua", "return 2\n")
    vim.fn.chdir(dir)

    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.lua"))
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/b.lua"))
    local b_buf = vim.api.nvim_get_current_buf()
    -- Make b dirty so bdelete refuses it (E89).
    vim.api.nvim_buf_set_lines(b_buf, 0, -1, false, { "return 2", "-- edited" })
    assert.is_true(vim.bo[b_buf].modified)

    local win = vim.api.nvim_get_current_win()
    pcall(
      vim.api.nvim_feedkeys,
      vim.api.nvim_replace_termcodes(" bd", true, false, true),
      "mx",
      false
    )

    -- The delete is refused, and crucially the view stays on the dirty buffer
    -- instead of silently jumping to another file.
    assert.is_true(vim.api.nvim_buf_is_loaded(b_buf))
    assert.are.equal(b_buf, vim.api.nvim_win_get_buf(win))
    assert.is_true(vim.bo[b_buf].modified)
  end)

  it("keeps editing when other buffers remain (no tree)", function()
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
    assert.are.equal(2, #listed_bufs())

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" bd", true, false, true), "mx", false)

    -- Window survives on the previous buffer; the tree never appears.
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.are.equal(a_buf, vim.api.nvim_win_get_buf(win))
    assert.is_false(vim.api.nvim_buf_is_loaded(b_buf))
    assert.is_false(require("nvim-tree.api").tree.is_visible())
  end)
end)
