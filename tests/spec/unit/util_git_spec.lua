local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

-- Pin the behavior of the centralized git-shellout layer (lua/util/git.lua).
-- These are the characterization tests for the P1 extraction: every call site
-- (telescope_smart, review_base, statusline, gitsigns) routes through this
-- module, so its contract must be exact — including the empty-string-root guard
-- that telescope_smart's old git_root_at lacked.

describe("util.git", function()
  local env_root, git

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["util.git"] = nil
    git = require("util.git")
  end)

  after_each(function()
    nvim_env.teardown(env_root)
  end)

  local function new_repo()
    return git_fixture.repo({ commits = { { files = { ["a.lua"] = "-- a\n" }, message = "init" } } })
  end

  describe("run", function()
    it("returns lines and ok=true for a successful command", function()
      local repo = new_repo()
      local lines, ok = git.run({ "rev-parse", "--show-toplevel" }, { cwd = repo })
      assert.is_true(ok)
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(lines[1]))
    end)

    it("returns ok=false for a failing command", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      local _, ok = git.run({ "rev-parse", "--show-toplevel" }, { cwd = dir })
      assert.is_false(ok)
      vim.fn.delete(dir, "rf")
    end)

    it("runs in cwd when no cwd option is given", function()
      local repo = new_repo()
      vim.fn.chdir(repo)
      local lines, ok = git.run({ "rev-parse", "--show-toplevel" })
      assert.is_true(ok)
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(lines[1]))
    end)
  end)

  describe("first_line", function()
    it("returns the first output line on success", function()
      local repo = new_repo()
      local out = git.first_line({ "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = repo })
      assert.are.equal("main", out)
    end)

    it("returns nil when the command fails", function()
      local repo = new_repo()
      assert.is_nil(git.first_line({ "rev-parse", "--verify", "--quiet", "nope" }, { cwd = repo }))
    end)

    it("returns nil when the command succeeds but prints nothing", function()
      local repo = new_repo()
      -- no tags exist -> exit 0, empty output
      assert.is_nil(git.first_line({ "tag", "-l" }, { cwd = repo }))
    end)
  end)

  describe("root", function()
    it("returns the toplevel for a git repo", function()
      local repo = new_repo()
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root(repo)))
    end)

    it("resolves from the cwd when called with no argument", function()
      local repo = new_repo()
      vim.fn.chdir(repo)
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(git.root()))
    end)

    it("returns nil for a non-git directory", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_nil(git.root(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("returns nil for a nonexistent path", function()
      assert.is_nil(git.root("/nonexistent"))
    end)
  end)

  describe("branch", function()
    it("returns the current branch name", function()
      local repo = new_repo()
      assert.are.equal("main", git.branch(repo))
    end)

    it("tracks a newly checked-out branch", function()
      local repo = new_repo()
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "-b", "feature" })
      assert.are.equal("feature", git.branch(repo))
    end)

    it("returns nil outside a git repo", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_nil(git.branch(dir))
      vim.fn.delete(dir, "rf")
    end)
  end)

  describe("resolve", function()
    local repo
    before_each(function()
      repo = new_repo()
    end)

    it("returns true for HEAD", function()
      assert.is_true(git.resolve(repo, "HEAD"))
    end)

    it("returns true for a created branch", function()
      vim.fn.system({ "git", "-C", repo, "branch", "feature", "HEAD" })
      assert.is_true(git.resolve(repo, "feature"))
    end)

    it("returns false for a nonexistent ref", function()
      assert.is_false(git.resolve(repo, "deadbeef"))
    end)

    it("returns false for an empty ref", function()
      assert.is_false(git.resolve(repo, ""))
    end)

    it("returns false for a nil ref", function()
      assert.is_false(git.resolve(repo, nil))
    end)

    it("returns false when root is nil", function()
      assert.is_false(git.resolve(nil, "HEAD"))
    end)
  end)

  describe("file_in_ref", function()
    it("returns true for a file present in the ref", function()
      local repo = new_repo()
      assert.is_true(git.file_in_ref(repo, "HEAD", "a.lua"))
    end)

    it("returns false for a path absent from the ref", function()
      local repo = new_repo()
      assert.is_false(git.file_in_ref(repo, "HEAD", "missing.lua"))
    end)

    it("returns false for nil or empty arguments", function()
      local repo = new_repo()
      assert.is_false(git.file_in_ref(repo, "HEAD", ""))
      assert.is_false(git.file_in_ref(repo, nil, "a.lua"))
      assert.is_false(git.file_in_ref(nil, "HEAD", "a.lua"))
    end)
  end)
end)
