local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

local function write_file(root, path, content)
  local full = root .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "w"))
  f:write(content)
  f:close()
end

local function git_commit(root, message)
  vim.fn.system({ "git", "-C", root, "add", "-A" })
  vim.fn.system({ "git", "-C", root, "commit", "-m", message, "--no-gpg-sign", "--allow-empty" })
end

local function stub_vim_fn(map)
  local orig = vim.fn
  local stub = setmetatable({}, {
    __index = function(_, name)
      if map[name] then
        return map[name]
      end
      return orig[name]
    end,
  })
  vim.fn = stub
  return function()
    vim.fn = orig
  end
end

describe("config.telescope_smart", function()
  local env_root, M, restore_fn

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.telescope_smart"] = nil
    M = require("config.telescope_smart")
  end)

  after_each(function()
    if restore_fn then
      restore_fn()
      restore_fn = nil
    end
    nvim_env.teardown(env_root)
  end)

  describe("_git_changes", function()
    it("classifies staged, modified, untracked with empty committed against HEAD base", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x", ["b.lua"] = "y" } } },
        modified = { ["a.lua"] = "x2" },
        staged = { ["s.lua"] = "..." },
        untracked = { ["u.lua"] = "..." },
      })
      local staged, modified, untracked, committed = M._git_changes(repo, "main")
      assert.are.same({ ["s.lua"] = true }, staged)
      assert.are.same({ ["a.lua"] = true }, modified)
      assert.are.same({ ["u.lua"] = true }, untracked)
      assert.are.same({}, committed)
    end)

    it("captures committed files on a feature branch ahead of base", function()
      local repo = git_fixture.repo({
        commits = {
          { files = { ["a.lua"] = "x", ["b.lua"] = "y" }, message = "init" },
          { files = { ["a.lua"] = "x2" }, message = "second" },
        },
      })
      vim.fn.system({ "git", "-C", repo, "checkout", "-b", "feature" })
      assert.are.equal(0, vim.v.shell_error)

      write_file(repo, "c.lua", "ccc")
      git_commit(repo, "add c")
      write_file(repo, "d.lua", "ddd")
      git_commit(repo, "add d")

      local _, _, _, committed = M._git_changes(repo, "main")
      assert.are.same({ ["c.lua"] = true, ["d.lua"] = true }, committed)
    end)
  end)

  describe("_merge_results", function()
    it(
      "dedupes across categories and orders staged, modified, untracked, committed, others",
      function()
        local staged = { ["a.lua"] = true }
        local modified = { ["b.lua"] = true }
        local untracked = { ["c.lua"] = true }
        local committed = { ["a.lua"] = true, ["d.lua"] = true }
        local all_files = { "./b.lua", "e.lua", "a.lua" }

        local result = M._merge_results(staged, modified, untracked, committed, all_files)
        assert.are.same({ "a.lua", "b.lua", "c.lua", "d.lua", "e.lua" }, result)
      end
    )
  end)

  describe("_list_all fallback", function()
    it("uses rg when available", function()
      local captured
      restore_fn = stub_vim_fn({
        executable = function(prog)
          return prog == "rg" and 1 or 0
        end,
        systemlist = function(cmd)
          captured = cmd
          return { "ok" }
        end,
      })
      local out = M._list_all()
      assert.are.same({ "rg", "--files", "--hidden", "--glob", "!.git" }, captured)
      assert.are.same({ "ok" }, out)
    end)

    it("falls back to fd when rg is missing", function()
      local captured
      restore_fn = stub_vim_fn({
        executable = function(prog)
          return prog == "fd" and 1 or 0
        end,
        systemlist = function(cmd)
          captured = cmd
          return { "fd-ok" }
        end,
      })
      local out = M._list_all()
      assert.are.same({ "fd", "--type", "f", "--hidden", "--exclude", ".git" }, captured)
      assert.are.same({ "fd-ok" }, out)
    end)

    it("falls back to find when neither rg nor fd is available", function()
      local captured
      restore_fn = stub_vim_fn({
        executable = function(_)
          return 0
        end,
        systemlist = function(cmd)
          captured = cmd
          return { "find-ok" }
        end,
      })
      local out = M._list_all()
      assert.are.same({ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" }, captured)
      assert.are.same({ "find-ok" }, out)
    end)
  end)
end)
