local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

-- Pins config.file_reference: the `path:line` string <leader>yl puts on the
-- clipboard. The interesting part is which directory the path is relative to —
-- the buffer's work tree normally, the *superproject* when the buffer lives in
-- a submodule of the tree we are sitting in (a bare `file.lua:42` cannot say
-- which of 200 submodules it means).

describe("config.file_reference.base", function()
  local ref = require("config.file_reference")

  it("uses the buffer's work tree", function()
    assert.are.equal("/repo", ref.base("/repo/a/b.lua", "/repo", "/repo", "/repo"))
  end)

  it("prefers the superproject when the buffer sits in one of its submodules", function()
    assert.are.equal("/repo", ref.base("/repo/sub/b.lua", "/repo/sub", "/repo", "/repo"))
  end)

  it("keeps the submodule root when the cwd is in an unrelated repo", function()
    assert.are.equal("/repo/sub", ref.base("/repo/sub/b.lua", "/repo/sub", "/other", "/other"))
  end)

  it("keeps the git root when the cwd is not in a repo at all", function()
    assert.are.equal("/repo", ref.base("/repo/a.lua", "/repo", "/home/me", nil))
  end)

  it("does not treat a sibling with a shared prefix as a superproject", function()
    assert.are.equal("/repo-other", ref.base("/repo-other/a.lua", "/repo-other", "/repo", "/repo"))
  end)

  it("falls back to the cwd outside any work tree", function()
    assert.are.equal("/scratch", ref.base("/scratch/a.lua", nil, "/scratch", nil))
  end)

  it("gives up (absolute path) for a file outside both the cwd and any repo", function()
    assert.is_nil(ref.base("/elsewhere/a.lua", nil, "/scratch", nil))
  end)
end)

describe("config.file_reference.reference", function()
  local env_root, ref, cwd

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    cwd = vim.fn.getcwd()
    package.loaded["util.git"] = nil
    package.loaded["config.file_reference"] = nil
    ref = require("config.file_reference")
  end)

  after_each(function()
    vim.fn.chdir(cwd)
    nvim_env.teardown(env_root)
  end)

  -- A buffer named after a real file, without :edit — nothing here needs the
  -- contents, and the isolated env should stay free of filetype machinery.
  local function buf_for(file)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, file)
    return buf
  end

  it("renders path:line relative to the repo root", function()
    local repo =
      git_fixture.repo({ commits = { { files = { ["a/b.lua"] = "-- b\n" }, message = "init" } } })
    assert.are.equal("a/b.lua:42", ref.reference(buf_for(repo .. "/a/b.lua"), 42))
  end)

  it("renders a line span for a multi-line selection", function()
    local repo =
      git_fixture.repo({ commits = { { files = { ["a.lua"] = "-- a\n" }, message = "init" } } })
    local buf = buf_for(repo .. "/a.lua")
    assert.are.equal("a.lua:10-20", ref.reference(buf, 10, 20))
    -- A one-line selection is still a single line, not a 10-10 range.
    assert.are.equal("a.lua:10", ref.reference(buf, 10, 10))
  end)

  it("prefixes the submodule path when the cwd is the superproject", function()
    local fixture = git_fixture.superproject({ children = { "child" } })
    vim.fn.chdir(fixture.root)
    local buf = buf_for(fixture.children.child .. "/child.txt")
    assert.are.equal("child/child.txt:3", ref.reference(buf, 3))
  end)

  it("returns nil for a buffer with no file", function()
    assert.is_nil(ref.reference(vim.api.nvim_create_buf(false, true), 1))
  end)
end)

describe("config.file_reference.relpath", function()
  local ref = require("config.file_reference")
  local git_fixture = require("helpers.git_fixture")

  local prev_cwd

  before_each(function()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd.cd(prev_cwd)
  end)

  --- A buffer named `path` without going through :edit (which would attach an
  --- LSP client for a .lua file).
  local function named_buf(path)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, path)
    return buf
  end

  it("is relative to the work tree", function()
    local root = git_fixture.repo({
      commits = { { files = { ["a/b.lua"] = "return 1\n" }, message = "init" } },
    })
    vim.cmd.cd(root)
    assert.are.equal("a/b.lua", ref.relpath(named_buf(root .. "/a/b.lua")))
  end)

  it("is nil for a buffer with no file", function()
    assert.is_nil(ref.relpath(vim.api.nvim_create_buf(false, true)))
  end)
end)
