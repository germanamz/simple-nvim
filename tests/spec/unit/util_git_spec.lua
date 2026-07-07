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

    it("returns no stdout lines for a stderr-only failure", function()
      -- git's "fatal: not a git repository" diagnostic is written to stderr; the
      -- run layer must keep it out of `lines` so callers that parse positionally
      -- (head, statusline) aren't corrupted by error text. systemlist merged the
      -- two streams; vim.system keeps them separate.
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      local lines, ok = git.run({ "rev-parse", "--show-toplevel" }, { cwd = dir })
      assert.is_false(ok)
      assert.are.same({}, lines)
      vim.fn.delete(dir, "rf")
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

    it("memoizes a negative result so a non-repo dir spawns git at most once", function()
      -- Buffer churn (pickers, previews, help buffers) re-resolves the same
      -- non-repo dirs constantly, and each miss is a synchronous main-thread
      -- vim.system():wait() — so a definitive "not a repo" must be cached too.
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      local real_system, spawns = vim.system, 0
      vim.system = function(...)
        spawns = spawns + 1
        return real_system(...)
      end
      local first = git.root(dir)
      local first_spawns = spawns
      local second = git.root(dir)
      local second_spawns = spawns
      vim.system = real_system
      vim.fn.delete(dir, "rf")
      assert.is_nil(first)
      assert.are.equal(1, first_spawns)
      assert.is_nil(second)
      assert.are.equal(1, second_spawns)
    end)

    it("discovers a dir that later becomes a repo after cache invalidation", function()
      -- The negative memo holds until the dir_cache invalidation path
      -- (_clear_root_cache, wired to DirChanged / .gitmodules / <leader>gR)
      -- drops it — the same clear that already covers stale positive entries.
      local dir = vim.fn.tempname() .. "-becomes-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_nil(git.root(dir))
      vim.fn.system({ "git", "-C", dir, "init", "-q", "--initial-branch=main" })
      assert.is_nil(git.root(dir))
      git._clear_root_cache()
      assert.are.equal(vim.fn.resolve(dir), vim.fn.resolve(git.root(dir)))
      vim.fn.delete(dir, "rf")
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

  describe("git_dir", function()
    it("returns the absolute git directory for a repo", function()
      local repo = new_repo()
      local dir = git.git_dir(repo)
      assert.are.equal(vim.fn.resolve(repo .. "/.git"), vim.fn.resolve(dir))
    end)

    it("returns nil for a non-git directory", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_nil(git.git_dir(dir))
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

  -- parse_head turns one `git rev-parse HEAD --abbrev-ref HEAD` result into the
  -- { sha, branch } shape. Pure, so the sync head() and the async HEAD watcher
  -- (config.git_head._resolve_head) share exactly one parse.
  describe("parse_head", function()
    it("parses normal, detached, and unborn from (lines, ok)", function()
      assert.are.same(
        { sha = "abc123", branch = "main" },
        git.parse_head({ "abc123", "main" }, true)
      )
      assert.are.same({ sha = "abc123", branch = nil }, git.parse_head({ "abc123", "HEAD" }, true))
      assert.are.same({ sha = nil, branch = nil }, git.parse_head({ "HEAD" }, false))
    end)
  end)

  -- head() resolves HEAD's object id AND branch in one process so the watcher
  -- can gate on the sha (which a `git submodule update` moves while the branch
  -- is unchanged) rather than the branch name alone.
  describe("head", function()
    it("returns the object id and branch on a normal checkout", function()
      local repo = new_repo()
      local h = git.head(repo)
      assert.is_truthy(h.sha and h.sha:match("^%x%x%x%x%x%x%x"))
      assert.are.equal("main", h.branch)
    end)

    it("returns the object id with a nil branch on a detached HEAD", function()
      local repo = new_repo()
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach" })
      local h = git.head(repo)
      assert.is_truthy(h.sha and h.sha:match("^%x%x%x%x%x%x%x"))
      assert.is_nil(h.branch)
    end)

    it("returns a nil object id and nil branch on an unborn HEAD", function()
      local dir = vim.fn.tempname() .. "-unborn"
      vim.fn.mkdir(dir, "p")
      vim.fn.system({ "git", "-C", dir, "init", "-q", "--initial-branch=main" })
      local h = git.head(dir)
      assert.is_nil(h.sha)
      assert.is_nil(h.branch)
      vim.fn.delete(dir, "rf")
    end)

    it("moves the sha but not the branch across a detached commit move", function()
      local repo = git_fixture.repo({
        commits = {
          { files = { ["a.lua"] = "1\n" }, message = "c1" },
          { files = { ["a.lua"] = "2\n" }, message = "c2" },
        },
      })
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach", "HEAD~1" })
      local h1 = git.head(repo)
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach", "main" })
      local h2 = git.head(repo)
      assert.is_nil(h1.branch)
      assert.is_nil(h2.branch)
      assert.is_truthy(h1.sha)
      assert.is_truthy(h2.sha)
      assert.are_not.equal(h1.sha, h2.sha)
    end)
  end)
end)
