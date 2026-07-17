-- Pins the pure directory-marker aggregation of the nvim-tree git decorator:
-- ancestors of a changed file get a marker, worktree changes dominating
-- base-only ones. (The decorator class itself needs a loaded nvim-tree, so it
-- is exercised by the smoke suite, not here.)
local nvim_tree_git = require("config.nvim_tree_git")

describe("config.nvim_tree_git._dir_markers", function()
  it("marks every ancestor directory of a changed file", function()
    local dirs = nvim_tree_git._dir_markers({ ["a/b/c.lua"] = " M" })
    assert.are.same({
      ["a"] = "SmartFilesModified",
      ["a/b"] = "SmartFilesModified",
    }, dirs)
  end)

  it("does not mark anything for top-level files", function()
    assert.are.same({}, nvim_tree_git._dir_markers({ ["c.lua"] = "??" }))
  end)

  it("marks base-only subtrees with the base group", function()
    local dirs = nvim_tree_git._dir_markers({ ["a/c.lua"] = "bM" })
    assert.are.same({ ["a"] = "SmartFilesBase" }, dirs)
  end)

  it("lets a worktree change dominate a base-only sibling", function()
    local dirs = nvim_tree_git._dir_markers({
      ["a/base.lua"] = "bA",
      ["a/work.lua"] = "MM",
    })
    assert.are.same({ ["a"] = "SmartFilesModified" }, dirs)
  end)

  -- A commit-diverged submodule (bumped pointer, clean worktree) contributes no
  -- file codes — the recursion inside it finds nothing — so it only rolls up via
  -- the Tier-0 dirty_subs set: the submodule folder itself AND its ancestors are
  -- marked worktree-dirty.
  it("marks a dirty submodule folder and its ancestors from the dirty_subs set", function()
    local dirs = nvim_tree_git._dir_markers({}, { ["libs/childA"] = true })
    assert.are.same({
      ["libs/childA"] = "SmartFilesModified",
      ["libs"] = "SmartFilesModified",
    }, dirs)
  end)

  it("unions dirty_subs with file-code rollups, worktree dominating", function()
    local dirs = nvim_tree_git._dir_markers({ ["x/base.lua"] = "bM" }, { ["x/sub"] = true })
    assert.are.same({
      ["x"] = "SmartFilesModified", -- x holds the dirty submodule -> dominates base
      ["x/sub"] = "SmartFilesModified",
    }, dirs)
  end)
end)

-- The decorator's directory-icon lookup. path_util.relative :p-normalizes a
-- directory node's path, which APPENDS a trailing slash ("a/b" -> "a/b/"), while
-- _dir_markers keys are slash-free. _dir_icon must strip that slash before the
-- lookup or every directory rollup marker silently vanishes (the original bug).
-- Glyph is by category: "*" flags a subtree holding worktree (uncommitted)
-- changes, "•" a subtree that only differs from the review base.
describe("config.nvim_tree_git._dir_icon", function()
  it("marks a worktree-dirty dir with * despite the trailing slash", function()
    assert.are.same(
      { { str = "*", hl = { "SmartFilesModified" } } },
      nvim_tree_git._dir_icon({ ["a/b"] = "SmartFilesModified" }, "a/b/")
    )
  end)

  it("marks a base-only dir with a • bullet", function()
    assert.are.same(
      { { str = "•", hl = { "SmartFilesBase" } } },
      nvim_tree_git._dir_icon({ ["a"] = "SmartFilesBase" }, "a/")
    )
  end)

  it("returns nil for a clean dir", function()
    assert.is_nil(nvim_tree_git._dir_icon({ ["a"] = "SmartFilesModified" }, "b/"))
  end)
end)

-- refresh_labels must coalesce rapid triggers (rebase, focus toggling): at
-- most one whole-tree pipeline in flight per cwd, plus one queued trailing
-- refresh that runs with the then-current inputs once the in-flight one
-- completes. Without it every trigger spawned an overlapping git pipeline.
describe("config.nvim_tree_git.refresh_labels coalescing", function()
  local saved_tree, saved_api, saved_smart
  local calls, module

  before_each(function()
    saved_tree = package.loaded["nvim-tree"]
    saved_api = package.loaded["nvim-tree.api"]
    saved_smart = package.loaded["config.telescope_smart"]
    package.loaded["nvim-tree"] = true
    package.loaded["nvim-tree.api"] = {
      tree = {
        is_visible = function()
          return true
        end,
        reload = function() end,
      },
    }
    calls = {}
    package.loaded["config.telescope_smart"] = {
      _refresh_async = function(cwd, cb)
        table.insert(calls, { cwd = cwd, cb = cb })
      end,
    }
    package.loaded["config.nvim_tree_git"] = nil
    module = require("config.nvim_tree_git")
  end)

  after_each(function()
    package.loaded["nvim-tree"] = saved_tree
    package.loaded["nvim-tree.api"] = saved_api
    package.loaded["config.telescope_smart"] = saved_smart
    package.loaded["config.nvim_tree_git"] = nil
  end)

  it("coalesces rapid triggers into one running + one trailing refresh", function()
    for _ = 1, 5 do
      module.refresh_labels()
    end
    assert.are.equal(1, #calls)

    calls[1].cb({})
    assert.are.equal(2, #calls)

    calls[2].cb({})
    assert.are.equal(2, #calls)
  end)

  it("spawns a fresh pipeline immediately once idle", function()
    module.refresh_labels()
    calls[1].cb({})
    assert.are.equal(1, #calls)

    module.refresh_labels()
    assert.are.equal(2, #calls)
  end)
end)

-- The repo_status liveness wiring: refresh_labels drops the per-dir branch-fact
-- cache so a focus/HEAD/gR refresh re-resolves visible repos, and a
-- RepoStatusChanged event (fired by config.repo_status / config.nvim_tree_submodule
-- when a resolve lands) reloads the tree so the labels repaint.
describe("config.nvim_tree_git repo_status wiring", function()
  local saved_tree, saved_api, saved_smart, saved_repo, saved_sub
  local reloads, invalidations, revalidations, sub_invalidations, module

  before_each(function()
    saved_tree = package.loaded["nvim-tree"]
    saved_api = package.loaded["nvim-tree.api"]
    saved_smart = package.loaded["config.telescope_smart"]
    saved_repo = package.loaded["config.repo_status"]
    saved_sub = package.loaded["config.submodule_status"]
    reloads, invalidations, revalidations, sub_invalidations = 0, 0, 0, 0
    package.loaded["nvim-tree"] = true
    package.loaded["nvim-tree.api"] = {
      tree = {
        is_visible = function()
          return true
        end,
        reload = function()
          reloads = reloads + 1
        end,
      },
    }
    package.loaded["config.telescope_smart"] = {
      _refresh_async = function() end,
    }
    package.loaded["config.repo_status"] = {
      invalidate_all = function()
        invalidations = invalidations + 1
      end,
      revalidate = function()
        revalidations = revalidations + 1
      end,
    }
    package.loaded["config.submodule_status"] = {
      invalidate_all = function()
        sub_invalidations = sub_invalidations + 1
      end,
    }
    package.loaded["config.nvim_tree_git"] = nil
    module = require("config.nvim_tree_git")
  end)

  after_each(function()
    package.loaded["nvim-tree"] = saved_tree
    package.loaded["nvim-tree.api"] = saved_api
    package.loaded["config.telescope_smart"] = saved_smart
    package.loaded["config.repo_status"] = saved_repo
    package.loaded["config.submodule_status"] = saved_sub
    package.loaded["config.nvim_tree_git"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_git_refresh")
  end)

  it("revalidates (not hard-flushes) the repo_status cache on a plain refresh", function()
    -- The FocusGained path keeps unchanged submodules cached instead of nuking
    -- and re-resolving every visible row.
    module.refresh_labels()
    assert.are.equal(1, revalidations)
    assert.are.equal(0, invalidations)
  end)

  it("hard-flushes both the repo_status and submodule_status caches on a hard refresh", function()
    -- HeadChanged / ReviewBaseChanged / <leader>gR pass { hard = true } so even a
    -- submodule whose cheap index key is unchanged (a bare external edit) re-scans.
    module.refresh_labels({ hard = true })
    assert.are.equal(1, invalidations)
    assert.are.equal(1, sub_invalidations)
    assert.are.equal(0, revalidations)
  end)

  it("reloads a visible tree when RepoStatusChanged fires", function()
    module.register_autocmds()
    local before = reloads
    vim.api.nvim_exec_autocmds("User", { pattern = "RepoStatusChanged", data = { dir = "/x" } })
    assert.are.equal(before + 1, reloads)
  end)
end)

-- decorator() registers a ColorScheme re-highlight autocmd. It must live in a
-- named augroup (clear = true): a package.loaded reset plus re-require empties
-- the module-scope Decorator memo, and an ungrouped autocmd would stack a
-- duplicate instead of replacing.
describe("config.nvim_tree_git.decorator ColorScheme registration", function()
  local saved_api

  local function colorscheme_count()
    return #vim.api.nvim_get_autocmds({ event = "ColorScheme" })
  end

  before_each(function()
    saved_api = package.loaded["nvim-tree.api"]
    package.loaded["nvim-tree.api"] = {
      Decorator = {
        extend = function()
          return {}
        end,
      },
    }
  end)

  after_each(function()
    package.loaded["nvim-tree.api"] = saved_api
    package.loaded["config.nvim_tree_git"] = nil
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_git_hl")
  end)

  it("keeps exactly one autocmd across a package.loaded reload", function()
    local baseline = colorscheme_count()
    require("config.nvim_tree_git").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())

    package.loaded["config.nvim_tree_git"] = nil
    require("config.nvim_tree_git").decorator()
    assert.are.equal(baseline + 1, colorscheme_count())
  end)
end)

-- register_autocmds() runs from the plugin's config(), which re-runs on
-- :Lazy reload. Without a cleared augroup each re-run would stack duplicate
-- handlers (N re-runs = N git pipelines per FocusGained).
describe("config.nvim_tree_git.register_autocmds", function()
  local function counts()
    return {
      review = #vim.api.nvim_get_autocmds({ event = "User", pattern = "ReviewBaseChanged" }),
      head = #vim.api.nvim_get_autocmds({ event = "User", pattern = "HeadChanged" }),
      refreshed = #vim.api.nvim_get_autocmds({ event = "User", pattern = "SmartCodesRefreshed" }),
      reposstatus = #vim.api.nvim_get_autocmds({ event = "User", pattern = "RepoStatusChanged" }),
      focus = #vim.api.nvim_get_autocmds({ event = "FocusGained" }),
    }
  end

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "nvim_tree_git_refresh")
  end)

  it("registers each handler exactly once even when called twice", function()
    local baseline = counts()
    nvim_tree_git.register_autocmds()
    nvim_tree_git.register_autocmds()
    local after = counts()
    assert.are.equal(baseline.review + 1, after.review)
    assert.are.equal(baseline.head + 1, after.head)
    assert.are.equal(baseline.refreshed + 1, after.refreshed)
    assert.are.equal(baseline.reposstatus + 1, after.reposstatus)
    assert.are.equal(baseline.focus + 1, after.focus)
  end)
end)
