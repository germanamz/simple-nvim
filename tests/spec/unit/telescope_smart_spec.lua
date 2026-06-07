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
    it("returns porcelain codes and counts for staged, modified, untracked", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x", ["b.lua"] = "y" } } },
        modified = { ["a.lua"] = "x2" },
        staged = { ["s.lua"] = "..." },
        untracked = { ["u.lua"] = "..." },
      })
      local codes, counts = M._git_changes(repo, "main")
      assert.are.equal(" M", codes["a.lua"])
      assert.are.equal("A ", codes["s.lua"])
      assert.are.equal("??", codes["u.lua"])
      assert.is_nil(codes["b.lua"])

      assert.are.equal(1, counts.modified)
      assert.are.equal(1, counts.added)
      assert.are.equal(1, counts.untracked)
      assert.are.equal(1, counts.staged)
      -- worktree modification + untracked both count as unstaged
      assert.are.equal(2, counts.unstaged)
      assert.are.equal(0, counts.committed)
    end)

    it("tags base-only committed files with a 'b' code and counts them", function()
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

      local codes, counts = M._git_changes(repo, "main")
      assert.are.equal("bA", codes["c.lua"])
      assert.are.equal("bA", codes["d.lua"])
      assert.are.equal(2, counts.committed)
      assert.are.equal(2, counts.base.added)
    end)

    it("lists individual untracked files inside a brand-new directory", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x" } } },
        untracked = { ["newdir/newfile.lua"] = "..." },
      })
      local codes, counts = M._git_changes(repo, "main")
      -- git collapses fully-untracked dirs to "newdir/" by default; we want the
      -- actual file so the picker can list and open it, not the directory.
      assert.are.equal("??", codes["newdir/newfile.lua"])
      assert.is_nil(codes["newdir/"])
      assert.are.equal(1, counts.untracked)
    end)

    it("recurses into deeply nested untracked directories", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x" } } },
        untracked = { ["deep/nested/dir/file.lua"] = "..." },
      })
      local codes, counts = M._git_changes(repo, "main")
      assert.are.equal("??", codes["deep/nested/dir/file.lua"])
      assert.is_nil(codes["deep/"])
      assert.is_nil(codes["deep/nested/"])
      assert.are.equal(1, counts.untracked)
    end)

    it("still excludes gitignored files inside an untracked directory", function()
      local repo = git_fixture.repo({
        commits = { { files = { [".gitignore"] = "*.log\n" } } },
        untracked = {
          ["newdir/keep.lua"] = "...",
          ["newdir/skip.log"] = "...",
        },
      })
      local codes, counts = M._git_changes(repo, "main")
      assert.are.equal("??", codes["newdir/keep.lua"])
      assert.is_nil(codes["newdir/skip.log"])
      assert.is_nil(codes["newdir/"])
      assert.are.equal(1, counts.untracked)
    end)

    it("does not consult the base when it does not resolve", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x" } } },
        untracked = { ["u.lua"] = "..." },
      })
      local codes, counts = M._git_changes(repo, "no-such-ref")
      assert.are.equal("??", codes["u.lua"])
      assert.are.equal(0, counts.committed)
    end)
  end)

  describe("_merge_results", function()
    it("lists code-tagged files first then dedupes the full file list", function()
      local codes = { ["a.lua"] = " M", ["d.lua"] = "bA" }
      local all_files = { "./b.lua", "e.lua", "a.lua" }

      local result = M._merge_results(codes, all_files)
      table.sort(result)
      assert.are.same({ "a.lua", "b.lua", "d.lua", "e.lua" }, result)
    end)

    it("strips a leading ./ from listed files before deduping", function()
      local codes = { ["a.lua"] = " M" }
      local result = M._merge_results(codes, { "./a.lua" })
      assert.are.same({ "a.lua" }, result)
    end)
  end)

  describe("_parse_status_path", function()
    it("returns a plain path unchanged", function()
      assert.are.equal("a.lua", M._parse_status_path("a.lua"))
    end)

    it("returns the destination of a rename", function()
      assert.are.equal("new.lua", M._parse_status_path("old.lua -> new.lua"))
    end)

    it("unquotes a path containing spaces", function()
      assert.are.equal("a b.lua", M._parse_status_path('"a b.lua"'))
    end)
  end)

  describe("_format_prefix", function()
    local function text(code)
      local t = M._format_prefix(code)
      return t
    end

    it("renders nothing for nil or empty codes", function()
      assert.are.equal("  ", text(nil))
      assert.are.equal("  ", text(""))
      assert.are.equal("  ", text("  "))
    end)

    it("renders untracked as ?* with one highlight", function()
      local t, hls = M._format_prefix("??")
      assert.are.equal("?*", t)
      assert.are.same({ { { 0, 2 }, "SmartFilesUntracked" } }, hls)
    end)

    it("renders a staged add without an unstaged marker", function()
      local t, hls = M._format_prefix("A ")
      assert.are.equal("A ", t)
      assert.are.same({ { { 0, 1 }, "SmartFilesAdded" } }, hls)
    end)

    it("renders a worktree modification with the unstaged marker", function()
      local t, hls = M._format_prefix(" M")
      assert.are.equal("M*", t)
      assert.are.same({
        { { 0, 1 }, "SmartFilesModified" },
        { { 1, 2 }, "SmartFilesUnstaged" },
      }, hls)
    end)

    it("prefers the staged (X) letter as dominant when both are set", function()
      local t = M._format_prefix("MM")
      assert.are.equal("M*", t)
    end)

    it("renders a base-only code with the base highlight on the leading b", function()
      local t, hls = M._format_prefix("bD")
      assert.are.equal("bD", t)
      assert.are.same({
        { { 0, 1 }, "SmartFilesBase" },
        { { 1, 2 }, "SmartFilesDeleted" },
      }, hls)
    end)
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
