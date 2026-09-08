local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- Regression net for `<leader>lR` (lua/config/options.lua -> config.lsp_picker
-- .restart_all), against a REAL server.
--
-- The gap it pins
-- --------------
-- `<leader>lr` restarts the clients attached to the CURRENT buffer, and every
-- other lever here walks `attached_buffers` too: the picker restarts a client
-- you can see, and `<leader>lk` only stops. So a buffer whose server died has
-- nothing left to walk back from -- get_clients returns an empty list, the
-- restart reports "no LSP clients on this buffer", and reopening the file was
-- the only way to get a server again.
--
-- Why the slow lane: only a real server proves a client actually comes BACK.
-- The unit specs drive stub clients, which can show that FileType was re-fired
-- but never that anything attached to it. Self-skips without a server on PATH,
-- like the rest of `make test-lsp`.
describe("e2e-lsp: <leader>lR", function()
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
  it("brings a server back to a buffer whose client died, which <leader>lr cannot", function()
    if vim.fn.executable("lua-language-server") ~= 1 then
      pending("lua-language-server not on PATH (mason server not installed)")
      return
    end

    local canonical = vim.uv.fs_realpath(root) or root
    local path = canonical .. "/a.lua"
    local fd = assert(io.open(path, "w"))
    fd:write("local a = 1\nreturn a\n")
    fd:close()
    vim.fn.chdir(canonical)

    --- A client that is attached and not on its way out.
    local function live(bufnr)
      return vim.tbl_filter(function(c)
        return not c:is_stopped()
      end, vim.lsp.get_clients({ bufnr = bufnr, name = "lua_ls" }))
    end

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    if not vim.wait(20000, function()
      return #live(buf) > 0
    end, 50) then
      pending("lua_ls did not attach within timeout; treating as unavailable")
      return
    end
    local before_id = live(buf)[1].id

    -- The server dies underneath the buffer. Nothing re-attaches on its own:
    -- vim.lsp.enable's hook is a FileType autocmd, and the filetype was already
    -- set once, when the file was opened.
    live(buf)[1]:stop()
    assert.is_true(
      vim.wait(20000, function()
        return #live(buf) == 0
      end, 50),
      "the client never went away, so the test never reached the state it pins"
    )

    local leader = vim.g.mapleader or "\\"

    -- The control. `<leader>lr` survives the detach as a buffer-local map, but
    -- it has nothing to restart: this is the dead end the new key exists for.
    local lr = keymap_probe.resolve("n", leader .. "lr")
    if lr and lr.callback then
      local quiet = vim.notify
      vim.notify = function() end
      pcall(lr.callback)
      vim.notify = quiet
      assert.are.equal(0, #live(buf), "<leader>lr recovered a dead client on its own")
    end

    local lR = keymap_probe.resolve("n", leader .. "lR")
    assert.is_not_nil(lR, "no <leader>lR keymap")
    assert.is_not_nil(lR.callback, "<leader>lR has no callback")
    -- Global, not buffer-local: the buffer that most needs this is one with no
    -- LspAttach to have hung a buffer-local map off in the first place.
    assert.is_nil(lR.buffer, "<leader>lR should be global, not buffer-local")

    local quiet = vim.notify
    vim.notify = function() end
    local ok, err = pcall(lR.callback)
    vim.notify = quiet
    assert.is_true(ok, "<leader>lR errored: " .. tostring(err))

    assert.is_true(
      vim.wait(20000, function()
        return #live(buf) > 0
      end, 50),
      "<leader>lR left the buffer without a server"
    )
    assert.is_not.equal(before_id, live(buf)[1].id, "re-attached the same dead client")
  end)
end)
