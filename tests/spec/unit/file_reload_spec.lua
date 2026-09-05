-- config.file_reload is the missing half of 'autoread': the option is on by
-- Neovim default, but it only executes when a timestamp CHECK runs, and Neovim
-- runs one on its own in three situations only (real terminal focus-gain,
-- entering a buffer that is in a window, and the sweep after a `:!cmd`). This
-- config shells out exclusively through vim.system/systemlist, so the third
-- never fires -- which left every indicator computed from buffer text (gitsigns
-- hunks, LSP diagnostics, lint) reporting on a file the editor had not re-read.
--
-- The load-bearing detail these specs pin is that a BARE `:checktime` is not
-- enough: it visits only buffers that are in a window, despite doc/editing.txt
-- claiming "each loaded buffer is checked". The per-bufnr form is the one that
-- reaches a hidden buffer, and hidden buffers are exactly the ones an agent
-- rewriting eight files at once leaves stale.
local nvim_env = require("helpers.nvim_env")
local wait = require("helpers.wait")

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end

-- A loaded, named, unmodified file buffer that is NOT displayed in any window.
local function hidden_buf(path, content)
  write_file(path, content)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

describe("config.file_reload", function()
  local env_root, M, tmpdir

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    tmpdir = vim.fn.tempname() .. "-file-reload"
    vim.fn.mkdir(tmpdir, "p")
    -- The minimal harness does not load init.lua, so <leader> would default to
    -- "\\" and the keymap assertion below would pin the wrong key.
    vim.g.mapleader = " "
    package.loaded["config.file_reload"] = nil
    M = require("config.file_reload")
    M._reset()
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "file_reload")
    pcall(vim.keymap.del, "n", "<leader>r")
    -- Wipe this spec's file buffers before deleting their files: a sweep in the
    -- NEXT test would otherwise find them pointing at a now-missing path and
    -- report a deletion, which is correct behaviour but not what that test is
    -- measuring.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find(tmpdir, 1, true) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true, unload = false })
      end
    end
    vim.fn.delete(tmpdir, "rf")
    nvim_env.teardown(env_root)
  end)

  describe("sweep", function()
    it("reloads a hidden buffer whose file changed, which a bare :checktime cannot", function()
      local path = tmpdir .. "/hidden.txt"
      local buf = hidden_buf(path, "before\n")
      assert.are.equal("before", lines(buf))

      write_file(path, "after\n")

      -- The control: the bare form is what a naive `au FocusGained * checktime`
      -- would run, and it leaves this buffer stale.
      vim.cmd("checktime")
      assert.are.equal("before", lines(buf))

      M.sweep({ force = true })
      assert.are.equal("after", lines(buf))
    end)

    it("leaves a buffer with unsaved edits alone and reports the conflict", function()
      M.setup()
      local path = tmpdir .. "/conflict.txt"
      local buf = hidden_buf(path, "disk v1\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my unsaved edit" })
      assert.is_true(vim.bo[buf].modified)

      write_file(path, "disk v2\n")

      local warned = {}
      local notify = vim.notify
      vim.notify = function(msg)
        warned[#warned + 1] = msg
      end
      local ok = pcall(M.sweep, { force = true })
      vim.notify = notify

      assert.is_true(ok, "sweep errored on a modified buffer")
      -- The edit survives: a refresh must never discard unsaved work.
      assert.are.equal("my unsaved edit", lines(buf))
      assert.is_true(vim.bo[buf].modified)
      local conflicts = vim.tbl_filter(function(msg)
        return msg:find("conflict.txt", 1, true) ~= nil
      end, warned)
      assert.are.equal(1, #conflicts, "expected exactly one conflict notification")
      assert.is_truthy(conflicts[1]:find("unsaved edits", 1, true))
    end)

    it("skips buffers that have no file behind them", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.bo[scratch].buftype = "nofile"
      local named = vim.api.nvim_create_buf(true, false)

      local checked = {}
      local swept = M.sweep({ force = true, _record = checked })

      assert.is_falsy(vim.tbl_contains(checked, scratch), "swept a buftype=nofile buffer")
      assert.is_falsy(vim.tbl_contains(checked, named), "swept a buffer with no name")
      assert.is_true(swept >= 0)
    end)

    it("throttles unforced sweeps so an idle CursorHold cannot storm", function()
      local path = tmpdir .. "/throttle.txt"
      local buf = hidden_buf(path, "one\n")

      assert.is_true(M.sweep() > 0, "the first unforced sweep should run")

      write_file(path, "two\n")
      assert.are.equal(0, M.sweep(), "a second sweep inside the window should be skipped")
      assert.are.equal("one", lines(buf))

      -- force is the <leader>r hatch: it ignores the window entirely.
      M.sweep({ force = true })
      assert.are.equal("two", lines(buf))
    end)

    it("does not reload while the editor is in insert mode", function()
      local path = tmpdir .. "/insert.txt"
      local buf = hidden_buf(path, "one\n")
      write_file(path, "two\n")

      local mode = vim.api.nvim_get_mode
      vim.api.nvim_get_mode = function()
        return { mode = "i", blocking = false }
      end
      local swept = M.sweep({ force = true })
      vim.api.nvim_get_mode = mode

      assert.are.equal(0, swept, "swept during insert mode")
      assert.are.equal("one", lines(buf))
    end)
  end)

  describe("setup", function()
    it("registers the three sweep edges plus the conflict handler", function()
      M.setup()
      for _, event in ipairs({ "FocusGained", "BufEnter", "CursorHold" }) do
        local found = vim.api.nvim_get_autocmds({ group = "file_reload", event = event })
        assert.is_true(#found >= 1, "no autocmd registered for " .. event)
      end
      -- Owning FileChangedShell is what replaces Neovim's BLOCKING W11/W12
      -- prompt with a notification -- without it a CursorHold sweep would stop
      -- the editor dead any time a file with unsaved edits changed on disk.
      local fcs = vim.api.nvim_get_autocmds({ group = "file_reload", event = "FileChangedShell" })
      assert.is_true(#fcs >= 1, "no FileChangedShell handler; the sweep would prompt")
    end)

    it("republishes a reload as User FileReloaded so consumers get one edge", function()
      M.setup()
      local seen = {}
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "FileReloaded",
        callback = function(args)
          seen[#seen + 1] = args.data and args.data.buf
        end,
      })

      local path = tmpdir .. "/edge.txt"
      local buf = hidden_buf(path, "one\n")
      write_file(path, "two\n")
      M.sweep({ force = true })

      -- Deferred by one tick, not fired inline: `:checktime` reloads as an Ex
      -- command, and a consumer that throws inside that try context unwinds the
      -- whole User chain, skipping every consumer registered after it.
      assert.are.same({}, seen, "FileReloaded fired inline, inside the :checktime try context")
      wait.wait_for(function()
        return vim.tbl_contains(seen, buf)
      end, 1000, "no User FileReloaded for the reloaded buffer")

      pcall(vim.api.nvim_del_autocmd, id)
    end)

    it("keeps running consumers after one of them throws", function()
      M.setup()
      local ran, ids = {}, {}
      for _, name in ipairs({ "first", "boom", "last" }) do
        ids[#ids + 1] = vim.api.nvim_create_autocmd("User", {
          pattern = "FileReloaded",
          callback = function()
            ran[#ran + 1] = name
            if name == "boom" then
              error("consumer blew up")
            end
          end,
        })
      end

      local path = tmpdir .. "/fanout.txt"
      hidden_buf(path, "one\n")
      write_file(path, "two\n")
      M.sweep({ force = true })

      wait.wait_for(function()
        return vim.tbl_contains(ran, "last")
      end, 1000, "a throwing consumer stopped the ones registered after it")
      assert.are.same({ "first", "boom", "last" }, ran)

      for _, id in ipairs(ids) do
        pcall(vim.api.nvim_del_autocmd, id)
      end
    end)

    it("maps <leader>r to the forced refresh", function()
      M.setup()
      local map
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.lhs == " r" then
          map = m
        end
      end
      assert.is_truthy(map, "<leader>r is not mapped")
      assert.is_truthy(map.desc)
    end)
  end)

  describe("refresh", function()
    it("forces a sweep even inside the throttle window", function()
      local path = tmpdir .. "/forced.txt"
      local buf = hidden_buf(path, "one\n")
      M.sweep() -- arms the throttle
      write_file(path, "two\n")

      M.refresh()
      assert.are.equal("two", lines(buf))
    end)
  end)
end)
