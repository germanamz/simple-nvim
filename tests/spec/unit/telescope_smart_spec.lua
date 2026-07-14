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
    it("lists code-tagged files first (sorted) then dedupes the full file list", function()
      local codes = { ["a.lua"] = " M", ["d.lua"] = "bA" }
      local all_files = { "./b.lua", "e.lua", "a.lua" }

      -- Changed files come first in sorted order (matching smart_files_changed),
      -- then the remaining listed files in their original order, deduped.
      local result = M._merge_results(codes, all_files)
      assert.are.same({ "a.lua", "d.lua", "b.lua", "e.lua" }, result)
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
      assert.are.same({
        "find",
        ".",
        "-type",
        "f",
        "-not",
        "-path",
        "*/.git/*",
        "-not",
        "-path",
        "*/node_modules/*",
        "-not",
        "-path",
        "*/.venv/*",
        "-not",
        "-path",
        "*/target/*",
        "-not",
        "-path",
        "*/build/*",
        "-not",
        "-path",
        "*/dist/*",
      }, captured)
      assert.are.same({ "find-ok" }, out)
    end)
  end)

  describe("_list_all_async", function()
    local captured

    local function stub_vim_system(result)
      local orig = vim.system
      vim.system = function(cmd, opts, on_exit)
        captured = { cmd = cmd, opts = opts }
        on_exit(result)
      end
      return function()
        vim.system = orig
      end
    end

    local function list_async(result)
      captured = nil
      restore_fn = stub_vim_system(result)
      local got
      M._list_all_async("/some/cwd", function(files)
        got = files
      end)
      assert.is_true(vim.wait(1000, function()
        return got ~= nil
      end, 10))
      return got
    end

    it("bounds the walker with a timeout", function()
      list_async({ code = 0, signal = 0, stdout = "a.lua\n" })
      assert.are.equal(10000, captured.opts.timeout)
    end)

    it("treats a timed-out (SIGTERM'd) walker as a failed listing", function()
      local got = list_async({ code = 124, signal = 15, stdout = "partial.lua\n" })
      assert.are.same({}, got)
    end)

    it("still keeps a partial-error walk's output (rg exits 2)", function()
      local got = list_async({ code = 2, signal = 0, stdout = "a.lua\nb.lua\n" })
      assert.are.same({ "a.lua", "b.lua" }, got)
    end)
  end)

  describe("_build_legend_segments", function()
    local counts = {
      added = 2,
      modified = 1,
      deleted = 0,
      renamed = 0,
      untracked = 3,
      staged = 5,
      unstaged = 4,
      committed = 0,
      base = { added = 1, modified = 0, deleted = 0, renamed = 0 },
    }

    it("keeps only nonzero worktree segments in order", function()
      local groups = M._build_legend_segments(counts, nil)
      assert.are.equal(4, #groups.worktree)
      assert.are.equal("A", groups.worktree[1].icon)
      assert.are.equal(2, groups.worktree[1].count)
      assert.are.equal("M", groups.worktree[2].icon)
      assert.are.equal("?*", groups.worktree[3].icon)
      assert.are.equal(3, groups.worktree[3].count)
      assert.are.equal("*", groups.worktree[4].icon)
      assert.are.equal(4, groups.worktree[4].count)
    end)

    it("omits the base list entirely when no base is set", function()
      local groups = M._build_legend_segments(counts, nil)
      assert.are.equal(0, #groups.base_list)
    end)

    it("builds base segments with a 'vs <base>' trailer when base is set", function()
      local groups = M._build_legend_segments(counts, "main")
      assert.are.equal(2, #groups.base_list)
      assert.are.equal("bA", groups.base_list[1].icon)
      assert.are.equal(1, groups.base_list[1].count)
      assert.are.equal("vs main", groups.base_list[2].label)
    end)

    it("emits no base trailer when every base count is zero", function()
      local zero = vim.tbl_deep_extend("force", counts, {
        base = { added = 0, modified = 0, deleted = 0, renamed = 0 },
      })
      local groups = M._build_legend_segments(zero, "main")
      assert.are.equal(0, #groups.base_list)
    end)
  end)

  describe("_parse_config_values", function()
    it("extracts the value column from get-regexp lines", function()
      local lines = {
        "submodule.childA.path childA",
        "submodule.sub/deep.path sub/deep",
        "submodule.spaced.path my dir/sub",
      }
      assert.are.same({ "childA", "sub/deep", "my dir/sub" }, M._parse_config_values(lines))
    end)

    it("returns an empty table for empty input", function()
      assert.are.same({}, M._parse_config_values({}))
    end)

    it("skips blank and whitespace-only lines amid valid entries", function()
      local lines = {
        "submodule.a.path a",
        "",
        "   ",
        "submodule.b.path sub/b",
      }
      assert.are.same({ "a", "sub/b" }, M._parse_config_values(lines))
    end)
  end)

  describe("_has_submodules", function()
    it("is true with a .gitmodules and false without", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      assert.is_true(M._has_submodules(sp.root))
      local plain = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
      assert.is_false(M._has_submodules(plain))
    end)
  end)

  describe("_run_pool", function()
    it("never exceeds the concurrency limit and completes every item", function()
      local active, max_active, completed = 0, 0, 0
      local done_all = false
      local items = {}
      for i = 1, 20 do
        items[i] = i
      end
      M._run_pool(items, 3, function(_, done)
        active = active + 1
        max_active = math.max(max_active, active)
        vim.defer_fn(function()
          active = active - 1
          completed = completed + 1
          done()
        end, 5)
      end, function()
        done_all = true
      end)
      assert.is_true(vim.wait(3000, function()
        return done_all
      end, 5))
      assert.are.equal(20, completed)
      assert.is_true(max_active <= 3)
    end)

    it("completes immediately for an empty item list", function()
      local done = false
      M._run_pool({}, 4, function() end, function()
        done = true
      end)
      assert.is_true(done)
    end)
  end)

  describe("_submodule_paths_async", function()
    it("lists checked-out submodules recursively", function()
      local sp = git_fixture.superproject({
        children = { "childA", "childB" },
        grandchild = { parent = "childA", name = "grand" },
      })
      local got
      M._submodule_paths_async(sp.root, function(p)
        got = p
      end)
      assert.is_true(vim.wait(3000, function()
        return got ~= nil
      end, 10))
      table.sort(got)
      assert.are.same({ "childA", "childA/grand", "childB" }, got)
    end)

    it("skips an uninitialized (deinitialized) submodule", function()
      local sp = git_fixture.superproject({ children = { "childA", "childB" } })
      -- Deinit childB: removes its worktree/.git so only its .gitmodules entry
      -- remains. Discovery must skip it (no checked-out worktree to status).
      vim.fn.system({ "git", "-C", sp.root, "submodule", "deinit", "-f", "childB" })
      local got
      M._submodule_paths_async(sp.root, function(p)
        got = p
      end)
      assert.is_true(vim.wait(3000, function()
        return got ~= nil
      end, 10))
      table.sort(got)
      assert.are.same({ "childA" }, got)
    end)
  end)

  describe("_recursive_changes_async", function()
    it("merges per-file codes from inside a submodule and drops the gitlink row", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      write_file(sp.children.childA, "childA.txt", "changed\n") -- modify a tracked file
      write_file(sp.children.childA, "new.lua", "x\n") -- untracked
      local codes
      M._recursive_changes_async(sp.root, nil, function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil
      end, 10))
      assert.is_truthy(codes["childA/new.lua"]) -- untracked, prefixed by the submodule path
      assert.is_truthy(codes["childA/childA.txt"]) -- modified
      assert.is_nil(codes["childA"]) -- the dirty submodule is NOT a bogus gitlink row
    end)

    it("recurses into a nested grandchild", function()
      local sp = git_fixture.superproject({
        children = { "childA" },
        grandchild = { parent = "childA", name = "grand" },
      })
      write_file(sp.grandchild, "grand.txt", "changed\n")
      local codes
      M._recursive_changes_async(sp.root, nil, function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil
      end, 10))
      assert.is_truthy(codes["childA/grand/grand.txt"])
      assert.is_nil(codes["childA/grand"]) -- no nested gitlink row
    end)

    it("takes the cheap path with no .gitmodules", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x\n" } } },
        modified = { ["a.lua"] = "y\n" },
      })
      assert.is_false(M._has_submodules(repo))
      local codes
      M._recursive_changes_async(repo, nil, function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil
      end, 10))
      assert.is_truthy(codes["a.lua"])
    end)

    it("applies the base diff to the outer repo only; submodules give worktree codes", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      vim.fn.system({ "git", "-C", sp.root, "branch", "base" })
      write_file(sp.root, "outer_new.lua", "x\n")
      git_commit(sp.root, "outer commit")
      write_file(sp.children.childA, "new.lua", "x\n")
      local codes
      M._recursive_changes_async(sp.root, "base", function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil
      end, 10))
      assert.are.equal("bA", codes["outer_new.lua"]) -- outer: changed-since-base
      assert.is_truthy(codes["childA/new.lua"]) -- submodule: worktree only
    end)
  end)

  describe("cwd canonicalization", function()
    local function untracked_repo_root()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "x" } } },
        untracked = { ["u.lua"] = "..." },
      })
      -- Resolved toplevel so the cwd-relative rewrite strips cleanly (the
      -- /var vs /private/var macOS symlink, as in the _refresh_async spec).
      return require("util.git").root(repo)
    end

    it("keeps the filesystem root and strips a single trailing slash", function()
      assert.are.equal("/", M._canonical_cwd("/"))
      assert.are.equal("/a/b", M._canonical_cwd("/a/b/"))
      assert.are.equal("/a/b", M._canonical_cwd("/a/b"))
    end)

    it("a trailing-slash cwd reads the plain form's cache entry", function()
      local root = untracked_repo_root()
      local codes
      M._refresh_async(root, function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil and codes["u.lua"] ~= nil
      end, 10))
      local cached = M._refresh(root .. "/")
      assert.are.equal("??", cached["u.lua"])
    end)

    it("an async refresh keyed with a trailing slash lands on the plain key", function()
      local root = untracked_repo_root()
      local codes
      M._refresh_async(root .. "/", function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil and codes["u.lua"] ~= nil
      end, 10))
      local cached = M._refresh(root)
      assert.are.equal("??", cached["u.lua"])
    end)
  end)

  describe("_refresh_async (recursion wired in)", function()
    it("exposes submodule files as cwd-relative codes", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      write_file(sp.children.childA, "new.lua", "x\n")
      -- Use the canonical toplevel as cwd so the cwd-relative rewrite (which keys
      -- off git.root's resolved path) strips cleanly — the /var vs /private/var
      -- symlink is an unrelated macOS artifact.
      local root = require("util.git").root(sp.root)
      local codes
      M._refresh_async(root, function(c)
        codes = c
      end)
      assert.is_true(vim.wait(3000, function()
        return codes ~= nil and codes["childA/new.lua"] ~= nil
      end, 10))
      assert.is_truthy(codes["childA/new.lua"])
    end)
  end)

  describe("loading float", function()
    describe("_load_guard", function()
      it("mounts only when the press is current and the picker is not yet open", function()
        assert.is_true(M._load_guard(3, 3, false).mount) -- current + not opened -> mount
        assert.is_false(M._load_guard(3, 3, true).mount) -- current but already opened -> no mount
        assert.is_false(M._load_guard(2, 3, false).mount) -- stale press -> never mounts
        assert.is_false(M._load_guard(2, 3, true).mount)
      end)

      it(
        "dismisses only for the current generation (stale press never closes a newer float)",
        function()
          assert.is_true(M._load_guard(3, 3, true).dismiss) -- current -> dismiss
          assert.is_true(M._load_guard(3, 3, false).dismiss) -- current, dismiss ignores opened
          assert.is_false(M._load_guard(2, 3, true).dismiss) -- superseded press -> must NOT close
        end
      )
    end)
  end)
end)
