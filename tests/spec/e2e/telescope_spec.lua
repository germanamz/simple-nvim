local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "mx", false)
end

local function is_telescope_open()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then
      return true
    end
  end
  return false
end

local function current_prompt_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then
      return buf
    end
  end
  return nil
end

local function close_picker()
  press("<Esc>")
  wait.wait_for(function()
    return not is_telescope_open()
  end, 2000, "telescope picker did not close")
end

describe("e2e: telescope", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    require("lazy").load({ plugins = { "telescope.nvim" } })
  end)

  after_each(function()
    if is_telescope_open() then
      pcall(close_picker)
    end
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  describe("<leader>ff (find_files)", function()
    it("opens picker", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "return 1\n" }, message = "init" } },
      })
      vim.fn.chdir(repo)

      press("<Space>ff")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

      local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
      local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
      assert.is_not_nil(picker, "no current picker")
      assert.is_truthy(
        picker.prompt_title:lower():find("find files", 1, true),
        "expected prompt_title to contain 'find files', got: " .. tostring(picker.prompt_title)
      )

      close_picker()
      assert.is_false(is_telescope_open())
    end)
  end)

  describe("<leader>fg (live_grep)", function()
    it("opens picker", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "return 1\n" }, message = "init" } },
      })
      vim.fn.chdir(repo)

      press("<Space>fg")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

      local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
      local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
      assert.is_not_nil(picker, "no current picker")
      assert.is_truthy(
        picker.prompt_title:lower():find("live grep", 1, true),
        "expected prompt_title to contain 'live grep', got: " .. tostring(picker.prompt_title)
      )

      close_picker()
      assert.is_false(is_telescope_open())
    end)
  end)

  describe("<leader><space> (smart_files)", function()
    it("orders results: staged, modified, untracked, committed, others", function()
      local repo = git_fixture.repo({
        commits = {
          {
            files = {
              ["base.lua"] = "-- base\n",
              ["modified.lua"] = "-- original\n",
            },
            message = "init",
          },
          {
            files = { ["committed.lua"] = "-- new commit\n" },
            message = "feature",
          },
        },
        staged = { ["staged.lua"] = "-- staged\n" },
        modified = { ["modified.lua"] = "-- changed\n" },
        untracked = { ["untracked.lua"] = "-- untracked\n" },
      })
      local canonical = vim.uv.fs_realpath(repo) or repo
      vim.fn.chdir(canonical)
      require("config.review_base").set(canonical, "HEAD~1")

      press("<Space><Space>")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

      local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
      local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
      assert.is_not_nil(picker, "no current picker")

      local function non_empty_lines()
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)) do
          if line ~= "" then
            table.insert(out, line)
          end
        end
        return out
      end

      wait.wait_for(function()
        return #non_empty_lines() >= 5
      end, 5000, "results did not populate")

      local lines = non_empty_lines()

      local function find_index(name)
        for i, line in ipairs(lines) do
          if line:find(name, 1, true) then
            return i
          end
        end
        return nil
      end

      local staged_idx = find_index("staged.lua")
      local modified_idx = find_index("modified.lua")
      local untracked_idx = find_index("untracked.lua")
      local committed_idx = find_index("committed.lua")
      local base_idx = find_index("base.lua")

      assert.is_not_nil(staged_idx, "staged.lua missing from results: " .. vim.inspect(lines))
      assert.is_not_nil(modified_idx, "modified.lua missing from results: " .. vim.inspect(lines))
      assert.is_not_nil(untracked_idx, "untracked.lua missing from results: " .. vim.inspect(lines))
      assert.is_not_nil(committed_idx, "committed.lua missing from results: " .. vim.inspect(lines))
      assert.is_not_nil(base_idx, "base.lua missing from results: " .. vim.inspect(lines))

      assert.is_true(
        staged_idx < modified_idx,
        "expected staged before modified: " .. vim.inspect(lines)
      )
      assert.is_true(
        modified_idx < untracked_idx,
        "expected modified before untracked: " .. vim.inspect(lines)
      )
      assert.is_true(
        untracked_idx < committed_idx,
        "expected untracked before committed: " .. vim.inspect(lines)
      )
      assert.is_true(
        committed_idx < base_idx,
        "expected committed before others: " .. vim.inspect(lines)
      )

      assert.is_truthy(lines[staged_idx]:find("◆", 1, true), "staged row missing ◆ icon")
      assert.is_truthy(lines[modified_idx]:find("●", 1, true), "modified row missing ● icon")
      assert.is_truthy(lines[untracked_idx]:find("○", 1, true), "untracked row missing ○ icon")
      assert.is_truthy(lines[committed_idx]:find("◈", 1, true), "committed row missing ◈ icon")

      close_picker()
      require("config.review_base").clear(canonical)
      assert.is_false(is_telescope_open())
    end)
  end)

  describe("<leader>gB (review_base picker)", function()
    it("opens picker with [ clear base ] entry and branch list", function()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "return 1\n" }, message = "init" } },
      })
      vim.fn.system({ "git", "-C", repo, "branch", "feature" })
      assert.are.equal(0, vim.v.shell_error)
      vim.fn.chdir(repo)

      press("<Space>gB")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

      local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
      local picker = require("telescope.actions.state").get_current_picker(prompt_buf)
      assert.is_not_nil(picker, "no current picker")
      assert.is_truthy(
        picker.prompt_title:lower():find("review base", 1, true),
        "expected prompt_title to contain 'Review base', got: " .. tostring(picker.prompt_title)
      )

      local function non_empty_lines()
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)) do
          if line ~= "" then
            table.insert(out, line)
          end
        end
        return out
      end

      wait.wait_for(function()
        return #non_empty_lines() >= 3
      end, 5000, "results did not populate")

      local lines = non_empty_lines()
      assert.is_truthy(
        lines[1]:find("clear base", 1, true),
        "expected first entry to be '[ clear base ]', got: " .. vim.inspect(lines[1])
      )

      local joined = table.concat(lines, "\n")
      assert.is_truthy(
        joined:find("main", 1, true),
        "expected branch 'main' in results: " .. joined
      )
      assert.is_truthy(
        joined:find("feature", 1, true),
        "expected branch 'feature' in results: " .. joined
      )

      close_picker()
      assert.is_false(is_telescope_open())
    end)
  end)
end)
