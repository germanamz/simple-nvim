local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- The tree is configured as an on-demand browser: it dismisses itself when a
-- file is actually opened — from within the tree (actions.open_file.
-- quit_on_open) or from a Telescope picker (the select mappings in
-- lua/plugins/telescope.lua, which close the tree first so the file lands in a
-- full window, not the 35-col sidebar). Merely opening a picker does NOT close
-- the tree; it stays put until a file is chosen or it's toggled. These specs
-- pin all of that.
describe("e2e: nvim-tree auto-close", function()
  local root, prev_cwd

  local function write_file(path, contents)
    local fd = assert(io.open(path, "w"))
    fd:write(contents)
    fd:close()
  end

  local function open_tree()
    local api = require("nvim-tree.api")
    api.tree.open()
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
    return api
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

  it("closes the tree when a file is opened from it (quit_on_open)", function()
    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/hello.lua", "return 1\n")
    vim.fn.chdir(dir)

    local api = open_tree()

    -- Focus the tree and walk its rendered rows to the file, mirroring how a
    -- user lands on a node before pressing <CR>. get_node_under_cursor returns
    -- a live node the open action understands; get_nodes returns inert data.
    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)

    local file_node
    wait.wait_for(function()
      for lnum = 1, vim.api.nvim_buf_line_count(0) do
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        local node = api.tree.get_node_under_cursor()
        if node and node.name == "hello.lua" then
          file_node = node
          return true
        end
      end
      return false
    end, 3000, "hello.lua never appeared in the tree")

    api.node.open.edit(file_node)

    wait.wait_for(function()
      return not api.tree.is_visible()
    end, 3000, "tree stayed open after opening a file from it")
    assert.are.equal("hello.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
  end)

  local function telescope_open()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "TelescopePrompt" then
        return true
      end
    end
    return false
  end

  local function current_prompt_buf()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "TelescopePrompt" then
        return buf
      end
    end
    return nil
  end

  local function close_picker()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "mx", false)
    wait.wait_for(function()
      return not telescope_open()
    end, 2000, "telescope picker did not close")
  end

  it("stays open while a Telescope picker is up, and after cancelling", function()
    require("lazy").load({ plugins = { "telescope.nvim" } })

    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/a.lua", "return 1\n")
    vim.fn.chdir(dir)

    local api = open_tree()
    assert.is_true(api.tree.is_visible())

    require("telescope.builtin").find_files()
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

    -- Opening a picker must NOT dismiss the tree (the old behavior).
    assert.is_true(api.tree.is_visible(), "tree closed when the picker merely opened")

    -- Cancelling the picker leaves the tree exactly where it was.
    close_picker()
    assert.is_true(api.tree.is_visible(), "tree closed after cancelling the picker")
  end)

  it("closes when a file is opened from a picker, filling a full window", function()
    require("lazy").load({ plugins = { "telescope.nvim" } })

    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/pick_me.lua", "return 1\n")
    vim.fn.chdir(dir)

    local api = open_tree()

    require("telescope.builtin").find_files()
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

    -- Wait until the picker has actually selected an entry, not just rendered
    -- the row — selecting before then would dismiss the tree but open nothing.
    local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
    local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
    wait.wait_for(function()
      return picker:get_selection() ~= nil
    end, 5000, "picker never settled on a selection")

    -- <CR> runs our select wrapper: dismiss the tree, then open the file. The
    -- tree window is gone, so the file can't land in the 35-col sidebar.
    local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
    vim.api.nvim_feedkeys(cr, "mx", false)

    wait.wait_for(function()
      return not api.tree.is_visible()
        and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "pick_me.lua"
    end, 3000, "file did not open after picking it from the picker")
    assert.is_true(
      vim.api.nvim_win_get_width(0) > 35,
      "file opened in a narrow window (the sidebar?), width: " .. vim.api.nvim_win_get_width(0)
    )
  end)
end)
