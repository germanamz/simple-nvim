local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

local resolved = vim.fn.resolve

-- config.dir_cache drops the directory-keyed resolution caches (util.git's
-- root_cache, conform's python pyproject cache) when the repo topology can
-- change under a directory: a cwd change, or a .gitmodules edit (a submodule
-- add/remove without a cd). Without it, a dir that gains or loses repo
-- membership keeps resolving to its old (cached) toplevel until restart.
describe("config.dir_cache", function()
  local env_root, M, git

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.dir_cache"] = nil
    package.loaded["util.git"] = nil
    package.loaded["config.formatters"] = nil
    M = require("config.dir_cache")
    git = require("util.git")
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "dir_cache_invalidation")
    nvim_env.teardown(env_root)
  end)

  it("registers DirChanged and BufWritePost(.gitmodules) invalidation autocmds", function()
    M.setup()
    local dir_changed = vim.api.nvim_get_autocmds({
      group = "dir_cache_invalidation",
      event = "DirChanged",
    })
    local gitmodules = vim.api.nvim_get_autocmds({
      group = "dir_cache_invalidation",
      event = "BufWritePost",
      pattern = ".gitmodules",
    })
    assert.is_true(#dir_changed >= 1)
    assert.is_true(#gitmodules >= 1)
  end)

  it("re-resolves a dir that gained repo membership after a .gitmodules write", function()
    M.setup()
    local parent = git_fixture.repo({ commits = { { files = { ["a.lua"] = "x" } } } })
    local sub = parent .. "/sub"
    vim.fn.mkdir(sub, "p")
    -- sub resolves to (and is cached as) the parent repo
    assert.are.equal(resolved(parent), resolved(git.root(sub)))
    -- sub becomes its own repo; the cached parent root is now stale
    vim.fn.system({ "git", "-C", sub, "init", "-q", "--initial-branch=main" })
    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = ".gitmodules" })
    assert.are.equal(resolved(sub), resolved(git.root(sub)))
  end)

  it("also drops the python formatter cache on invalidation", function()
    M.setup()
    local cleared = false
    require("config.formatters")._clear_python_cache = function()
      cleared = true
    end
    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = ".gitmodules" })
    assert.is_true(cleared)
  end)
end)
