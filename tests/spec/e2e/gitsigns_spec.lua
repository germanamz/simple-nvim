local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "mx", false)
end

local function build_original()
  local out = {}
  for i = 1, 40 do
    table.insert(out, "-- line " .. i)
  end
  return table.concat(out, "\n") .. "\n"
end

local function build_modified()
  local out = {}
  for i = 1, 40 do
    if i == 5 then
      table.insert(out, "-- line 5 CHANGED")
    elseif i == 12 then
      table.insert(out, "-- line 12")
      table.insert(out, "-- inserted A")
      table.insert(out, "-- inserted B")
    elseif i == 30 or i == 31 then
      -- delete: skip these two lines
    else
      table.insert(out, "-- line " .. i)
    end
  end
  return table.concat(out, "\n") .. "\n"
end

describe("e2e: gitsigns", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    require("lazy").load({ plugins = { "gitsigns.nvim" } })
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("navigates between three hunks and wraps", function()
    local repo = git_fixture.repo({
      commits = {
        { files = { ["a.lua"] = build_original() }, message = "init" },
      },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo

    -- write modified content
    local f = assert(io.open(canonical .. "/a.lua", "w"))
    f:write(build_modified())
    f:close()

    -- sanity check: git diff produces 3 hunks
    local diff_lines = vim.fn.systemlist({ "git", "-C", canonical, "diff", "--unified=0", "a.lua" })
    local hunk_headers = 0
    for _, line in ipairs(diff_lines) do
      if line:sub(1, 2) == "@@" then
        hunk_headers = hunk_headers + 1
      end
    end
    assert.are.equal(3, hunk_headers, "expected 3 hunk headers in git diff")

    vim.fn.chdir(canonical)
    vim.cmd("edit " .. canonical .. "/a.lua")
    local bufnr = vim.api.nvim_get_current_buf()

    wait.wait_for(function()
      return vim.b[bufnr].gitsigns_status ~= nil
    end, 5000, "gitsigns_status never set on buffer")

    local gs = require("gitsigns")
    wait.wait_for(function()
      local hunks = gs.get_hunks(bufnr) or {}
      return #hunks == 3
    end, 5000, "gitsigns did not produce 3 hunks")

    local hunks = gs.get_hunks(bufnr)
    table.sort(hunks, function(a, b)
      return a.added.start < b.added.start
    end)

    local function in_hunk(line, h)
      local start = h.added.start
      local count = math.max(h.added.count or 0, 1)
      return line >= start and line < start + count
    end

    -- hunk 1 should be at line 5 (change)
    assert.are.equal(5, hunks[1].added.start, "expected first hunk at line 5")

    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    press("]c")
    wait.wait_for(function()
      return in_hunk(vim.api.nvim_win_get_cursor(0)[1], hunks[1])
    end, 2000, "first ]c did not land in hunk 1")

    press("]c")
    wait.wait_for(function()
      return in_hunk(vim.api.nvim_win_get_cursor(0)[1], hunks[2])
    end, 2000, "second ]c did not land in hunk 2")

    press("]c")
    wait.wait_for(function()
      return in_hunk(vim.api.nvim_win_get_cursor(0)[1], hunks[3])
    end, 2000, "third ]c did not land in hunk 3")

    press("]c")
    wait.wait_for(function()
      return in_hunk(vim.api.nvim_win_get_cursor(0)[1], hunks[1])
    end, 2000, "wrap ]c did not return to hunk 1")

    vim.api.nvim_win_set_cursor(0, { hunks[3].added.start, 0 })
    press("[c")
    wait.wait_for(function()
      return in_hunk(vim.api.nvim_win_get_cursor(0)[1], hunks[2])
    end, 2000, "[c from hunk 3 did not land in hunk 2")
  end)

  it("diffs against review base when configured", function()
    local repo = git_fixture.repo({
      commits = {
        { files = { ["a.lua"] = "-- v1\n" }, message = "init" },
        { files = { ["a.lua"] = "-- v2\n" }, message = "second" },
      },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo
    vim.fn.chdir(canonical)
    require("config.review_base").set(canonical, "HEAD~1")

    vim.cmd("edit " .. canonical .. "/a.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    wait.wait_for(function()
      return vim.b[bufnr].gitsigns_status ~= nil
    end, 5000, "gitsigns_status never set on buffer")

    wait.wait_for(function()
      local h = require("gitsigns").get_hunks(bufnr) or {}
      return #h >= 1
    end, 5000, "gitsigns did not produce hunks against review base")

    local hunks = require("gitsigns").get_hunks(bufnr)
    assert.is_true(#hunks >= 1, "expected ≥1 hunk vs HEAD~1, got " .. #hunks)

    require("config.review_base").clear(canonical)
  end)
end)
