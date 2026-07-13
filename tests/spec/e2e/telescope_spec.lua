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

  describe("normal-mode default + two-stage escape", function()
    local function open_find_files()
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "return 1\n" }, message = "init" } },
      })
      vim.fn.chdir(repo)
      press("<Space>ff")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })
    end

    local function mode()
      return vim.api.nvim_get_mode().mode
    end

    local function wait_for_mode(want, msg)
      wait.wait_for(function()
        return mode() == want
      end, 2000, msg)
    end

    it("opens the picker in normal mode", function()
      open_find_files()
      wait_for_mode("n", "picker did not open in normal mode")
      assert.are.equal("n", mode())
      close_picker()
    end)

    it("closes on <Esc> from normal mode", function()
      open_find_files()
      wait_for_mode("n", "picker did not open in normal mode")

      press("<Esc>")
      wait.wait_for(function()
        return not is_telescope_open()
      end, 2000, "<Esc> did not close the picker from normal mode")
      assert.is_false(is_telescope_open())
    end)

    -- Headless Neovim can't actually enter insert mode in a `buftype=prompt`
    -- window (no UI attached, so even `startinsert` is a no-op). We therefore
    -- assert the resolved insert-mode wiring instead of driving the live
    -- transition: <Esc> must be our own callback (stopinsert -> normal mode),
    -- NOT telescope's close action, while <C-c> must still close.
    it("wires insert-mode <Esc> to leave insert (not close), <C-c> still closes", function()
      open_find_files()
      wait_for_mode("n", "picker did not open in normal mode")

      local prompt_buf = assert(current_prompt_buf(), "no telescope prompt buffer")
      local maps = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(prompt_buf, "i")) do
        maps[m.lhs] = m
      end

      local esc = assert(maps["<Esc>"], "no insert-mode <Esc> mapping on the prompt buffer")
      assert.are.equal("function", type(esc.callback), "insert <Esc> should map to a Lua function")
      -- Telescope tags its built-in close action with desc "telescope|close".
      assert.is_nil(
        (esc.desc or ""):find("close", 1, true),
        "insert <Esc> should not be the close action, got desc: " .. tostring(esc.desc)
      )

      local cc = assert(maps["<C-C>"], "no insert-mode <C-c> mapping on the prompt buffer")
      assert.is_truthy(
        (cc.desc or ""):find("close", 1, true),
        "insert <C-c> should still close, got desc: " .. tostring(cc.desc)
      )

      close_picker()
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
    it("prefixes each file with its git-status code (worktree + vs base)", function()
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

      local function line_for(name)
        for _, line in ipairs(lines) do
          if line:find(name, 1, true) then
            return line
          end
        end
        return nil
      end

      -- Each row is rendered as: <2-cell telescope gutter><2-char prefix>...
      -- The gutter is the selection caret ("▶ ") on the active row and two
      -- spaces otherwise. Strip it, then the prefix is the leading two chars.
      local function assert_prefix(name, prefix)
        local line = line_for(name)
        assert.is_not_nil(line, name .. " missing from results: " .. vim.inspect(lines))
        local body = line:gsub("^▶ ", ""):gsub("^  ", "")
        assert.are.equal(
          prefix,
          body:sub(1, 2),
          name .. " expected prefix '" .. prefix .. "', got line: " .. vim.inspect(line)
        )
      end

      assert_prefix("staged.lua", "A ") -- staged add
      assert_prefix("modified.lua", "M*") -- unstaged worktree modification
      assert_prefix("untracked.lua", "?*") -- untracked
      assert_prefix("committed.lua", "bA") -- added in a commit since base
      assert_prefix("base.lua", "  ") -- unchanged, no status

      close_picker()
      require("config.review_base").clear(canonical)
      assert.is_false(is_telescope_open())
    end)
  end)

  describe("<leader>fb (buffers + flags legend)", function()
    -- The legend float is non-focusable and holds both "+ modified" and
    -- "= read-only"; no other test window contains that pair.
    local function legend_win()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        if text:find("+ modified", 1, true) and text:find("= read-only", 1, true) then
          return win
        end
      end
      return nil
    end

    -- Deleted in an after_each (not at the end of the it-block) so a failing
    -- wait doesn't leak the listed buffer into later specs of this shared
    -- session.
    local target_buf

    after_each(function()
      if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
        pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
      end
      target_buf = nil
    end)

    it("shows a flags legend under the picker and closes it with the picker", function()
      -- A named listed buffer for the picker to show, created via the API so
      -- no BufReadPost/FileType/LSP autocmd chain fires: the shared headless
      -- session caches the LSP log path from the FIRST isolated env, so
      -- editing a real .lua file in a later env errors mid-autocmd (and that
      -- error leaks into the next spec).
      target_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(target_buf, root .. "/legend-target.txt")

      press("<Space>fb")
      wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

      wait.wait_for(function()
        return legend_win() ~= nil
      end, 3000, "flags legend float did not appear")

      local win = assert(legend_win())
      assert.is_false(
        vim.api.nvim_win_get_config(win).focusable,
        "legend float should not be focusable"
      )

      close_picker()
      wait.wait_for(function()
        return legend_win() == nil
      end, 2000, "flags legend float did not close with the picker")
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
