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

local function custom_marks(bufnr)
  local ns = vim.api.nvim_create_namespace("gs_custom")
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- Count only the extmarks that actually paint a line background. For a file
-- that's new vs the review base the painter always lays down an extmark per
-- line (to keep the colored line number), and toggles just the hl_group/hl_eol
-- — so #extmarks stays constant. The visible-background count is what flips.
local function visible_bg_marks(bufnr)
  local ns = vim.api.nvim_create_namespace("gs_custom")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local n = 0
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group then
      n = n + 1
    end
  end
  return n
end

local function open_modified_repo()
  local repo = git_fixture.repo({
    commits = { { files = { ["a.lua"] = build_original() }, message = "init" } },
    modified = { ["a.lua"] = build_modified() },
  })
  local canonical = vim.uv.fs_realpath(repo) or repo
  vim.fn.chdir(canonical)
  vim.cmd("edit " .. canonical .. "/a.lua")
  return vim.api.nvim_get_current_buf()
end

-- Open a brand-new file (untracked, absent from the review base). gitsigns does
-- not attach to untracked files, so the buffer only ever gets the custom
-- new-vs-base painting — never gitsigns' own attach/on_attach path.
local function open_new_vs_base_file()
  local repo = git_fixture.repo({
    commits = { { files = { ["a.lua"] = "-- a\n" }, message = "init" } },
  })
  local canonical = vim.uv.fs_realpath(repo) or repo
  vim.fn.chdir(canonical)
  require("config.review_base").set(canonical, "HEAD")

  local f = assert(io.open(canonical .. "/new.lua", "w"))
  f:write("-- new 1\n-- new 2\n-- new 3\n")
  f:close()

  vim.cmd("edit " .. canonical .. "/new.lua")
  local bufnr = vim.api.nvim_get_current_buf()

  -- drive the custom painter and make sure highlights start in the shown state
  -- regardless of where a previous test left the global toggle.
  local function paint()
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", modeline = false })
  end
  paint()
  wait.wait_for(function()
    return vim.b[bufnr].gs_new_vs_base == true
  end, 5000, "new file never flagged new-vs-base")
  if visible_bg_marks(bufnr) == 0 then
    _G.gitsigns_toggle_hunks()
    paint()
  end
  wait.wait_for(function()
    return visible_bg_marks(bufnr) > 0
  end, 3000, "new-file add highlights never shown")
  return bufnr, canonical
end

-- Drive the global hunks_visible state to "shown" for a buffer that has hunks,
-- regardless of where a previous test left it. Forcing a GitSignsUpdate makes
-- the custom painter run synchronously, so the extmark count reflects the real
-- toggle state before we decide whether to flip it.
local function ensure_shown(bufnr)
  wait.wait_for(function()
    return (require("gitsigns").get_hunks(bufnr) or {})[1] ~= nil
  end, 5000, "gitsigns produced no hunks")
  vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", modeline = false })
  if custom_marks(bufnr) == 0 then
    _G.gitsigns_toggle_hunks()
  end
  wait.wait_for(function()
    return custom_marks(bufnr) > 0
  end, 3000, "hunk highlights were not shown")
end

describe("e2e: gitsigns", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    require("lazy").load({ plugins = { "gitsigns.nvim" } })
  end)

  after_each(function()
    -- gitsigns' current-line blame (delay=0) computes asynchronously via a git
    -- subprocess; an in-flight run_blame coroutine that resumes after the buffer
    -- is wiped throws "Invalid buffer id". gitsigns writes
    -- b:gitsigns_blame_line_dict when that computation lands, so we await that
    -- signal (not a fixed sleep) before wiping — it returns the instant blame
    -- settles, with the timeout only as a safety ceiling.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].gitsigns_status ~= nil then
        vim.wait(5000, function()
          return vim.b[buf].gitsigns_blame_line_dict ~= nil
        end, 10)
      end
    end
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

  it("hides hunk highlights and restores them on toggle", function()
    local bufnr = open_modified_repo()
    ensure_shown(bufnr)

    -- toggle OFF clears the custom line-background extmarks immediately
    _G.gitsigns_toggle_hunks()
    wait.wait_for(function()
      return custom_marks(bufnr) == 0
    end, 2000, "hunk highlights not cleared on toggle off")
    assert.are.equal(0, custom_marks(bufnr))

    -- toggle ON: backgrounds reappear once gitsigns' hunk cache recovers.
    -- Regression: toggle_word_diff invalidates that cache and does NOT fire
    -- GitSignsUpdate, so a naive synchronous repaint leaves this at 0 forever.
    _G.gitsigns_toggle_hunks()
    wait.wait_for(function()
      return custom_marks(bufnr) > 0
    end, 3000, "hunk highlights did not reappear on toggle on")
    assert.is_true(custom_marks(bufnr) > 0)
  end)

  it("keeps statusline hunk counts while highlights are hidden", function()
    local bufnr = open_modified_repo()
    ensure_shown(bufnr)

    _G.gitsigns_toggle_hunks() -- hide
    wait.wait_for(function()
      return custom_marks(bufnr) == 0
    end, 2000, "hunk highlights not cleared on toggle off")

    -- counts come straight from gs.get_hunks, independent of the visibility
    -- toggle, so they stay reported even with the backgrounds hidden.
    wait.wait_for(function()
      return _G.gitsigns_hunks_status():find("%+%d") ~= nil
    end, 3000, "hunk counts vanished while highlights were hidden")
    assert.are.equal(0, custom_marks(bufnr))
    assert.is_not_nil(_G.gitsigns_hunks_status():find("%+%d"))
  end)

  it("registers <leader>hh to toggle hunk highlights", function()
    open_modified_repo()
    -- <leader>hh is a global map (set in config), not buffer-local: it must work
    -- even in buffers gitsigns never attaches to, where on_attach never runs.
    local found
    wait.wait_for(function()
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.lhs == " hh" then
          found = m
          return true
        end
      end
      return false
    end, 5000, "<leader>hh never registered")

    assert.is_not_nil(found, "<leader>hh not registered")
    assert.is_not_nil(found.desc and found.desc:lower():find("toggle hunk"))
  end)

  it("toggles hunk highlights via <leader>hh on a new (unattached) file", function()
    local bufnr = open_new_vs_base_file()

    -- gitsigns never attaches to an untracked file, so the toggle keymap must
    -- exist independently of on_attach for the press to do anything.
    press(" hh") -- hide
    wait.wait_for(function()
      return visible_bg_marks(bufnr) == 0
    end, 2000, "<leader>hh did not hide add highlights on new file")
    assert.are.equal(0, visible_bg_marks(bufnr))

    press(" hh") -- show
    wait.wait_for(function()
      return visible_bg_marks(bufnr) > 0
    end, 3000, "<leader>hh did not restore add highlights on new file")
    assert.is_true(visible_bg_marks(bufnr) > 0)

    require("config.review_base").clear(vim.fn.getcwd())
  end)
end)
