local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- The tree is configured as an on-demand picker: it dismisses itself on exactly
-- two events — a file opened from within the tree (actions.open_file.
-- quit_on_open) and any Telescope picker opening (the User TelescopeFindPre
-- autocmd registered in the plugin's config). These specs pin both.
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

  it("closes the tree when a Telescope picker opens", function()
    require("lazy").load({ plugins = { "telescope.nvim" } })

    local dir = root .. "/proj"
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/a.lua", "return 1\n")
    vim.fn.chdir(dir)

    local api = open_tree()
    assert.is_true(api.tree.is_visible())

    -- Launching any picker fires User TelescopeFindPre, which closes the tree.
    require("telescope.builtin").find_files()
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

    wait.wait_for(function()
      return not api.tree.is_visible()
    end, 3000, "tree stayed open after a Telescope picker opened")

    -- Tidy up the open picker so it can't leak into the next spec.
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "mx", false)
    wait.wait_for(function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "TelescopePrompt" then
          return false
        end
      end
      return true
    end, 2000, "telescope picker did not close")
  end)
end)
