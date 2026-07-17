-- Pins the pure porcelain-v2 --branch parser and the branch/status formatter
-- (no git spawn, no state), plus the async resolve/cache/event layer that backs
-- the nvim-tree root header and the per-submodule decorator labels. The async
-- block shells out to real git, so it must run with the sandbox OFF.
local repo_status = require("config.repo_status")
local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

describe("config.repo_status", function()
  describe("parse", function()
    it("reads a clean branch with no upstream divergence line", function()
      local s = repo_status.parse({
        "# branch.oid abc123",
        "# branch.head main",
      })
      assert.are.equal("main", s.branch)
      assert.is_false(s.detached)
      assert.are.equal(0, s.ahead)
      assert.are.equal(0, s.behind)
      assert.are.equal(0, s.count)
      assert.is_false(s.dirty)
    end)

    it("counts changed, renamed, unmerged, and untracked entries as dirty", function()
      local s = repo_status.parse({
        "# branch.head main",
        "# branch.ab +0 -0",
        "1 .M N... 100644 100644 100644 aaa bbb file1.lua",
        "1 M. N... 100644 100644 100644 ccc ddd file2.lua",
        "2 R. N... 100644 100644 100644 eee fff R100 new.lua\told.lua",
        "u UU N... 100644 100644 100644 100644 ggg hhh iii conflict.lua",
        "? untracked.lua",
      })
      assert.are.equal(5, s.count)
      assert.is_true(s.dirty)
      assert.are.equal(0, s.ahead)
      assert.are.equal(0, s.behind)
    end)

    it("does not count ignored (!) entries", function()
      local s = repo_status.parse({
        "# branch.head main",
        "! ignored.log",
      })
      assert.are.equal(0, s.count)
      assert.is_false(s.dirty)
    end)

    it("reads ahead/behind from the branch.ab line", function()
      local s = repo_status.parse({
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -1",
      })
      assert.are.equal(2, s.ahead)
      assert.are.equal(1, s.behind)
    end)

    it("leaves ahead/behind at zero when there is no upstream (no branch.ab)", function()
      local s = repo_status.parse({
        "# branch.head main",
      })
      assert.are.equal(0, s.ahead)
      assert.are.equal(0, s.behind)
    end)

    it("reports a detached HEAD with a nil branch", function()
      local s = repo_status.parse({
        "# branch.oid abc123",
        "# branch.head (detached)",
      })
      assert.is_true(s.detached)
      assert.is_nil(s.branch)
    end)
  end)

  describe("plain", function()
    it("shows just the branch when clean", function()
      assert.are.equal(
        "main",
        repo_status.plain({
          branch = "main",
          detached = false,
          ahead = 0,
          behind = 0,
          count = 0,
          dirty = false,
        })
      )
    end)

    it("appends the dirty flag with the changed-file count", function()
      assert.are.equal(
        "main ✎3",
        repo_status.plain({
          branch = "main",
          detached = false,
          ahead = 0,
          behind = 0,
          count = 3,
          dirty = true,
        })
      )
    end)

    it("appends ahead and behind, omitting whichever is zero", function()
      assert.are.equal(
        "main ✎3 ↑2 ↓1",
        repo_status.plain({
          branch = "main",
          detached = false,
          ahead = 2,
          behind = 1,
          count = 3,
          dirty = true,
        })
      )
      assert.are.equal(
        "main ↑2",
        repo_status.plain({
          branch = "main",
          detached = false,
          ahead = 2,
          behind = 0,
          count = 0,
          dirty = false,
        })
      )
    end)

    it("renders a detached HEAD with its describe ref", function()
      assert.are.equal(
        "v2.1 (detached)",
        repo_status.plain({
          detached = true,
          branch = nil,
          detached_ref = "v2.1",
          ahead = 0,
          behind = 0,
          count = 0,
          dirty = false,
        })
      )
    end)

    it("renders empty when neither a branch nor a detached ref is known", function()
      assert.are.equal(
        "",
        repo_status.plain({
          detached = false,
          branch = nil,
          ahead = 0,
          behind = 0,
          count = 0,
          dirty = false,
        })
      )
    end)
  end)

  describe("segments", function()
    it("colors the branch, dirty, ahead, and behind parts with distinct groups", function()
      local segs = repo_status.segments({
        branch = "main",
        detached = false,
        ahead = 2,
        behind = 1,
        count = 3,
        dirty = true,
      })
      assert.are.same({
        { str = "main", hl = { "SmartFilesBranch" } },
        { str = " ✎3", hl = { "SmartFilesModified" } },
        { str = " ↑2", hl = { "SmartFilesAhead" } },
        { str = " ↓1", hl = { "SmartFilesBehind" } },
      }, segs)
    end)

    it("colors a detached ref with the detached group", function()
      local segs = repo_status.segments({
        detached = true,
        branch = nil,
        detached_ref = "v2.1",
        ahead = 0,
        behind = 0,
        count = 0,
        dirty = false,
      })
      assert.are.same({
        { str = "v2.1 (detached)", hl = { "SmartFilesDetached" } },
      }, segs)
    end)

    it("returns no segments when nothing is known", function()
      assert.are.same(
        {},
        repo_status.segments({
          detached = false,
          branch = nil,
          ahead = 0,
          behind = 0,
          count = 0,
          dirty = false,
        })
      )
    end)

    it("concatenating segment strings equals the plain label", function()
      local status =
        { branch = "feature/x", detached = false, ahead = 0, behind = 0, count = 1, dirty = true }
      local acc = {}
      for _, seg in ipairs(repo_status.segments(status)) do
        acc[#acc + 1] = seg.str
      end
      assert.are.equal(repo_status.plain(status), table.concat(acc))
    end)
  end)

  describe("resolve / request / cache", function()
    local env_root, fired, group

    before_each(function()
      env_root = nvim_env.setup_isolated_env()
      repo_status._reset()
      fired = {}
      group = vim.api.nvim_create_augroup("repo_status_spec", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "RepoStatusChanged",
        callback = function(args)
          table.insert(fired, args.data)
        end,
      })
    end)

    after_each(function()
      repo_status._reset()
      vim.api.nvim_del_augroup_by_id(group)
      nvim_env.teardown(env_root)
    end)

    local function wait_fired(n)
      return vim.wait(3000, function()
        return #fired >= (n or 1)
      end, 10)
    end

    it("get returns nil for a dir that was never requested", function()
      assert.is_nil(repo_status.get("/nonexistent"))
    end)

    it("resolves a clean repo: branch, no dirt, and fires RepoStatusChanged", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      repo_status.request(repo)
      assert.is_true(wait_fired(1))
      assert.are.equal(repo, fired[1].dir)
      local s = repo_status.get(repo)
      assert.are.equal("main", s.branch)
      assert.is_false(s.detached)
      assert.is_false(s.dirty)
      assert.are.equal(0, s.count)
    end)

    it("resolves a dirty repo: dirty flag and changed-file count", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } },
        modified = { ["a.lua"] = "2\n" },
        untracked = { ["b.lua"] = "new\n" },
      })
      repo_status.request(repo)
      assert.is_true(wait_fired(1))
      local s = repo_status.get(repo)
      assert.is_true(s.dirty)
      assert.are.equal(2, s.count) -- one modified + one untracked
    end)

    it("fills detached_ref from git describe on a detached HEAD", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      vim.fn.system({ "git", "-C", repo, "tag", "v1.0" })
      vim.fn.system({ "git", "-C", repo, "checkout", "-q", "--detach" })
      repo_status.request(repo)
      assert.is_true(wait_fired(1))
      local s = repo_status.get(repo)
      assert.is_true(s.detached)
      assert.is_nil(s.branch)
      assert.are.equal("v1.0", s.detached_ref)
    end)

    it("reports commits ahead of an upstream", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      git_fixture.with_remote(repo)
      vim.fn.system({
        "git",
        "-C",
        repo,
        "branch",
        "--quiet",
        "--set-upstream-to=origin/main",
        "main",
      })
      vim.fn.system({ "git", "-C", repo, "commit", "--allow-empty", "--no-gpg-sign", "-m", "ahead" })
      repo_status.request(repo)
      assert.is_true(wait_fired(1))
      local s = repo_status.get(repo)
      assert.is_true(s.ahead >= 1)
      assert.are.equal(0, s.behind)
    end)

    it("label_plain returns '' on a cold cache and the plain label once warm", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      assert.are.equal("", repo_status.label_plain(repo)) -- cold: schedules a resolve, returns empty
      assert.is_true(wait_fired(1)) -- the scheduled resolve landed
      assert.are.equal(repo_status.plain(repo_status.get(repo)), repo_status.label_plain(repo))
    end)

    it("invalidate_all drops the cache", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      repo_status.request(repo)
      assert.is_true(wait_fired(1))
      assert.is_not_nil(repo_status.get(repo))
      repo_status.invalidate_all()
      assert.is_nil(repo_status.get(repo))
    end)

    it("does not cache or fire for a non-repo dir", function()
      local dir = vim.fn.tempname() .. "-plain"
      vim.fn.mkdir(dir, "p")
      repo_status.request(dir)
      vim.wait(500, function()
        return #fired > 0
      end, 10)
      assert.are.equal(0, #fired)
      assert.is_nil(repo_status.get(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("single-flights concurrent requests and coalesces a trailing one", function()
      local cbs = {}
      repo_status._resolve = function(_, cb)
        cbs[#cbs + 1] = cb
        return true
      end
      local status =
        { branch = "main", detached = false, ahead = 0, behind = 0, count = 0, dirty = false }
      repo_status.request("/x") -- starts the single in-flight resolve
      repo_status.request("/x") -- arrives in-flight: coalesces to a trailing rerun
      assert.are.equal(1, #cbs)
      table.remove(cbs, 1)(status) -- complete #1: caches, fires event, kicks the trailing rerun
      assert.are.equal("/x", fired[#fired].dir)
      assert.is_not_nil(repo_status.get("/x"))
      assert.are.equal(1, #cbs) -- exactly one trailing resolve, not a stack
      table.remove(cbs, 1)(status) -- complete the rerun: fires once more, no further trailing
      assert.are.equal(2, #fired)
    end)
  end)
end)
