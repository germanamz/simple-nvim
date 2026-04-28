local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "mx", false)
end

local function diffview_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local ft = vim.bo[buf].filetype
      if name:match("^diffview:///") or ft:match("^Diffview") then
        table.insert(out, buf)
      end
    end
  end
  return out
end

local function diffview_view_active()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return false
  end
  local view = lib.get_current_view()
  return view ~= nil
end

describe("e2e: diffview", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    require("lazy").load({ plugins = { "diffview.nvim" } })
  end)

  after_each(function()
    pcall(vim.cmd, "DiffviewClose")
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  local function build_repo()
    local repo = git_fixture.repo({
      commits = {
        { files = { ["a.lua"] = "-- v1\n" }, message = "init" },
        { files = { ["a.lua"] = "-- v2\n" }, message = "second" },
      },
    })
    git_fixture.with_remote(repo, "origin")
    -- third commit advances HEAD beyond origin/main
    local f = assert(io.open(repo .. "/a.lua", "w"))
    f:write("-- v3 committed\n")
    f:close()
    vim.fn.system({ "git", "-C", repo, "add", "a.lua" })
    vim.fn.system({
      "git",
      "-C",
      repo,
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "user.name=Test User",
      "commit",
      "-m",
      "third",
      "--no-gpg-sign",
    })
    -- working-tree change vs index
    f = assert(io.open(repo .. "/a.lua", "w"))
    f:write("-- v4 working tree\n")
    f:close()
    return vim.uv.fs_realpath(repo) or repo
  end

  it("<leader>gd opens working tree vs index, q closes", function()
    local canonical = build_repo()
    vim.fn.chdir(canonical)

    press("<Space>gd")
    wait.wait_for(function()
      return #diffview_buffers() >= 2 and diffview_view_active()
    end, 5000, "diffview did not open ≥2 buffers")

    press("q")
    wait.wait_for(function()
      return not diffview_view_active() and #diffview_buffers() == 0
    end, 5000, "diffview did not close")
    assert.is_false(diffview_view_active())
    assert.are.equal(0, #diffview_buffers())
  end)

  it("<leader>gm opens branch vs origin/main", function()
    local canonical = build_repo()
    vim.fn.chdir(canonical)

    press("<Space>gm")
    wait.wait_for(function()
      return #diffview_buffers() >= 2 and diffview_view_active()
    end, 5000, "diffview did not open ≥2 buffers")

    local lib = require("diffview.lib")
    local view = lib.get_current_view()
    assert.is_not_nil(view, "no current diffview view")
    assert.is_truthy(
      view.rev_arg and view.rev_arg:find("origin/main", 1, true),
      "expected view.rev_arg to contain 'origin/main', got: " .. tostring(view.rev_arg)
    )

    press("q")
    wait.wait_for(function()
      return not diffview_view_active() and #diffview_buffers() == 0
    end, 5000, "diffview did not close")
    assert.is_false(diffview_view_active())
  end)
end)
