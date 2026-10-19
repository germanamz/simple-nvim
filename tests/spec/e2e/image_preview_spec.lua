local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- The wiring behind opening an image from the tree under the full config:
-- nvim-tree's on_attach rebinds the open keys, which must read a REAL tree node
-- (a field-only clone, see config.nvim_tree_hl_decorator) and send an image to
-- cmux while every other node opens as before. The cmux call sequence itself
-- lives in tests/spec/unit/image_preview_spec.lua; this file only proves the
-- keys reach it from where a user presses them.
--
-- Nothing here may reach the cmux socket -- it is the developer's live terminal
-- -- so `util.cmux.bin` and `M._run` are stubbed and every argv is recorded.
describe("e2e: nvim-tree opens images in cmux", function()
  local root, work, prev_cwd, calls, real_bin, ip, api

  --- The `lhs` mapping a keypress in the tree buffer would run.
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    assert.is_function(m.callback, "no mapping for " .. lhs)
    assert.are.equal(1, m.buffer, lhs .. " is not the tree's own mapping")
    m.callback()
  end

  --- Put the tree cursor on the node called `name`.
  local function cursor_on(name)
    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)
    wait.wait_for(function()
      for lnum = 1, vim.api.nvim_buf_line_count(0) do
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        local node = api.tree.get_node_under_cursor()
        if node and node.name == name then
          return true
        end
      end
      return false
    end, 3000, name .. " never appeared in the tree")
  end

  --- Every recorded cmux `open`, as the path it was asked to show.
  local function opened_paths()
    local paths = {}
    for _, args in ipairs(calls) do
      if args[4] == "open" then
        table.insert(paths, args[5])
      end
    end
    return paths
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    -- Real path up front: the temp dir sits behind macOS's /var -> /private/var
    -- symlink, and the module realpaths what it opens.
    work = vim.uv.fs_realpath(root) .. "/proj"
    vim.fn.mkdir(work .. "/assets", "p")
    vim.fn.mkdir(work .. "/folder.png", "p")
    vim.fn.writefile({ "\137PNG" }, work .. "/assets/shot.png", "b")
    vim.fn.writefile({ "return 1" }, work .. "/main.lua")
    vim.fn.chdir(work)
    require("lazy").load({ plugins = { "nvim-tree.lua" } })

    calls = {}
    ip = require("config.image_preview")
    ip._reset()
    ip._run = function(args, on_done)
      table.insert(calls, args)
      if args[4] == "open" then
        local payload = { surface_id = "s" .. #calls, pane_id = "editor" }
        return on_done(0, vim.json.encode({ opened = { { payload = payload } } }), "")
      elseif args[4] == "split-off" then
        return on_done(0, vim.json.encode({ pane_id = "images" }), "")
      end
      on_done(1, "", "")
    end
    local cmux = require("util.cmux")
    real_bin = cmux.bin
    cmux.bin = function()
      return "cmux-stub"
    end

    api = require("nvim-tree.api")
    -- On `work` explicitly: the explorer outlives tree.close(), so a bare open
    -- would show the previous spec's (deleted) root.
    api.tree.open({ path = work })
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
  end)

  after_each(function()
    ip._run = nil
    require("util.cmux").bin = real_bin
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("sends an image to cmux and keeps the tree open", function()
    cursor_on("assets")
    press("<CR>")
    cursor_on("shot.png")
    press("<CR>")

    assert.are.same({ work .. "/assets/shot.png" }, opened_paths())
    assert.are.equal(
      -1,
      vim.fn.bufnr(work .. "/assets/shot.png"),
      "the image was read into a buffer"
    )
    assert.is_true(api.tree.is_visible(), "the tree closed as if a file had been opened")
  end)

  it("sends an image from the split and preview keys too", function()
    cursor_on("assets")
    press("<CR>")
    cursor_on("shot.png")
    press("<C-v>")
    press("<Tab>")

    assert.are.equal(2, #opened_paths())
    assert.are.equal(-1, vim.fn.bufnr(work .. "/assets/shot.png"))
  end)

  it("opens any other file as before", function()
    cursor_on("main.lua")
    press("<CR>")

    wait.wait_for(function()
      return vim.api.nvim_buf_get_name(0) == work .. "/main.lua"
    end, 3000, "main.lua was not opened")
    assert.are.same({}, calls)
  end)

  it("still toggles a folder with an image's name", function()
    cursor_on("folder.png")
    press("<CR>")

    assert.are.same({}, calls)
    assert.is_true(api.tree.get_node_under_cursor().open, "folder.png did not expand")
  end)
end)
