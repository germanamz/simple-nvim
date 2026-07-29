local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local keymap_probe = require("tests.helpers.keymap_probe")

-- The sticky ancestor-folder header (config.nvim_tree_context): once a folder
-- containing the cursor row scrolls out of view, it stays pinned to the top of
-- the tree window, the way nvim-treesitter-context pins enclosing functions.
--
-- The height arithmetic is unit-tested against plain numbers; what needs a live
-- tree is the part that touches nvim-tree and the window: that the pinned rows
-- are a verbatim copy of the real tree rows (so every decorator survives into
-- the header for free), that the header stays away when the chain is already on
-- screen, and that the overlay is torn down by the toggle.
--
-- CursorMoved never fires in a headless script context, so these drive
-- M.update() directly rather than through feedkeys.
describe("e2e: nvim-tree sticky ancestor folders", function()
  local root, work, prev_cwd, ctx, prev_lines

  -- The tree can only scroll past `c` if the buffer is taller than the window,
  -- so the fixture and the screen are sized against each other: 40 files render
  -- ~44 rows, comfortably more than a 15-row screen.
  local FILES = 40
  local SCREEN_LINES = 15

  local function header()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "NvimTreeContext" then
          return win, buf
        end
      end
    end
    return nil
  end

  local function header_lines()
    local win, buf = header()
    return win and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or nil
  end

  local function open_tree()
    local api = require("nvim-tree.api")
    api.tree.open({ path = work })
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)
    api.tree.expand_all()
    wait.wait_for(function()
      return vim.api.nvim_buf_line_count(0) > FILES
    end, 3000, "expand_all never rendered the nested files")
    return api, tree_win
  end

  -- Line of the row rendering `name`, found the way a user lands on it.
  local function line_of(api, tree_win, name)
    local found
    wait.wait_for(function()
      for lnum = 1, vim.api.nvim_buf_line_count(0) do
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        local node = api.tree.get_node_under_cursor()
        if node and node.name == name then
          found = lnum
          return true
        end
      end
      return false
    end, 3000, name .. " never appeared in the tree")
    return found
  end

  -- Scroll so every folder in the a/b/c chain sits above the viewport, and park
  -- the cursor well below the top so the header is never capped by it.
  local function scroll_chain_offscreen(api, tree_win)
    local lines = {}
    for _, name in ipairs({ "a", "b", "c" }) do
      lines[name] = line_of(api, tree_win, name)
    end
    local topline = lines.c + 1
    local height = vim.api.nvim_win_get_height(tree_win)
    vim.fn.winrestview({ topline = topline, lnum = topline + math.min(5, height - 1), col = 0 })
    assert.are.equal(
      topline,
      vim.fn.line("w0"),
      "precondition failed: topline was clamped, fixture is too short"
    )
    return lines
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    prev_lines = vim.o.lines
    vim.o.lines = SCREEN_LINES
    work = root .. "/work"
    vim.fn.mkdir(work .. "/a/b/c", "p")
    for i = 1, FILES do
      local f = assert(io.open(("%s/a/b/c/f%02d.txt"):format(work, i), "w"))
      f:write("x\n")
      f:close()
    end
    require("lazy").load({ plugins = { "nvim-tree.lua" } })
    ctx = require("config.nvim_tree_context")
    ctx._reset()
  end)

  after_each(function()
    pcall(function()
      require("config.nvim_tree_context")._reset()
    end)
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    vim.o.lines = prev_lines
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("pins the ancestor chain once it scrolls out of view", function()
    local api, tree_win = open_tree()
    local lines = scroll_chain_offscreen(api, tree_win)

    ctx.update()

    -- The header is a verbatim copy of the real rows, so assert against the
    -- tree buffer itself rather than against reconstructed text.
    local tree_buf = vim.api.nvim_win_get_buf(tree_win)
    local expected = {}
    for _, name in ipairs({ "a", "b", "c" }) do
      local l = lines[name]
      expected[#expected + 1] = vim.api.nvim_buf_get_lines(tree_buf, l - 1, l, false)[1]
    end

    assert.are.same(expected, header_lines())
  end)

  it("shows no header while the whole chain is still on screen", function()
    local api, tree_win = open_tree()
    local lc = line_of(api, tree_win, "c")
    vim.fn.winrestview({ topline = 1, lnum = lc + 1, col = 0 })

    ctx.update()

    assert.is_nil(header(), "header appeared though every ancestor was visible")
  end)

  it("anchors on the tree window's first text row, with no winbar offset", function()
    -- The header has to cover the topline row exactly. row=0 already means the
    -- first TEXT row — a relative="win" float is composited below the winbar —
    -- so the tree's "g? — all mappings" hint survives without an offset, and
    -- adding one pushes the header a row too low, leaving a real tree row
    -- peeking out above the pinned folders.
    --
    -- This asserts the window config rather than a rendered screen position on
    -- purpose: headless reports float positions frame-relative (both
    -- nvim_win_get_position and screenpos), so a rendering-based assertion here
    -- would confidently pin the wrong model.
    local api, tree_win = open_tree()
    assert.are_not.equal(
      "",
      vim.wo[tree_win].winbar,
      "precondition failed: tree window has no winbar hint"
    )
    scroll_chain_offscreen(api, tree_win)

    ctx.update()

    local hwin = header()
    assert.is_not_nil(hwin, "no header to position")
    local cfg = vim.api.nvim_win_get_config(hwin)
    assert.are.equal("win", cfg.relative)
    assert.are.equal(tree_win, cfg.win)
    assert.are.equal(0, cfg.row, "header was offset off the tree's first text row")
  end)

  it("carries the tree's own highlights into the pinned rows", function()
    local api, tree_win = open_tree()
    scroll_chain_offscreen(api, tree_win)

    ctx.update()

    local _, hbuf = header()
    assert.is_not_nil(hbuf, "no header to inspect")
    local marks = vim.api.nvim_buf_get_extmarks(hbuf, -1, 0, -1, {})
    assert.is_true(#marks > 0, "pinned rows lost every highlight from the tree")
  end)

  it("closes the header on toggle and restores it on toggling back", function()
    local api, tree_win = open_tree()
    scroll_chain_offscreen(api, tree_win)
    ctx.update()
    assert.is_not_nil(header(), "precondition failed: no header to toggle off")

    ctx.toggle()
    assert.is_nil(header(), "toggle left the header on screen")
    ctx.update()
    assert.is_nil(header(), "update re-opened the header while disabled")

    ctx.toggle()
    ctx.update()
    assert.is_not_nil(header(), "toggling back did not restore the header")
  end)

  it("registers the <leader>uT toggle keymap", function()
    local leader = vim.g.mapleader or "\\"
    local m = keymap_probe.resolve("n", leader .. "uT")
    assert.is_not_nil(m, "no normal-mode <leader>uT keymap")
    assert.is_not_nil(m.callback, "<leader>uT resolves to no callback")
  end)
end)
