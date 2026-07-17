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

  it("rolls a worktree change up to a * marker on the containing directory", function()
    local repo = git_fixture.repo({
      commits = { { files = { ["src/committed.lua"] = "return 1\n" }, message = "init" } },
      modified = { ["src/committed.lua"] = "return 2\n" },
    })
    vim.fn.chdir(repo)

    open_tree(repo)
    -- The only tree line mentioning "src" is the directory row (the file row
    -- underneath shows the basename committed.lua); it gains a "*" once the
    -- codes cache warms and the rollup marker renders.
    local src_line
    wait.wait_for(function()
      for _, l in ipairs(tree_lines()) do
        if l:find("src", 1, true) then
          src_line = l
          return l:find("*", 1, true) ~= nil
        end
      end
      return false
    end, 3000, "src dir row never gained a * marker; last: " .. tostring(src_line))
  end)

  it("labels a file inside a submodule via the recursive status", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    local f = assert(io.open(sp.children.childA .. "/new.lua", "w"))
    f:write("return 1\n")
    f:close()
    vim.fn.chdir(sp.root)

    local api = open_tree(sp.root)
    -- The submodule directory is shown; its contents carry per-file labels from
    -- the cross-submodule recursive status (not the collapsed gitlink row).
    wait_for_line("childA")
    api.tree.expand_all()
    wait_for_line("%?%*%s+new%.lua")
  end)

  it("rolls a submodule-internal change up to its containing subdirectory", function()
    -- The reported case: a dirty file nested in a subdirectory of a submodule
    -- (e.g. lola-server/cmd/gql/main.go). The rollup marker must reach the
    -- intermediate directory via the submodule-recursion codes, which key the
    -- change as childA/deep/new.lua (superproject-relative).
    local sp = git_fixture.superproject({ children = { "childA" } })
    local deep = sp.children.childA .. "/deep"
    vim.fn.mkdir(deep, "p")
    local f = assert(io.open(deep .. "/new.lua", "w"))
    f:write("return 1\n")
    f:close()
    vim.fn.chdir(sp.root)

    local api = open_tree(sp.root)
    wait_for_line("childA")
    api.tree.expand_all()
    -- "deep" appears only on the intermediate directory row; it gains the "*"
    -- once the recursive codes warm.
    local deep_line
    wait.wait_for(function()
      for _, l in ipairs(tree_lines()) do
        if l:find("deep", 1, true) then
          deep_line = l
          return l:find("*", 1, true) ~= nil
        end
      end
      return false
    end, 3000, "deep dir row never gained a * marker; last: " .. tostring(deep_line))
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

  -- An external commit / `git add` from another terminal changes file status
  -- without moving HEAD, so neither ReviewBaseChanged nor HeadChanged fires; the
  -- decorations would stay stale. The config refreshes the codes + reloads on
  -- FocusGained instead. These pin that handler (the _refresh_async spy isolates
  -- it from nvim-tree's own fs/git watchers, which could also trigger a reload).
  it("refreshes the git decorations on FocusGained while the tree is visible", function()
    local repo = git_fixture.repo({
      commits = { { files = { ["committed.lua"] = "return 1\n" }, message = "init" } },
    })
    vim.fn.chdir(repo)
    open_tree(repo)

    local smart = require("config.telescope_smart")
    local orig = smart._refresh_async
    local calls = 0
    smart._refresh_async = function(cwd, cb)
      calls = calls + 1
      return orig(cwd, cb)
    end
    local ok, err = pcall(function()
      vim.api.nvim_exec_autocmds("FocusGained", {})
    end)
    smart._refresh_async = orig
    assert.is_true(ok, "FocusGained handler errored: " .. tostring(err))
    assert.is_true(calls >= 1, "FocusGained did not refresh the tree git codes")
  end)

  it("skips the FocusGained refresh when the tree is closed", function()
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    wait.wait_for(function()
      return not require("nvim-tree.api").tree.is_visible()
    end, 3000, "tree did not close")

    local smart = require("config.telescope_smart")
    local orig = smart._refresh_async
    local calls = 0
    smart._refresh_async = function(cwd, cb)
      calls = calls + 1
      return orig(cwd, cb)
    end
    vim.api.nvim_exec_autocmds("FocusGained", {})
    smart._refresh_async = orig
    assert.are.equal(0, calls, "tree refreshed git codes on FocusGained while closed")
  end)
end)
