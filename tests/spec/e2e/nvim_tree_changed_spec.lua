local nvim_env = require("tests.helpers.nvim_env")
local git_fixture = require("tests.helpers.git_fixture")
local wait = require("tests.helpers.wait")

-- C in the tree shows only changed files and the folders that hold them
-- (config.nvim_tree_changed), replacing the builtin git_clean toggle that is
-- inert with builtin git off. I keeps toggling ignored files on its own: both
-- filters share filters.custom, so each key flips its own module flag instead of
-- nvim-tree's single custom-filter state. The keys are driven through the tree
-- buffer's mapping callbacks.
describe("e2e: nvim-tree changed-only filter", function()
  local root, prev_cwd

  local function tree_win()
    return require("nvim-tree.view").get_winnr()
  end

  local function tree_text()
    local buf = vim.api.nvim_win_get_buf(tree_win())
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function wait_until(pred, what)
    local last
    wait.wait_for(function()
      last = tree_text()
      return pred(last)
    end, 3000, what .. "\ntree was:\n" .. tostring(last))
  end

  local function has(pattern)
    return function(text)
      return text:find(pattern) ~= nil
    end
  end

  local function press(lhs)
    local buf = vim.api.nvim_win_get_buf(tree_win())
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == lhs then
        return m.callback()
      end
    end
    error("no tree mapping for " .. lhs)
  end

  local function open_tree(path)
    local api = require("nvim-tree.api")
    api.tree.open({ path = path })
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
    -- The filter flag is module state that outlives the tree; leave it off.
    local changed = require("config.nvim_tree_changed")
    if changed.is_enabled() then
      pcall(changed.toggle)
    end
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("shows only changed files and their folders, and C again restores the tree", function()
    local repo = git_fixture.repo({
      commits = {
        {
          files = {
            ["src/changed.lua"] = "return 1\n",
            ["src/clean.lua"] = "return 2\n",
            ["docs/readme.md"] = "# docs\n",
          },
          message = "init",
        },
      },
      modified = { ["src/changed.lua"] = "return 3\n" },
      untracked = { ["top.lua"] = "return 4\n" },
    })
    vim.fn.chdir(repo)
    open_tree(repo)
    -- The top.lua label proves the codes cache is warm before filtering on it.
    wait_until(has("%?%*%s+top%.lua"), "codes never warmed")

    press("C")
    wait_until(function(t)
      return t:find("changed%.lua")
        and t:find("top%.lua")
        and not t:find("clean%.lua")
        and not t:find("docs")
    end, "C did not narrow the tree to the changed files")
    assert.is_truthy(vim.wo[tree_win()].winbar:find("changed only", 1, true))

    press("C")
    -- src stays expanded from the filtered view, so its clean file is back too.
    wait_until(function(t)
      return t:find("docs") and t:find("clean%.lua")
    end, "C did not restore the full tree")
    assert.is_truthy(vim.wo[tree_win()].winbar:find("g?", 1, true))
  end)

  it("keeps a submodule with changes and hides a clean one", function()
    local sp = git_fixture.superproject({ children = { "childA", "childB" } })
    local f = assert(io.open(sp.children.childA .. "/new.lua", "w"))
    f:write("return 1\n")
    f:close()
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    -- The rollup marker on childA proves the recursive submodule codes landed.
    wait_until(function(t)
      for line in t:gmatch("[^\n]+") do
        if line:find("childA", 1, true) and line:find("*", 1, true) then
          return true
        end
      end
      return false
    end, "childA never gained its * marker")

    press("C")
    wait_until(function(t)
      return t:find("new%.lua") and not t:find("childB") and not t:find("README")
    end, "C did not narrow the workspace to the changed submodule")
  end)

  it("lets I toggle ignored files without turning C off", function()
    local repo = git_fixture.repo({
      commits = {
        {
          files = {
            [".gitignore"] = "*.log\n",
            ["src/changed.lua"] = "return 1\n",
            ["docs/readme.md"] = "# docs\n",
          },
          message = "init",
        },
      },
      modified = { ["src/changed.lua"] = "return 2\n" },
      untracked = { ["debug.log"] = "noise\n" },
    })
    vim.fn.chdir(repo)
    open_tree(repo)
    -- The check-ignore oracle answers asynchronously; debug.log flashes, then hides.
    wait_until(function(t)
      return t:find("docs") and not t:find("debug%.log")
    end, "debug.log was never hidden as ignored")

    press("I")
    wait_until(has("debug%.log"), "I did not show the ignored file")

    press("C")
    wait_until(function(t)
      return t:find("changed%.lua") and not t:find("docs") and not t:find("debug%.log")
    end, "C did not narrow the tree")

    press("I")
    -- Back to hiding ignored files, and C is still in force.
    wait_until(function(t)
      return t:find("changed%.lua") and not t:find("docs")
    end, "I turned the changed-only filter off")

    press("C")
    wait_until(function(t)
      return t:find("docs") and not t:find("debug%.log")
    end, "the full tree did not come back with ignored files hidden")
  end)
end)
