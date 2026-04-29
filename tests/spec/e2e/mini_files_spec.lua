local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "mx", false)
end

local function minifiles_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "minifiles" then
      table.insert(out, buf)
    end
  end
  return out
end

local function is_minifiles_open()
  return require("mini.files").get_explorer_state() ~= nil
end

local function close_explorer()
  if is_minifiles_open() then
    require("mini.files").close()
  end
  wait.wait_for(function()
    return not is_minifiles_open()
  end, 2000, "mini.files did not close")
end

local function make_fixture_dir()
  local dir = vim.fn.tempname() .. "-mini-files"
  vim.fn.mkdir(dir, "p")
  vim.fn.mkdir(dir .. "/sub", "p")
  local f = assert(io.open(dir .. "/top.txt", "w"))
  f:write("top\n")
  f:close()
  f = assert(io.open(dir .. "/sub/nested.txt", "w"))
  f:write("nested\n")
  f:close()
  return vim.uv.fs_realpath(dir) or dir
end

describe("e2e: mini.files", function()
  local root, prev_cwd, fixture

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    fixture = make_fixture_dir()
    require("lazy").load({ plugins = { "mini.files" } })
  end)

  after_each(function()
    pcall(close_explorer)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    if fixture then
      vim.fn.delete(fixture, "rf")
    end
    nvim_env.teardown(root)
  end)

  describe("<leader>E (cwd)", function()
    it("opens floating explorer rooted at cwd", function()
      vim.fn.chdir(fixture)

      press("<Space>E")
      wait.wait_for_buffer({ filetype = "minifiles", timeout = 3000 })

      assert.is_true(is_minifiles_open())

      local bufs = minifiles_buffers()
      assert.is_true(#bufs >= 1, "expected at least one minifiles buffer")

      local lines = vim.api.nvim_buf_get_lines(bufs[1], 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("top.txt", 1, true), "expected top.txt in listing: " .. joined)
      assert.is_truthy(
        joined:find("sub", 1, true),
        "expected sub/ directory in listing: " .. joined
      )

      local state = require("mini.files").get_explorer_state()
      assert.is_not_nil(state)
      local first_win = state.windows[1]
      assert.is_not_nil(first_win, "expected at least one explorer window")
      local win_config = vim.api.nvim_win_get_config(first_win.win_id)
      assert.are.equal(
        "editor",
        win_config.relative,
        "explorer window should be a floating editor window"
      )
    end)
  end)

  describe("<leader>e (current file)", function()
    it("opens explorer at the current buffer's directory", function()
      local file = fixture .. "/sub/nested.txt"
      vim.cmd("edit " .. vim.fn.fnameescape(file))

      press("<Space>e")
      wait.wait_for_buffer({ filetype = "minifiles", timeout = 3000 })

      assert.is_true(is_minifiles_open())

      local bufs = minifiles_buffers()
      local lines = vim.api.nvim_buf_get_lines(bufs[1], 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.is_truthy(
        joined:find("nested.txt", 1, true),
        "expected nested.txt in listing for current-file open: " .. joined
      )
    end)
  end)

  describe("q mapping", function()
    it("closes the explorer", function()
      vim.fn.chdir(fixture)

      press("<Space>E")
      wait.wait_for_buffer({ filetype = "minifiles", timeout = 3000 })
      assert.is_true(is_minifiles_open())

      press("q")
      wait.wait_for(function()
        return not is_minifiles_open()
      end, 2000, "explorer did not close after pressing q")

      assert.is_false(is_minifiles_open())
    end)
  end)
end)
