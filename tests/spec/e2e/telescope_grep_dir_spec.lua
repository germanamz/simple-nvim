local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- <leader>fG greps ONE folder, and inside nvim-tree the folder it offers is the
-- node under the cursor. That seeding is the half of config.telescope_grep the
-- unit specs can only stub, because it depends on a real nvim-tree: the tree
-- buffer is named "NvimTree_1" with filetype NvimTree, so if the module ever
-- fell back to the buffer -> directory ladder it would silently seed the cwd and
-- still look like it worked. These specs drive the live tree instead.
--
-- Pressing the key inside the tree also pins the binding decision: <leader>fG is
-- registered ONCE, globally, on the assumption that nvim-tree maps no leader
-- keys buffer-locally and so cannot shadow it. If that ever stops being true,
-- the press here stops reaching the prompt.
describe("e2e: <leader>fG folder-scoped grep from nvim-tree", function()
  local root, work, prev_cwd

  local function press(keys)
    local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
    vim.api.nvim_feedkeys(termcodes, "mx", false)
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
    press("<Esc>")
    wait.wait_for(function()
      return current_prompt_buf() == nil
    end, 2000, "telescope picker did not close")
  end

  -- Walks the rendered rows to `name`, leaving the cursor parked on it, the way
  -- a user lands on a node before pressing a key.
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

  --- Press <leader>fG with vim.ui.input answered from `answer(opts)`, and return
  --- the opts the prompt was opened with. Restores vim.ui.input before any
  --- assertion can fail, so a broken spec never leaves the shared headless
  --- session with a stubbed input.
  local function grep_key(answer)
    local seen
    local real_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      seen = opts
      on_confirm(answer and answer(opts) or nil)
    end
    local ok, err = pcall(press, "<Space>fG")
    vim.ui.input = real_input
    assert(ok, tostring(err))
    return assert(seen, "<leader>fG did not open a prompt (shadowed inside the tree?)")
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    work = root .. "/work"
    vim.fn.mkdir(work .. "/pkg/deep", "p")
    -- .txt, not .lua: editing a real Lua file in a later isolated env trips the
    -- LSP-log path cached from the first one (see tests/README.md).
    for _, path in ipairs({ "pkg/note.txt", "pkg/deep/buried.txt", "top.txt" }) do
      local f = assert(io.open(work .. "/" .. path, "w"))
      f:write("needle\n")
      f:close()
    end
    vim.fn.chdir(work)
    require("lazy").load({ plugins = { "nvim-tree.lua", "telescope.nvim" } })
  end)

  after_each(function()
    if current_prompt_buf() then
      pcall(close_picker)
    end
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  local function open_tree()
    local api = require("nvim-tree.api")
    api.tree.open({ path = work })
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
    return api, vim.api.nvim_get_current_win()
  end

  it("seeds the prompt with the folder under the cursor", function()
    local api, tree_win = open_tree()
    cursor_to(api, tree_win, "pkg")

    local opts = grep_key()
    -- Shown cwd-relative (the cwd IS work here) with a trailing slash, so <Tab>
    -- continues inside pkg/ rather than completing its siblings.
    assert.are.equal("pkg/", opts.default)
    assert.are.equal("dir", opts.completion)
  end)

  it("seeds a file node with its parent folder", function()
    local api, tree_win = open_tree()
    cursor_to(api, tree_win, "top.txt")

    -- top.txt sits at the tree root, so its parent is the cwd — shown as "./"
    -- rather than the absolute path ":." would hand back for the cwd itself.
    assert.are.equal("./", grep_key().default)
  end)

  it("greps below the seeded folder, excluding siblings", function()
    local api, tree_win = open_tree()
    cursor_to(api, tree_win, "pkg")

    -- Accept the seeded default untouched — the single-<CR> path.
    grep_key(function(opts)
      return opts.default
    end)
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

    local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
    local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
    assert.are.equal("Live Grep (pkg)", picker.prompt_title)

    -- set_prompt, not feedkeys: a headless prompt buffer cannot be typed into.
    picker:set_prompt("needle")

    local function non_empty_lines()
      local out = {}
      for _, line in ipairs(vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)) do
        if line ~= "" then
          table.insert(out, line)
        end
      end
      return out
    end

    -- Both in-scope matches, not just the first: rows stream in one at a time, so
    -- waiting for a single line would race the assertions below.
    wait.wait_for(function()
      return #non_empty_lines() >= 2
    end, 5000, "grep results did not populate")

    local joined = table.concat(non_empty_lines(), "\n")
    assert.is_truthy(joined:find("note.txt", 1, true), "expected pkg/note.txt, got: " .. joined)
    -- Recursive below the scope, but never above it.
    assert.is_truthy(joined:find("buried.txt", 1, true), "expected pkg/deep/buried.txt: " .. joined)
    assert.is_nil(joined:find("top.txt", 1, true), "a match above the scope leaked in: " .. joined)

    close_picker()
  end)
end)
