-- config.nvim_tree_changed is the tree's "changed files only" filter (C in
-- nvim-tree). Builtin git is off, so nvim-tree's own git_clean filter has no
-- status to read; this predicate reads the same telescope_smart codes snapshot
-- the git decorator labels from instead. Pins which rows survive: changed files,
-- the folders that hold them (the folders that carry a */• marker), and a
-- commit-diverged submodule folder; and that it fails open wherever it has no
-- status to judge by.
local git_fixture = require("tests.helpers.git_fixture")
local review_base = require("config.review_base")

describe("config.nvim_tree_changed", function()
  local M, smart, orig_refresh, prev_cwd, repo
  local stub_codes, stub_root, stub_dirty

  before_each(function()
    package.loaded["config.nvim_tree_changed"] = nil
    M = require("config.nvim_tree_changed")
    prev_cwd = vim.fn.getcwd()
    -- A real repo so toggle()'s repo check passes; the files are on disk so
    -- path_util.relative sees real directories (and appends their slash).
    repo = git_fixture.repo({
      commits = {
        {
          files = {
            ["src/a.lua"] = "return 1\n",
            ["src/b.lua"] = "return 2\n",
            ["docs/x.md"] = "# x\n",
            ["sub/.keep"] = "",
          },
          message = "init",
        },
      },
    })
    vim.fn.chdir(repo)
    smart = require("config.telescope_smart")
    orig_refresh = smart._refresh
    stub_codes, stub_root, stub_dirty = { ["src/a.lua"] = " M" }, repo, {}
    smart._refresh = function()
      return stub_codes, nil, nil, stub_root, stub_dirty
    end
  end)

  after_each(function()
    smart._refresh = orig_refresh
    vim.fn.chdir(prev_cwd)
    vim.fn.delete(repo, "rf")
  end)

  -- From getcwd(), not `repo`: tempname() goes through the /tmp -> /private/tmp
  -- symlink and getcwd() is resolved, the same form nvim-tree builds its paths
  -- from. Mixing the two would make every path look outside the cwd.
  local function abs(rel)
    return vim.fn.getcwd() .. "/" .. rel
  end

  it("hides nothing while the filter is off", function()
    assert.is_false(M.is_enabled())
    assert.is_false(M.hides(abs("docs")))
    assert.is_false(M.hides(abs("src/b.lua")))
  end)

  describe("when on", function()
    before_each(function()
      M.toggle()
      assert.is_true(M.is_enabled())
    end)

    it("keeps a changed file and hides its unchanged sibling", function()
      assert.is_false(M.hides(abs("src/a.lua")))
      assert.is_true(M.hides(abs("src/b.lua")))
    end)

    -- path_util.relative turns an existing directory into "src/" (trailing
    -- slash); the lookup must strip it or every folder would vanish.
    it("keeps a folder that holds a change", function()
      assert.is_false(M.hides(abs("src")))
    end)

    it("hides a folder with no changes in it", function()
      assert.is_true(M.hides(abs("docs")))
    end)

    it("keeps files that differ only from the review base", function()
      stub_codes = { ["src/b.lua"] = "bM" }
      assert.is_false(M.hides(abs("src/b.lua")))
      assert.is_false(M.hides(abs("src")))
    end)

    -- A bumped submodule pointer has no file codes of its own; it arrives in
    -- the Tier-0 dirty_subs set, and its folder must stay visible.
    it("keeps a commit-diverged submodule folder", function()
      stub_dirty = { ["sub"] = true }
      assert.is_false(M.hides(abs("sub")))
    end)

    it("picks up a refreshed codes table", function()
      assert.is_true(M.hides(abs("src/b.lua")))
      stub_codes = { ["src/b.lua"] = " M" }
      assert.is_false(M.hides(abs("src/b.lua")))
      assert.is_true(M.hides(abs("src/a.lua")))
    end)

    it("fails open when the cwd has no repo status", function()
      stub_root = nil
      assert.is_false(M.hides(abs("docs")))
    end)

    it("never hides the cwd itself or paths outside it", function()
      assert.is_false(M.hides(vim.fn.getcwd()))
      assert.is_false(M.hides("/somewhere/else/file.lua"))
    end)

    it("turns off on a second toggle", function()
      M.toggle()
      assert.is_false(M.is_enabled())
      assert.is_false(M.hides(abs("docs")))
    end)
  end)

  it("refuses to turn on outside a git repo and says why", function()
    local plain = vim.fn.tempname() .. "-not-a-repo"
    vim.fn.mkdir(plain, "p")
    vim.fn.chdir(plain)
    local real_notify, notified = vim.notify, nil
    vim.notify = function(msg)
      notified = msg
    end
    local ok, err = pcall(M.toggle)
    vim.notify = real_notify
    vim.fn.delete(plain, "rf")
    assert.is_true(ok, tostring(err))
    assert.is_false(M.is_enabled())
    assert.are.equal(review_base.MSG_NOT_A_REPO, notified)
  end)

  it("names the active filter in the winbar hint", function()
    assert.is_truthy(M.winbar():find("g?", 1, true))
    assert.is_falsy(M.winbar():find("changed only", 1, true))
    M.toggle()
    assert.is_truthy(M.winbar():find("changed only", 1, true))
    assert.is_truthy(M.winbar():find("C to clear", 1, true))
  end)
end)
