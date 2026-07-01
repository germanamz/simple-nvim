-- config.ignore_filter replaces nvim-tree's builtin git-ignore filter (which,
-- in a superproject, spawns a synchronous `git status --ignored` per submodule
-- and trips a never-reset kill switch). Pins the pure decision logic the
-- synchronous filter and the async oracle rely on: the static heavy-dir set, the
-- partition-by-toplevel that keeps `git check-ignore` from crossing a submodule
-- boundary, and the NUL-delimited output parse.

describe("config.ignore_filter", function()
  local M

  before_each(function()
    package.loaded["config.ignore_filter"] = nil
    M = require("config.ignore_filter")
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "ignore_filter")
  end)

  describe("_is_static", function()
    it("matches a curated heavy-dir basename at any depth", function()
      assert.is_true(M._is_static("/a/b/node_modules"))
      assert.is_true(M._is_static("/x/.venv"))
      assert.is_true(M._is_static("/deep/nested/__pycache__"))
      assert.is_true(M._is_static("/p/.terraform"))
    end)

    it("does NOT match ambiguous names that are sometimes tracked", function()
      -- These must fall through to the oracle so a tracked dir of that name
      -- (git's real, index-aware answer) stays visible.
      assert.is_false(M._is_static("/p/target"))
      assert.is_false(M._is_static("/p/build"))
      assert.is_false(M._is_static("/p/dist"))
      assert.is_false(M._is_static("/p/bin"))
      assert.is_false(M._is_static("/p/vendor"))
      assert.is_false(M._is_static("/p/.idea"))
      assert.is_false(M._is_static("/p/Pods"))
    end)

    it("returns false for an ordinary path", function()
      assert.is_false(M._is_static("/p/src/main.rs"))
      assert.is_false(M._is_static("/p/README.md"))
    end)
  end)

  describe("is_ignored (synchronous predicate)", function()
    it("hides a static heavy dir immediately, with no enqueue/git", function()
      assert.is_true(M.is_ignored("/repo/node_modules"))
    end)

    it("fails open (shows) on a first, unknown non-static path", function()
      -- The oracle resolves it asynchronously; the synchronous answer must not
      -- block, so an unresolved path is shown until the batch lands.
      assert.is_false(M.is_ignored("/repo/some/unknown/dir"))
    end)
  end)

  describe("_partition", function()
    it("groups paths by their containing directory's toplevel", function()
      -- root_fn stub: dirname -> toplevel. Mirrors util.git.root resolving a
      -- path inside a submodule to that submodule's own toplevel.
      local function root_fn(dir)
        if dir:find("^/super/subA") then
          return "/super/subA"
        elseif dir:find("^/super") then
          return "/super"
        end
        return nil
      end

      local by_top, unrooted = M._partition({
        "/super/subA/target", -- inside submodule subA
        "/super/subA/x/y", -- deeper inside subA
        "/super/pkg/build", -- superproject
        "/elsewhere/thing", -- outside any work tree
      }, root_fn)

      assert.are.same({ "/super/subA/target", "/super/subA/x/y" }, by_top["/super/subA"])
      assert.are.same({ "/super/pkg/build" }, by_top["/super"])
      assert.are.same({ "/elsewhere/thing" }, unrooted)
    end)

    it("returns empty tables when nothing resolves to a repo", function()
      local by_top, unrooted = M._partition({ "/no/repo/here" }, function()
        return nil
      end)
      assert.are.same({}, by_top)
      assert.are.same({ "/no/repo/here" }, unrooted)
    end)
  end)

  describe("_parse_check_ignore", function()
    it("splits the NUL-delimited ignored subset into a lookup set", function()
      local hit = M._parse_check_ignore("/r/target\0/r/sub/build\0")
      assert.is_true(hit["/r/target"])
      assert.is_true(hit["/r/sub/build"])
      assert.is_nil(hit["/r/src"])
    end)

    it("returns an empty set for empty/nil output (rc 1 or error)", function()
      assert.are.same({}, M._parse_check_ignore(""))
      assert.are.same({}, M._parse_check_ignore(nil))
    end)
  end)

  describe("setup", function()
    it("registers a BufWritePost(.gitignore/exclude) invalidation autocmd", function()
      M.setup()
      local au = vim.api.nvim_get_autocmds({
        group = "ignore_filter",
        event = "BufWritePost",
      })
      assert.is_true(#au >= 1)
    end)
  end)
end)
