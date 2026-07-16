local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- `renderer.full_name = true` (lua/plugins/nvim-tree.lua) asks nvim-tree to pop a
-- one-line float over the cursor row whenever that row renders wider than the
-- 35-column sidebar, so long names stay readable without widening the tree.
--
-- Two things are worth pinning. The flag has to survive into nvim-tree's MERGED
-- config: config() assembles opts.renderer at runtime (the decorator classes only
-- exist once the plugin is loaded) and a wholesale `opts.renderer = {...}` there
-- silently drops any sibling renderer key — full_name would never reach setup().
-- And the float itself has to appear for a truncated row and go away for a short
-- one.
describe("e2e: nvim-tree full-name float", function()
  local root, work, prev_cwd

  -- A node must render wider than the sidebar before nvim-tree floats it: the
  -- threshold is view.width (35) minus signcolumn/foldcolumn textoff (~2), minus
  -- any right-aligned icon extmarks. 58 chars clears that with room to spare,
  -- even after the 3-space indent and devicon.
  local LONG_NAME = "a_very_long_filename_that_definitely_overflows_the_sidebar.lua"
  local SHORT_NAME = "short.lua"

  local function open_floats()
    local floats = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        floats[#floats + 1] = win
      end
    end
    return floats
  end

  local function float_texts()
    local texts = {}
    for _, win in ipairs(open_floats()) do
      local fbuf = vim.api.nvim_win_get_buf(win)
      texts[#texts + 1] = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
    end
    return texts
  end

  -- nvim-tree registers the float autocmds against the buffer-NAME pattern
  -- "NvimTree_*", so they have to be driven by pattern. Going through
  -- exec_autocmds rather than calling show() directly also runs hide() first,
  -- exactly as a real cursor move does — show() does not dedupe, so calling it
  -- straight would stack a second float on top of the live one.
  local function tree_cursor_moved()
    vim.api.nvim_exec_autocmds("CursorMoved", {
      pattern = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
    })
  end

  local function open_tree(path)
    local api = require("nvim-tree.api")
    api.tree.open({ path = path })
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
    return api
  end

  -- Walks the rendered rows to `name`, leaving the cursor parked on it — the
  -- same way a user lands on a node before the float fires.
  local function cursor_to(api, tree_win, name)
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

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    work = root .. "/work"
    vim.fn.mkdir(work, "p")
    for _, name in ipairs({ LONG_NAME, SHORT_NAME }) do
      local f = assert(io.open(work .. "/" .. name, "w"))
      f:write("return 1\n")
      f:close()
    end
    require("lazy").load({ plugins = { "nvim-tree.lua" } })
  end)

  after_each(function()
    for _, win in ipairs(open_floats()) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("carries renderer.full_name into nvim-tree's merged config", function()
    assert.is_true(require("nvim-tree.config").g.renderer.full_name)
  end)

  it("keeps the rest of the renderer opts alongside the decorators", function()
    -- The decorator list is meant to replace nvim-tree's default list wholesale
    -- (that is how the builtin "Git" decorator gets dropped for the smart-picker
    -- one), but a partial renderer table must not wipe unrelated renderer
    -- defaults.
    local renderer = require("nvim-tree.config").g.renderer
    assert.is_table(renderer.decorators)
    assert.is_false(vim.tbl_contains(renderer.decorators, "Git"))
    assert.are.equal(2, renderer.indent_width)
    assert.is_not_nil(renderer.icons)
  end)

  it("registers the floating-node autocmds", function()
    -- nvim_get_autocmds THROWS on an unknown group instead of returning {}, so
    -- the pcall result is itself the assertion that the augroup was created.
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "nvim_tree_floating_node" })
    assert.is_true(ok, "augroup nvim_tree_floating_node was never created")
    local events = {}
    for _, au in ipairs(autocmds) do
      events[au.event] = true
    end
    assert.is_true(events.CursorMoved, "no CursorMoved autocmd in nvim_tree_floating_node")
    assert.is_true(events.BufLeave, "no BufLeave autocmd in nvim_tree_floating_node")
  end)

  it("floats the full name over a row too long for the sidebar", function()
    local api = open_tree(work)
    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)

    cursor_to(api, tree_win, LONG_NAME)
    tree_cursor_moved()

    local floats = open_floats()
    assert.are.equal(1, #floats, "expected exactly one full-name float, got " .. #floats)
    local text = table.concat(float_texts(), "\n")
    assert.is_truthy(
      text:find(LONG_NAME, 1, true),
      "float did not contain the full name, got: " .. vim.inspect(text)
    )
  end)

  it("shows no float for a row that already fits", function()
    local api = open_tree(work)
    local tree_win = require("nvim-tree.view").get_winnr()
    vim.api.nvim_set_current_win(tree_win)

    -- Park on the long name first so a float is definitely up, then move off it:
    -- this pins the hide path, not merely the absence of a float.
    cursor_to(api, tree_win, LONG_NAME)
    tree_cursor_moved()
    assert.are.equal(1, #open_floats(), "no float to dismiss — precondition failed")

    cursor_to(api, tree_win, SHORT_NAME)
    tree_cursor_moved()

    assert.are.equal(0, #open_floats(), "float lingered over a row that fits")
  end)
end)
