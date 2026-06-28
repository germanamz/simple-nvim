local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

-- Regression net for multi-submodule support (plan stage P1). Pins the behavior
-- the whole config relies on in a superproject: util.git resolves each submodule
-- (and nested grandchild, linked worktree) to its OWN toplevel and gitdir, and
-- degrades correctly on an unborn-HEAD repo. These characterize existing
-- util.git behavior so later stages (per-buffer scoping, HEAD sha-gate, watcher
-- eviction) can build on a verified foundation.

local function resolved(p)
  return vim.fn.resolve(p)
end

describe("multi-submodule (util.git in a superproject)", function()
  local env_root, git

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["util.git"] = nil
    git = require("util.git")
  end)

  after_each(function()
    nvim_env.teardown(env_root)
  end)

  describe("per-submodule root resolution", function()
    local sp
    before_each(function()
      sp = git_fixture.superproject({ children = { "childA", "childB" } })
    end)

    it("resolves a submodule working tree to its own toplevel", function()
      assert.are.equal(resolved(sp.children.childA), resolved(git.root(sp.children.childA)))
      assert.are.equal(resolved(sp.children.childB), resolved(git.root(sp.children.childB)))
    end)

    it("gives each submodule a distinct root, separate from the superproject", function()
      local a = resolved(git.root(sp.children.childA))
      local b = resolved(git.root(sp.children.childB))
      local parent = resolved(git.root(sp.root))
      assert.are_not.equal(a, b)
      assert.are_not.equal(a, parent)
      assert.are_not.equal(b, parent)
    end)

    it("resolves a file inside a submodule to that submodule's toplevel", function()
      local file_dir = sp.children.childA
      assert.are.equal(resolved(sp.children.childA), resolved(git.root(file_dir)))
    end)

    it("points a submodule's gitdir at .git/modules/<name>, not the shared .git", function()
      local dir = git.git_dir(sp.children.childA)
      assert.is_not_nil(dir)
      assert.is_truthy(dir:match("/%.git/modules/childA$"))
    end)

    it("resolves a path in the superproject but outside any submodule to the parent", function()
      assert.are.equal(resolved(sp.root), resolved(git.root(sp.root)))
    end)
  end)

  describe("nested submodule (grandchild)", function()
    local sp
    before_each(function()
      sp = git_fixture.superproject({
        children = { "childA" },
        grandchild = { parent = "childA", name = "grand" },
      })
    end)

    it("resolves a grandchild to its own toplevel, distinct from its parent submodule", function()
      local grand = resolved(git.root(sp.grandchild))
      assert.are.equal(resolved(sp.grandchild), grand)
      assert.are_not.equal(grand, resolved(git.root(sp.children.childA)))
    end)

    it("nests the grandchild's gitdir under its parent's modules dir", function()
      local dir = git.git_dir(sp.grandchild)
      assert.is_not_nil(dir)
      assert.is_truthy(dir:match("modules/childA/modules/grand$"))
    end)
  end)

  describe("linked worktree of a submodule", function()
    local sp
    before_each(function()
      sp = git_fixture.superproject({
        children = { "childA" },
        worktree = { child = "childA", name = "wt" },
      })
    end)

    it("resolves a linked worktree to its own toplevel", function()
      assert.are.equal(resolved(sp.worktree), resolved(git.root(sp.worktree)))
    end)

    it("points the worktree gitdir at .git/worktrees/<name>", function()
      local dir = git.git_dir(sp.worktree)
      assert.is_not_nil(dir)
      assert.is_truthy(dir:match("/worktrees/wt$"))
    end)
  end)

  describe("git.buf_root (per-buffer repo scoping)", function()
    local sp
    before_each(function()
      sp = git_fixture.superproject({ children = { "childA", "childB" } })
    end)

    local bufs = {}
    local function buf_for(file)
      local buf = vim.api.nvim_create_buf(true, false)
      if file then
        vim.api.nvim_buf_set_name(buf, file)
      end
      bufs[#bufs + 1] = buf
      return buf
    end
    after_each(function()
      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      bufs = {}
    end)

    it("resolves a buffer editing a submodule file to that submodule's root", function()
      local buf = buf_for(sp.children.childA .. "/childA.txt")
      assert.are.equal(resolved(sp.children.childA), resolved(git.buf_root(buf)))
    end)

    it("scopes two buffers in different submodules to their own roots", function()
      local a = buf_for(sp.children.childA .. "/childA.txt")
      local b = buf_for(sp.children.childB .. "/childB.txt")
      assert.are.equal(resolved(sp.children.childA), resolved(git.buf_root(a)))
      assert.are.equal(resolved(sp.children.childB), resolved(git.buf_root(b)))
      assert.are_not.equal(resolved(git.buf_root(a)), resolved(git.buf_root(b)))
    end)

    it("falls back to the cwd repo for an unnamed buffer", function()
      vim.fn.chdir(sp.children.childB)
      local buf = buf_for(nil)
      assert.are.equal(resolved(sp.children.childB), resolved(git.buf_root(buf)))
    end)

    it("returns nil for a buffer outside any repo", function()
      local dir = vim.fn.tempname() .. "-no-repo"
      vim.fn.mkdir(dir, "p")
      vim.fn.chdir(dir)
      local buf = buf_for(nil)
      assert.is_nil(git.buf_root(buf))
      vim.fn.delete(dir, "rf")
    end)
  end)

  describe("unborn-HEAD repository (no commits)", function()
    local sp
    before_each(function()
      sp = git_fixture.superproject({ children = { "childA" }, unborn = true })
    end)

    it("resolves the toplevel even with no commits", function()
      assert.are.equal(resolved(sp.unborn), resolved(git.root(sp.unborn)))
    end)

    -- The crux of plan stage P3: an unborn HEAD still reports its branch NAME
    -- (the symref target), so a branch-name-only change gate stays silent across
    -- the unborn -> first-commit transition. Only the resolved object id moves
    -- (nil -> sha), which is why P3 re-keys the HeadChanged gate on the sha.
    it("still reports the unborn branch name before the first commit", function()
      assert.are.equal("main", git.branch(sp.unborn))
    end)

    it("cannot resolve HEAD to an object on an unborn repo", function()
      assert.is_nil(
        git.first_line({ "rev-parse", "--verify", "--quiet", "HEAD" }, { cwd = sp.unborn })
      )
    end)
  end)
end)
