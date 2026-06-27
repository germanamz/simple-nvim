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
  local env_root, M, orig_rename

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.review_base"] = nil
    M = require("config.review_base")
  end)

  after_each(function()
    if orig_rename then
      os.rename = orig_rename
      orig_rename = nil
    end
    vim.api.nvim_clear_autocmds({ event = "User", pattern = "ReviewBaseChanged" })
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

  -- git_root / resolve were thin re-exports of util.git.{root,resolve}; they were
  -- removed so root/ref resolution has a single home. Their behavior is covered
  -- by tests/spec/unit/util_git_spec.lua.

  describe("set / get round-trip", function()
    it("persists ref and fires User ReviewBaseChanged exactly once", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      local fires = {}
      vim.api.nvim_create_autocmd("User", {
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
    end)
  end)

  describe("clear", function()
    it("removes the entry and fires the autocmd with nil ref", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      M.set(repo, "main")
      assert.are.equal("main", M.get(repo))

      local fires = {}
      vim.api.nvim_create_autocmd("User", {
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
    end)
  end)

  describe("no-op guards", function()
    it("does not re-fire when M.set is called with the unchanged ref", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      M.set(repo, "main")

      local fires = {}
      vim.api.nvim_create_autocmd("User", {
        pattern = "ReviewBaseChanged",
        callback = function(args)
          table.insert(fires, args.data)
        end,
      })

      M.set(repo, "main")

      assert.are.equal(0, #fires)
      assert.are.equal("main", M.get(repo))
    end)

    it("does not fire when clearing an already-absent base", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })

      local fires = {}
      vim.api.nvim_create_autocmd("User", {
        pattern = "ReviewBaseChanged",
        callback = function(args)
          table.insert(fires, args.data)
        end,
      })

      M.clear(repo)

      assert.are.equal(0, #fires)
    end)
  end)

  describe("clear_active", function()
    it("clears the stored base for the repo containing start_path", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      -- clear_active resolves start_path to the canonical toplevel (git.root),
      -- which is how the picker flow stores the base, so key the fixture the
      -- same way (tempname() lands under a symlinked /var on macOS).
      local root = require("util.git").root(repo)
      M.set(root, "main")
      assert.are.equal("main", M.get(root))

      M.clear_active(repo)

      assert.is_nil(M.get(root))
    end)

    it("is a no-op outside a git repo", function()
      local dir = vim.fn.tempname() .. "-not-a-repo"
      vim.fn.mkdir(dir, "p")
      assert.has_no.errors(function()
        M.clear_active(dir)
      end)
      vim.fn.delete(dir, "rf")
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

  describe("apply_selection", function()
    local repo
    before_each(function()
      repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
    end)

    it("clears the base on the clear sentinel and reports nil", function()
      M.set(repo, "main")
      local got = "unset"
      M._apply_selection(repo, M._CLEAR_SENTINEL, function(ref)
        got = ref
      end)
      assert.is_nil(M.get(repo))
      assert.is_nil(got)
    end)

    it("sets a valid branch and reports it", function()
      vim.fn.system({ "git", "-C", repo, "branch", "feature", "HEAD" })
      local got = "unset"
      M._apply_selection(repo, "feature", function(ref)
        got = ref
      end)
      assert.are.equal("feature", M.get(repo))
      assert.are.equal("feature", got)
    end)

    it("rejects an invalid ref without setting, reporting nil", function()
      local got = "unset"
      M._apply_selection(repo, "no-such-ref", function(ref)
        got = ref
      end)
      assert.is_nil(M.get(repo))
      assert.is_nil(got)
    end)

    it("reports nil when there is no selection", function()
      local got = "unset"
      M._apply_selection(repo, nil, function(ref)
        got = ref
      end)
      assert.is_nil(got)
    end)
  end)

  describe("atomic write", function()
    it("leaves the state file uncorrupted when os.rename errors", function()
      local repo = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      M.set(repo, "main")
      local pre_content = read_file(state_path())
      assert.is_not_nil(pre_content)

      orig_rename = os.rename
      os.rename = function()
        error("simulated rename failure")
      end

      local ok = pcall(M.set, repo, "feature")

      assert.is_false(ok)
      assert.are.equal(pre_content, read_file(state_path()))
    end)
  end)
end)
