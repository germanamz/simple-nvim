local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

describe("config.git_head", function()
  local env_root, head, group, fired

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.git_head"] = nil
    package.loaded["util.git"] = nil
    head = require("config.git_head")
    fired = {}
    group = vim.api.nvim_create_augroup("git_head_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "HeadChanged",
      callback = function(args)
        table.insert(fired, args.data)
      end,
    })
  end)

  after_each(function()
    head._stop_all()
    vim.api.nvim_del_augroup_by_id(group)
    nvim_env.teardown(env_root)
  end)

  local function new_repo()
    return git_fixture.repo({
      commits = { { files = { ["a.lua"] = "-- a\n" }, message = "init" } },
    })
  end

  local function wait_for_event()
    return vim.wait(3000, function()
      return #fired > 0
    end, 10)
  end

  describe("get", function()
    it("returns nil for a nil root", function()
      assert.is_nil(head.get(nil))
    end)

    it("returns nil for an unwatched root", function()
      assert.is_nil(head.get("/nonexistent"))
    end)
  end)

  describe("watch", function()
    it("returns false outside a git repo", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_false(head.watch(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("snapshots the current branch", function()
      local repo = new_repo()
      assert.is_true(head.watch(repo))
      assert.are.equal("main", head.get(repo))
    end)

    it("fires HeadChanged with root and branch on an external checkout", function()
      local repo = new_repo()
      head.watch(repo)
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "-b", "feature" })
      assert.is_true(wait_for_event())
      assert.are.equal(repo, fired[1].root)
      assert.are.equal("feature", fired[1].branch)
      assert.are.equal("feature", head.get(repo))
    end)

    it("fires once per change even when watch is called twice", function()
      local repo = new_repo()
      head.watch(repo)
      head.watch(repo)
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "-b", "feature" })
      assert.is_true(wait_for_event())
      -- Give any duplicate event time to arrive before asserting there is none.
      vim.wait(300, function()
        return #fired > 1
      end, 10)
      assert.are.equal(1, #fired)
    end)

    it("reports a detached HEAD as a nil branch", function()
      local repo = new_repo()
      head.watch(repo)
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach" })
      assert.is_true(wait_for_event())
      assert.are.equal(repo, fired[1].root)
      assert.is_nil(fired[1].branch)
      assert.is_nil(head.get(repo))
    end)

    -- The P3 correctness fix: a `git submodule update` checks out a different
    -- commit as a detached HEAD. The branch is nil before and after, so the old
    -- branch-name gate stayed silent; the gate now keys on the resolved sha.
    it("fires when a detached HEAD moves between commits (submodule update)", function()
      local repo = git_fixture.repo({
        commits = {
          { files = { ["a.lua"] = "1\n" }, message = "c1" },
          { files = { ["a.lua"] = "2\n" }, message = "c2" },
        },
      })
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach", "HEAD~1" })
      head.watch(repo)
      assert.is_nil(head.get(repo)) -- detached at c1: nil branch
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach", "main" })
      assert.is_true(wait_for_event())
      assert.are.equal(repo, fired[1].root)
      assert.is_nil(fired[1].branch) -- still detached after the move to c2
    end)

    it("watches an unborn repo without error and reports a nil branch", function()
      local dir = vim.fn.tempname() .. "-unborn"
      vim.fn.mkdir(dir, "p")
      vim.fn.system({ "git", "-C", dir, "init", "-q", "--initial-branch=main" })
      assert.is_true(head.watch(dir))
      assert.is_nil(head.get(dir))
      vim.fn.delete(dir, "rf")
    end)
  end)
end)
