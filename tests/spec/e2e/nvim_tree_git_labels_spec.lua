local nvim_env = require("tests.helpers.nvim_env")
local git_fixture = require("tests.helpers.git_fixture")
local wait = require("tests.helpers.wait")

-- The tree's git column is the custom decorator in config.nvim_tree_git, which
-- replaces nvim-tree's builtin Git decorator with the smart pickers' porcelain
-- labels and review base. These specs pin the rendered labels end to end:
-- worktree codes, the base-only bX codes, and the live reaction to
-- ReviewBaseChanged.
describe("e2e: nvim-tree git labels", function()
  local root, prev_cwd

  local function tree_lines()
    local view = require("nvim-tree.view")
    local win = view.get_winnr()
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local function wait_for_line(pattern)
    local last
    wait.wait_for(function()
      last = table.concat(tree_lines(), "\n")
      return last:find(pattern) ~= nil
    end, 3000, "no tree line matched " .. pattern .. "\ntree was:\n" .. tostring(last))
  end

  -- Open the tree rooted at `path` explicitly: the tree keeps its root from a
  -- previous spec's repo otherwise (it only adopts the cwd on first open).
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
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("labels worktree changes with the picker porcelain codes", function()
    local repo = git_fixture.repo({
      commits = { { files = { ["committed.lua"] = "return 1\n" }, message = "init" } },
      modified = { ["committed.lua"] = "return 2\n" },
      untracked = { ["new.lua"] = "return 3\n" },
    })
    vim.fn.chdir(repo)

    open_tree(repo)
    wait_for_line("M%*%s+committed%.lua")
    wait_for_line("%?%*%s+new%.lua")
  end)

  it("labels committed-vs-base changes and updates on ReviewBaseChanged", function()
    local repo = git_fixture.repo({
      commits = {
        { files = { ["committed.lua"] = "return 1\n" }, message = "init" },
      },
    })
    vim.fn.system({ "git", "-C", repo, "branch", "base" })
    local f = assert(io.open(repo .. "/committed.lua", "w"))
    f:write("return 2\n")
    f:close()
    vim.fn.system({ "git", "-C", repo, "add", "-A" })
    vim.fn.system({
      "git",
      "-C",
      repo,
      "-c",
      "user.email=t@e.invalid",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "-m",
      "change",
      "--no-gpg-sign",
    })
    vim.fn.chdir(repo)

    open_tree(repo)
    -- Clean worktree, no base set: no label on the file.
    wait_for_line("committed%.lua")
    assert.is_nil(table.concat(tree_lines(), "\n"):find("bM"))

    -- Setting the base fires ReviewBaseChanged, which force-refreshes the
    -- codes cache and reloads the visible tree.
    local git_root = require("util.git").root(repo)
    require("config.review_base").set(git_root, "base")
    wait_for_line("bM%s+committed%.lua")

    -- Clearing it removes the label again.
    require("config.review_base").clear(git_root)
    wait.wait_for(function()
      return table.concat(tree_lines(), "\n"):find("bM") == nil
    end, 3000, "bM label survived clearing the review base")
  end)
end)
