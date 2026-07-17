-- Pins the testable seams of the per-submodule nvim-tree decorator: the async
-- submodule-set discovery (_subs_for), the repo_status -> segments mapping
-- (_segments_for), and the ColorScheme augroup idempotency. The Decorator class
-- itself needs a loaded nvim-tree, so its live render is exercised in e2e.
local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

describe("config.nvim_tree_submodule", function()
  describe("_subs_for (submodule set discovery)", function()
    local env_root, sub, fired, group

    before_each(function()
      env_root = nvim_env.setup_isolated_env()
      package.loaded["config.nvim_tree_submodule"] = nil
      package.loaded["util.git"] = nil
      package.loaded["config.telescope_smart"] = nil
      sub = require("config.nvim_tree_submodule")
      fired = {}
      group = vim.api.nvim_create_augroup("nvim_tree_submodule_spec", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "RepoStatusChanged",
        callback = function(a)
          table.insert(fired, a.data)
        end,
      })
    end)

    after_each(function()
      sub._reset()
      vim.api.nvim_del_augroup_by_id(group)
      nvim_env.teardown(env_root)
    end)

    local function wait_ready()
      return vim.wait(3000, function()
        return #fired > 0
      end, 10)
    end

    it("returns an empty set for a plain repo with no submodules", function()
      local repo =
        git_fixture.repo({ commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } } })
      assert.are.same({}, sub._subs_for(repo))
    end)

    it("discovers submodule paths (cwd-relative) and fires a repaint when ready", function()
      local sp = git_fixture.superproject({ children = { "childA", "childB" } })
      assert.are.same({}, sub._subs_for(sp.root)) -- cold: empty set + schedule
      assert.is_true(wait_ready())
      -- git.root resolves symlinks (/var -> /private/var on macOS); compare resolved.
      assert.are.equal(vim.fn.resolve(sp.root), vim.fn.resolve(fired[1].dir))
      local set = sub._subs_for(sp.root) -- warm
      assert.is_true(set["childA"])
      assert.is_true(set["childB"])
    end)

    it("includes a nested grandchild submodule", function()
      local sp = git_fixture.superproject({
        children = { "childA" },
        grandchild = { parent = "childA", name = "grand" },
      })
      sub._subs_for(sp.root)
      assert.is_true(wait_ready())
      local set = sub._subs_for(sp.root)
      assert.is_true(set["childA"])
      assert.is_true(set["childA/grand"])
    end)
  end)

  describe("_segments_for (repo_status -> decorator segments)", function()
    local saved

    before_each(function()
      saved = package.loaded["config.repo_status"]
      package.loaded["config.nvim_tree_submodule"] = nil
    end)

    after_each(function()
      package.loaded["config.repo_status"] = saved
      package.loaded["config.nvim_tree_submodule"] = nil
    end)

    it("prepends a gap and returns the status segments when cached", function()
      package.loaded["config.repo_status"] = {
        get = function()
          return { branch = "main" }
        end,
        segments = function()
          return { { str = "main", hl = { "SmartFilesBranch" } } }
        end,
        request = function()
          error("should not request on a cache hit")
        end,
      }
      local sub = require("config.nvim_tree_submodule")
      assert.are.same({
        { str = "  ", hl = {} },
        { str = "main", hl = { "SmartFilesBranch" } },
      }, sub._segments_for("/x/childA"))
    end)

    it("returns nil and schedules a request on a cache miss", function()
      local requested = {}
      package.loaded["config.repo_status"] = {
        get = function()
          return nil
        end,
        request = function(dir)
          table.insert(requested, dir)
        end,
        segments = function()
          return {}
        end,
      }
      local sub = require("config.nvim_tree_submodule")
      assert.is_nil(sub._segments_for("/x/childA"))
      assert.are.same({ "/x/childA" }, requested)
    end)
  end)

  describe("decorator ColorScheme registration", function()
    local saved_api, saved_rs

    local function cs_count()
      return #vim.api.nvim_get_autocmds({ event = "ColorScheme" })
    end

    before_each(function()
      saved_api = package.loaded["nvim-tree.api"]
      saved_rs = package.loaded["config.repo_status"]
      package.loaded["nvim-tree.api"] = {
        Decorator = {
          extend = function()
            return {}
          end,
        },
      }
      package.loaded["config.repo_status"] = { define_highlights = function() end }
      package.loaded["config.nvim_tree_submodule"] = nil
    end)

    after_each(function()
      package.loaded["nvim-tree.api"] = saved_api
      package.loaded["config.repo_status"] = saved_rs
      package.loaded["config.nvim_tree_submodule"] = nil
      pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_submodule_hl")
    end)

    it("keeps exactly one ColorScheme autocmd across a package.loaded reload", function()
      local baseline = cs_count()
      require("config.nvim_tree_submodule").decorator()
      assert.are.equal(baseline + 1, cs_count())

      package.loaded["config.nvim_tree_submodule"] = nil
      require("config.nvim_tree_submodule").decorator()
      assert.are.equal(baseline + 1, cs_count())
    end)
  end)
end)
