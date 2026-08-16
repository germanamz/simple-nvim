local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- Regression net for `<leader>lr` (lua/plugins/lsp.lua), against a REAL server.
--
-- The bug it pins
-- --------------
-- The keymap used to stop the buffer's clients and then `:edit` to re-trigger
-- `vim.lsp.enable`'s FileType attach. Both halves of that failed in ordinary use:
--
--   • `:edit` refuses a modified buffer (E37) — and a buffer with unsaved edits
--     is exactly the state you are in when you reach for a restart. The clients
--     were already stopped by then, so the error left the buffer with NO server
--     at all: no completion, no diagnostics, until you reopened the file.
--   • `:edit` only re-attaches the CURRENT buffer, while `stop()` detaches every
--     buffer that client served. Sibling files under the same root went dark and
--     never came back on their own (the wart noted in config.lsp_tsdk's header).
--
-- Why the slow lane: only a real client has real `attached_buffers`, which is
-- what the sibling half turns on. Self-skips without a server on PATH, like the
-- rest of `make test-lsp`.
describe("e2e-lsp: <leader>lr", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "lua_ls" })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  -- One example, one isolated env: a second `setup_isolated_env()` in the same
  -- headless child makes `:edit`ing a .lua file fail on a stale lsp.log path.
  it("restarts from a modified buffer without losing edits or sibling buffers", function()
    if vim.fn.executable("lua-language-server") ~= 1 then
      pending("lua-language-server not on PATH (mason server not installed)")
      return
    end

    local canonical = vim.uv.fs_realpath(root) or root
    local function write(name, body)
      local path = canonical .. "/" .. name
      local fd = assert(io.open(path, "w"))
      fd:write(body)
      fd:close()
      return path
    end
    local a_path = write("a.lua", "local a = 1\nreturn a\n")
    local b_path = write("b.lua", "local b = 2\nreturn b\n")
    vim.fn.chdir(canonical)

    --- A client that is attached and not on its way out.
    local function live(bufnr)
      return vim.tbl_filter(function(c)
        return not c:is_stopped()
      end, vim.lsp.get_clients({ bufnr = bufnr, name = "lua_ls" }))
    end
    local function wait_live(bufnr)
      return vim.wait(20000, function()
        return #live(bufnr) > 0
      end, 50)
    end

    vim.cmd("edit " .. vim.fn.fnameescape(a_path))
    local a_buf = vim.api.nvim_get_current_buf()
    if not wait_live(a_buf) then
      pending("lua_ls did not attach within timeout; treating as unavailable")
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(b_path))
    local b_buf = vim.api.nvim_get_current_buf()
    assert.is_true(wait_live(b_buf), "lua_ls never attached to the sibling buffer")

    -- Both files sit under one root, so one client serves both — the shape that
    -- makes a naive restart strand the buffer you are not standing in.
    local before_id = live(a_buf)[1].id
    assert.are.equal(before_id, live(b_buf)[1].id, "expected one client across both buffers")

    -- Back to a.lua and leave it dirty, the way a real restart is reached for.
    vim.api.nvim_set_current_buf(a_buf)
    vim.api.nvim_buf_set_lines(a_buf, 0, 0, false, { "-- unsaved work" })
    assert.is_true(vim.bo[a_buf].modified, "test setup failed to dirty the buffer")

    local leader = vim.g.mapleader or "\\"
    local m = keymap_probe.resolve("n", leader .. "lr")
    assert.is_not_nil(m, "no <leader>lr keymap on an LSP buffer")
    assert.is_not_nil(m.callback, "<leader>lr has no callback")
    assert.are.equal(a_buf, m.buffer, "<leader>lr should be buffer-local to the LSP buffer")

    local ok, err = pcall(m.callback)
    assert.is_true(ok, "<leader>lr errored on a modified buffer: " .. tostring(err))

    -- The edits survive: a restart must not reload the file out from under you.
    assert.is_true(vim.bo[a_buf].modified, "<leader>lr discarded the unsaved changes")
    assert.are.equal(
      "-- unsaved work",
      vim.api.nvim_buf_get_lines(a_buf, 0, 1, false)[1],
      "<leader>lr reverted the buffer to its on-disk contents"
    )

    -- Both buffers come back, on a genuinely new client.
    assert.is_true(wait_live(a_buf), "no lua_ls on the restarted buffer")
    assert.is_true(wait_live(b_buf), "the sibling buffer was left without a server")
    assert.is_not.equal(before_id, live(a_buf)[1].id, "<leader>lr did not actually restart")
  end)
end)
