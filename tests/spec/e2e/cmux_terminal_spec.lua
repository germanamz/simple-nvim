local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- The wiring behind `<leader>tt` / `<leader>tv` / `<leader>th` under the full
-- config: init.lua installs the global maps, and nvim-tree's on_attach installs
-- the tree's own copies, which must read a REAL tree node (a field-only clone,
-- see config.nvim_tree_hl_decorator) rather than the tree buffer's name. The
-- directory rules and argv shapes live in tests/spec/unit/cmux_terminal_spec.lua;
-- this file only proves the keys reach them from where a user presses them.
--
-- Nothing here may reach the cmux socket -- it is the developer's live terminal
-- -- so `util.cmux.bin` and `M._run` are stubbed and every argv is recorded.
describe("e2e: cmux terminal keymaps", function()
  local root, work, prev_cwd, calls, real_bin, term

  --- The `lhs` mapping a keypress in the current buffer would run.
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    assert.is_function(m.callback, "no mapping for " .. lhs)
    m.callback()
  end

  --- The working directory the only recorded cmux call asked for.
  local function only_dir()
    assert.are.equal(1, #calls, "expected exactly one cmux call, got " .. #calls)
    local args = calls[1]
    if args[1] == "rpc" then
      return vim.json.decode(args[3]).working_directory
    end
    return args[3]
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    -- Real path up front: the temp dir sits behind macOS's /var -> /private/var
    -- symlink, and nvim-tree reports the path it was opened on.
    work = vim.uv.fs_realpath(root) .. "/proj"
    vim.fn.mkdir(work .. "/src/lib", "p")
    vim.fn.writefile({ "return 1" }, work .. "/src/main.lua")
    vim.fn.chdir(work)
    require("lazy").load({ plugins = { "nvim-tree.lua" } })

    calls = {}
    term = require("config.cmux_terminal")
    term._run = function(args, on_done)
      table.insert(calls, args)
      on_done(0, "", "")
    end
    local cmux = require("util.cmux")
    real_bin = cmux.bin
    cmux.bin = function()
      return "cmux-stub"
    end
  end)

  after_each(function()
    term._run = nil
    require("util.cmux").bin = real_bin
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("maps all three keys globally, from init.lua", function()
    vim.cmd.edit(vim.fn.fnameescape(work .. "/src/main.lua"))
    press(" tt")
    assert.are.equal(work .. "/src", only_dir())
  end)

  it("maps the tree's own copies from on_attach, reading the node under the cursor", function()
    local api = require("nvim-tree.api")
    api.tree.open()
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")

    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)
    wait.wait_for(function()
      for lnum = 1, vim.api.nvim_buf_line_count(0) do
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        local node = api.tree.get_node_under_cursor()
        if node and node.name == "src" then
          return true
        end
      end
      return false
    end, 3000, "src never appeared in the tree")

    -- The buffer-local copy, not the global map: the global one would read the
    -- tree buffer (a nofile buffer) and open in the cwd, `work`, instead.
    assert.are.equal(1, vim.fn.maparg(" tv", "n", false, true).buffer)
    press(" tv")
    assert.are.equal(work .. "/src", only_dir())
  end)
end)
