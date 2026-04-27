local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  return raw
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function state_path()
  return vim.fn.stdpath("data") .. "/nvim-review-base.json"
end

describe("config.review_base", function()
  local env_root
  local M

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.review_base"] = nil
    M = require("config.review_base")
  end)

  after_each(function()
    nvim_env.teardown(env_root)
  end)

  describe("read_state via M.get", function()
    it("returns nil for any key when the state file is missing", function()
      assert.is_nil(M.get("/some/path"))
      assert.is_nil(M.get("/another/path"))
    end)

    it("returns nil for any key when the state file is malformed JSON", function()
      write_file(state_path(), "{not json")
      assert.is_nil(M.get("/some/path"))
    end)

    it("returns nil for any key when the state file is empty", function()
      write_file(state_path(), "")
      assert.is_nil(M.get("/some/path"))
    end)
  end)

  describe("git_root", function()
    it("returns the toplevel for a git repo", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      local root = M.git_root(repo)
      assert.is_not_nil(root)
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(root))
    end)

    it("returns nil for a non-git directory", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.is_nil(M.git_root(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("returns nil for a nonexistent path", function()
      assert.is_nil(M.git_root("/nonexistent"))
    end)
  end)

  describe("resolve", function()
    local repo
    before_each(function()
      repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
    end)

    it("returns true for HEAD", function()
      assert.is_true(M.resolve(repo, "HEAD"))
    end)

    it("returns true for a created branch", function()
      vim.fn.system({ "git", "-C", repo, "branch", "feature", "HEAD" })
      assert.are.equal(0, vim.v.shell_error)
      assert.is_true(M.resolve(repo, "feature"))
    end)

    it("returns true for a created tag", function()
      vim.fn.system({ "git", "-C", repo, "tag", "v1", "HEAD" })
      assert.are.equal(0, vim.v.shell_error)
      assert.is_true(M.resolve(repo, "v1"))
    end)

    it("returns false for a nonexistent ref", function()
      assert.is_false(M.resolve(repo, "deadbeef"))
    end)

    it("returns false for an empty ref", function()
      assert.is_false(M.resolve(repo, ""))
    end)

    it("returns false for a nil ref", function()
      assert.is_false(M.resolve(repo, nil))
    end)

    it("returns false when root is nil", function()
      assert.is_false(M.resolve(nil, "HEAD"))
    end)
  end)

  describe("set / get round-trip", function()
    it("persists ref and fires User ReviewBaseChanged exactly once", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      local fires = {}
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "ReviewBaseChanged",
        callback = function(args)
          table.insert(fires, args.data)
        end,
      })

      M.set(repo, "main")

      assert.are.equal(1, #fires)
      assert.are.equal(repo, fires[1].root)
      assert.are.equal("main", fires[1].ref)
      assert.are.equal("main", M.get(repo))

      pcall(vim.api.nvim_del_autocmd, id)
    end)
  end)

  describe("clear", function()
    it("removes the entry and fires the autocmd with nil ref", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      M.set(repo, "main")
      assert.are.equal("main", M.get(repo))

      local fires = {}
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "ReviewBaseChanged",
        callback = function(args)
          table.insert(fires, args.data)
        end,
      })

      M.clear(repo)

      assert.are.equal(1, #fires)
      assert.are.equal(repo, fires[1].root)
      assert.is_nil(fires[1].ref)
      assert.is_nil(M.get(repo))

      pcall(vim.api.nvim_del_autocmd, id)
    end)
  end)

  describe("bootstrap", function()
    it("drops stale entries and preserves valid ones", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      local payload = {
        ["/nonexistent/dir"] = "main",
        [repo] = "main",
      }
      write_file(state_path(), vim.json.encode(payload))

      M.bootstrap()

      assert.are.equal("main", M.get(repo))
      assert.is_nil(M.get("/nonexistent/dir"))

      local raw = read_file(state_path())
      local decoded = vim.json.decode(raw)
      assert.are.equal("main", decoded[repo])
      assert.is_nil(decoded["/nonexistent/dir"])
    end)
  end)

  describe("atomic write", function()
    it("leaves the state file uncorrupted when os.rename errors", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      M.set(repo, "main")
      local pre_content = read_file(state_path())
      assert.is_not_nil(pre_content)

      local orig_rename = os.rename
      os.rename = function()
        error("simulated rename failure")
      end

      local ok = pcall(M.set, repo, "feature")
      os.rename = orig_rename

      assert.is_false(ok)
      assert.are.equal(pre_content, read_file(state_path()))
    end)
  end)
end)
