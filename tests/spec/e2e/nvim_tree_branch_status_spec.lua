local nvim_env = require("tests.helpers.nvim_env")
local git_fixture = require("tests.helpers.git_fixture")
local wait = require("tests.helpers.wait")

-- End-to-end for the workspace branch/status feature: the superproject branch on
-- the root_folder_label line (config.repo_status.label_plain) and the per-
-- submodule branch/dirty labels placed after the folder name (the
-- config.nvim_tree_submodule decorator). Both resolve asynchronously and repaint
-- via RepoStatusChanged, so the assertions poll the rendered buffer.
describe("e2e: nvim-tree branch & status", function()
  local root, prev_cwd

  local function tree_text()
    local view = require("nvim-tree.view")
    local win = view.get_winnr()
    if not win or not vim.api.nvim_win_is_valid(win) then
      return ""
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function wait_for(pattern)
    local last
    wait.wait_for(function()
      last = tree_text()
      return last:find(pattern) ~= nil
    end, 4000, "no tree line matched " .. pattern .. "\ntree was:\n" .. tostring(last))
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
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    require("config.repo_status")._reset()
    require("config.nvim_tree_submodule")._reset()
    nvim_env.teardown(root)
  end)

  it("shows the superproject branch on the root_folder_label line", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    -- Root header = basename + "   " + status; the superproject is on main.
    wait_for("superproject%s+main")
  end)

  it("labels a visible submodule folder with its own branch (distinct from root)", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    -- Put childA on a branch that the superproject is NOT on, so the label proves
    -- it reads the submodule's own HEAD, not the superproject's.
    vim.fn.system({ "git", "-C", sp.children.childA, "checkout", "-q", "-b", "feature" })
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    wait_for("childA%s+feature")
  end)

  it("shows the dirty flag on a submodule with uncommitted changes", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    local f = assert(io.open(sp.children.childA .. "/dirty.lua", "w"))
    f:write("return 1\n")
    f:close()
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    -- The childA row carries a dirty flag (branch may be main or detached after
    -- submodule add; the ✎ is what this pins).
    wait_for("childA.*✎")
  end)

  it("labels a detached submodule with its describe ref", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    vim.fn.system({ "git", "-C", sp.children.childA, "tag", "v9.9" })
    vim.fn.system({ "git", "-C", sp.children.childA, "checkout", "-q", "--detach", "v9.9" })
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    -- The describe follow-up resolves the tag; nil branch renders "<ref> (detached)".
    wait_for("childA%s+v9%.9 %(detached%)")
  end)

  it("shows ahead-of-upstream on the root header", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    git_fixture.with_remote(sp.root)
    vim.fn.system({
      "git",
      "-C",
      sp.root,
      "branch",
      "--quiet",
      "--set-upstream-to=origin/main",
      "main",
    })
    vim.fn.system({
      "git",
      "-C",
      sp.root,
      "commit",
      "--allow-empty",
      "--no-gpg-sign",
      "-m",
      "ahead",
    })
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    wait_for("superproject%s+main ↑1")
  end)

  it("keeps submodule dirt out of the root header (--ignore-submodules=all)", function()
    local sp = git_fixture.superproject({ children = { "childA" } })
    local f = assert(io.open(sp.children.childA .. "/inside.lua", "w"))
    f:write("x\n")
    f:close()
    vim.fn.chdir(sp.root)
    open_tree(sp.root)
    wait_for("superproject%s+main") -- root resolved (warm, not just the cold basename)
    wait_for("childA.*✎") -- the submodule reports its own dirt
    -- The root's own tree is clean, so its header must carry no dirty flag.
    local root_line = tree_text():gmatch("[^\n]+")()
    assert.is_nil(root_line:find("✎"), "root header counted submodule dirt: " .. root_line)
  end)

  -- The core perf guarantee: a submodule's git status is resolved ONLY when its
  -- folder row is rendered. A grandchild submodule under a collapsed childA has
  -- no visible row, so it must not be resolved until childA is expanded.
  it("resolves a submodule's status only when its folder row is visible", function()
    local sp = git_fixture.superproject({
      children = { "childA" },
      grandchild = { parent = "childA", name = "grand" },
    })
    vim.fn.chdir(sp.root)
    local api = open_tree(sp.root)
    local rs = require("config.repo_status")
    -- nvim-tree stores resolved absolute paths (the decorator requests them), so
    -- compare against the resolved fixture paths.
    local childA = vim.fn.resolve(sp.children.childA)
    local grand = vim.fn.resolve(sp.grandchild)

    -- childA is a visible top-level row, so it resolves; wait for that to prove
    -- the pipeline ran, then assert grand (inside collapsed childA) did NOT.
    wait.wait_for(function()
      return rs.get(childA) ~= nil
    end, 4000, "childA never resolved")
    assert.is_nil(rs.get(grand), "grand resolved while its row was not visible")

    -- Expanding childA renders grand's row, which resolves it now.
    api.tree.expand_all()
    wait.wait_for(function()
      return rs.get(grand) ~= nil
    end, 4000, "grand not resolved after its row became visible")
  end)
end)
