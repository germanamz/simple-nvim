-- Pins config.cmux_terminal: `<leader>tt` / `<leader>tv` / `<leader>th` open a
-- cmux terminal -- a tab in Neovim's own pane, a split to the right, a split
-- below -- already sitting in the directory you were looking at.
--
-- Two things can go wrong, and each describe below pins one: the directory
-- (which folder a buffer or a tree node stands for) and the cmux call (which
-- verb, which direction, which working directory). The specs press the real
-- keymaps, so a swapped v/h or a keymap wired to the wrong resolver fails here
-- too, not only a broken helper.
--
-- The real `cmux` binary is never run -- it would open panes in the developer's
-- live terminal -- so both ends are stubbed: `util.cmux.bin` (the "is this a
-- cmux session" check) and `M._run` (every invocation). `M._run` is called
-- synchronously, unlike the real path's vim.schedule hop, so a spec can assert
-- right after the press.
local term = require("config.cmux_terminal")

-- Which cmux CLI the module believes it has; nil is "not a cmux session".
local cmux_bin = "cmux-stub"
require("util.cmux").bin = function()
  return cmux_bin
end

-- The surface Neovim runs in. Splits are made off it, so it must reach the argv.
local SURFACE = "11111111-2222-3333-4444-555555555555"

describe("config.cmux_terminal", function()
  local calls, exit_code, notified, real_notify, real_surface, root

  --- The callback behind `lhs` in normal mode: the buffer-local one when the
  --- current buffer has it, else the global one -- the one a keypress would run.
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    assert.is_function(m.callback, "no mapping for " .. lhs)
    m.callback()
  end

  --- The one cmux invocation a press made.
  local function only_call()
    assert.are.equal(1, #calls, "expected exactly one cmux call, got " .. #calls)
    return calls[1]
  end

  --- The params of a `cmux rpc surface.split <json>` argv, decoded.
  local function split_params(args)
    assert.are.same({ "rpc", "surface.split" }, { args[1], args[2] })
    assert.are.equal(3, #args)
    return vim.json.decode(args[3])
  end

  before_each(function()
    calls, exit_code, notified = {}, 0, {}
    cmux_bin = "cmux-stub"
    term._reset()
    term._run = function(args, on_done)
      table.insert(calls, args)
      on_done(exit_code, "", exit_code ~= 0 and "Error: boom" or "")
    end
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    real_surface = vim.env.CMUX_SURFACE_ID
    vim.env.CMUX_SURFACE_ID = SURFACE

    -- A real tree on disk: the resolver asks the filesystem what is a file and
    -- what is a folder. Resolved up front because macOS's temp dir sits behind
    -- the /var -> /private/var symlink, and the expectations below are literals
    -- built from this root, not from the code under test.
    root = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/[^/]*$")) .. "/cmux-terminal-spec"
    vim.fn.delete(root, "rf")
    vim.fn.mkdir(root .. "/src/lib", "p")
    vim.fn.writefile({ "x" }, root .. "/src/main.lua")

    term.setup()
  end)

  after_each(function()
    vim.notify = real_notify
    vim.env.CMUX_SURFACE_ID = real_surface
    term._run = nil
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(root, "rf")
  end)

  describe("the cmux call", function()
    before_each(function()
      vim.cmd.edit(vim.fn.fnameescape(root .. "/src/main.lua"))
    end)

    it("<leader>tt opens a focused terminal tab in the buffer's directory", function()
      press("<leader>tt")
      assert.are.same(
        { "new-surface", "--working-directory", root .. "/src", "--focus", "true" },
        only_call()
      )
    end)

    it("<leader>tv splits Neovim's surface to the right", function()
      press("<leader>tv")
      assert.are.same({
        direction = "right",
        surface_id = SURFACE,
        working_directory = root .. "/src",
        focus = true,
      }, split_params(only_call()))
    end)

    it("<leader>th splits Neovim's surface downward", function()
      press("<leader>th")
      assert.are.same({
        direction = "down",
        surface_id = SURFACE,
        working_directory = root .. "/src",
        focus = true,
      }, split_params(only_call()))
    end)

    it("reports a failed cmux call instead of failing silently", function()
      exit_code = 1
      press("<leader>tv")
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.is_truthy(notified[1].msg:find("boom", 1, true), notified[1].msg)
    end)
  end)

  describe("the buffer's directory", function()
    --- The working directory a `<leader>tt` press on the current buffer asks for.
    local function tab_dir()
      press("<leader>tt")
      return only_call()[3]
    end

    it("is the parent folder of a file on disk", function()
      vim.cmd.edit(vim.fn.fnameescape(root .. "/src/main.lua"))
      assert.are.equal(root .. "/src", tab_dir())
    end)

    it("is the nearest existing folder for a file not written yet", function()
      -- `lib/` exists, `new/` does not: cmux cannot start a shell in a folder
      -- that is not there, so the press lands in the deepest one that is.
      vim.cmd.edit(vim.fn.fnameescape(root .. "/src/lib/new/thing.lua"))
      assert.are.equal(root .. "/src/lib", tab_dir())
    end)

    it("falls back to Neovim's cwd for a buffer with no file", function()
      vim.cmd.enew()
      assert.are.equal(vim.fn.getcwd(), tab_dir())
    end)

    it("falls back to Neovim's cwd for a URL-named buffer", function()
      -- fugitive://, oil://, term://: not paths, however path-like they look.
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "fugitive://" .. root .. "/.git//0/src/main.lua")
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal(vim.fn.getcwd(), tab_dir())
    end)

    it("falls back to Neovim's cwd for a special buffer that borrows a path", function()
      -- A scratch/listing buffer named after a real file is still not that file.
      local buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, root .. "/src/main.lua.scratch")
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal("nofile", vim.bo[buf].buftype)
      assert.are.equal(vim.fn.getcwd(), tab_dir())
    end)
  end)

  describe("on the nvim-tree buffer", function()
    local node, tree_buf

    before_each(function()
      -- The node nvim-tree hands back: a field-only clone, so the module must
      -- read absolute_path rather than call node methods.
      node = nil
      package.loaded["nvim-tree.api"] = {
        tree = {
          get_node_under_cursor = function()
            return node
          end,
        },
      }
      tree_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(tree_buf)
      term.set_tree_keymaps(tree_buf)
    end)

    after_each(function()
      package.loaded["nvim-tree.api"] = nil
    end)

    it("opens a folder node in that folder", function()
      node = { name = "lib", type = "directory", absolute_path = root .. "/src/lib" }
      press("<leader>tv")
      assert.are.equal(root .. "/src/lib", split_params(only_call()).working_directory)
    end)

    it("opens a file node in its parent folder", function()
      node = { name = "main.lua", type = "file", absolute_path = root .. "/src/main.lua" }
      press("<leader>th")
      local params = split_params(only_call())
      assert.are.equal("down", params.direction)
      assert.are.equal(root .. "/src", params.working_directory)
    end)

    it("opens a tab from the tree too", function()
      node = { name = "src", type = "directory", absolute_path = root .. "/src" }
      press("<leader>tt")
      assert.are.same(
        { "new-surface", "--working-directory", root .. "/src", "--focus", "true" },
        only_call()
      )
    end)

    it("uses the tree's node, not the buffer's name", function()
      -- The tree buffer is a nofile scratch buffer: were the global map to win,
      -- this would open in Neovim's cwd instead of the node's folder.
      node = { name = "lib", type = "directory", absolute_path = root .. "/src/lib" }
      assert.are_not.equal(root .. "/src/lib", vim.fn.getcwd())
      press("<leader>tt")
      assert.are.equal(root .. "/src/lib", only_call()[3])
    end)

    it("falls back to Neovim's cwd when there is no node", function()
      press("<leader>tt")
      assert.are.equal(vim.fn.getcwd(), only_call()[3])
    end)
  end)

  describe("outside a cmux session", function()
    it("says so once and calls nothing", function()
      -- The maps are global and installed at startup, so a plain terminal gets
      -- one warning, not one per press.
      cmux_bin = nil
      vim.cmd.edit(vim.fn.fnameescape(root .. "/src/main.lua"))
      press("<leader>tt")
      press("<leader>tv")

      assert.are.same({}, calls)
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)
end)
