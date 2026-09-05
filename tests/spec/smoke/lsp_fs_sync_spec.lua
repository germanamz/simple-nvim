local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: lsp fs sync", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  it("the nvim-lsp-file-operations plugin is gone", function()
    -- Replaced by config.lsp_fs_sync (docs/lsp-fs-sync.md): the plugin used
    -- deprecated APIs, blocked the UI up to 10s per client, and never covered
    -- gopls. Guard against it sneaking back in.
    assert.is_nil(require("lazy.core.config").plugins["nvim-lsp-file-operations"])
  end)

  it("loading nvim-tree wires the tree's fs events through to the LSP", function()
    assert.is_nil(package.loaded["config.lsp_fs_sync"])
    require("lazy").load({ plugins = { "nvim-tree.lua" } })

    -- Prove the subscription end-to-end, not just that the module was
    -- required: fire the real nvim-tree event dispatcher and assert a fake
    -- client hears the didChangeWatchedFiles delete.
    local recorded = {}
    local fake = {
      id = 1,
      root_dir = "/",
      server_capabilities = {},
      notify = function(_, method, params)
        table.insert(recorded, { method = method, params = params })
        return true
      end,
    }
    local orig_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(filter)
      if filter and filter.bufnr then
        return {}
      end
      return { fake }
    end

    local ok, err = pcall(function()
      require("nvim-tree.events")._dispatch_file_removed("/ws/server/gone.go")
    end)

    vim.lsp.get_clients = orig_get_clients
    assert.is_true(ok, "event dispatch errored: " .. tostring(err))
    assert.are.equal(1, #recorded)
    assert.are.equal("workspace/didChangeWatchedFiles", recorded[1].method)
    assert.are.same(
      { changes = { { uri = vim.uri_from_fname("/ws/server/gone.go"), type = 3 } } },
      recorded[1].params
    )
  end)

  describe("LSP capabilities", function()
    -- The LSP stack is deferred to BufReadPre/BufNewFile; loading
    -- mason-lspconfig stands in for opening the first real file.
    before_each(function()
      require("lazy").load({ plugins = { "mason-lspconfig.nvim" } })
    end)

    -- willRename is what makes ts_ls react to an nvim-tree rename (rewrite
    -- imports, drop the stale path). The module only advertises operations it
    -- actually sends — the old plugin's blanket willCreate/willDelete must be
    -- gone, so servers don't wait on requests that will never come.
    for _, server in ipairs({ "lua_ls", "ts_ls", "pyright", "gopls" }) do
      it("advertises exactly the supported file operations to " .. server, function()
        local caps = vim.lsp.config[server]
          and vim.lsp.config[server].capabilities
          and vim.lsp.config[server].capabilities.workspace
          and vim.lsp.config[server].capabilities.workspace.fileOperations
        assert.is_not_nil(caps, "file-operations capabilities not merged into " .. server)
        assert.is_true(caps.willRename)
        assert.is_true(caps.didRename)
        assert.is_true(caps.didCreate)
        assert.is_nil(caps.willCreate)
        assert.is_nil(caps.willDelete)
        assert.is_nil(caps.didDelete)
      end)
    end
  end)

  describe("<leader>lr restart keymap", function()
    local function buf_keymap_by_desc(buf, desc)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.desc == desc then
          return m
        end
      end
      return nil
    end

    -- The keymap is buffer-local, set from the LspAttach autocmd. Fire that
    -- autocmd with a stubbed client so the callback runs with no real server.
    local function attach(buf)
      local orig = vim.lsp.get_client_by_id
      vim.lsp.get_client_by_id = function(_)
        return { name = "lua_ls" }
      end
      vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 1 } })
      vim.lsp.get_client_by_id = orig
    end

    it("is registered on LspAttach", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      attach(buf)
      local m = buf_keymap_by_desc(buf, "Restart LSP on buffer")
      assert.is_not_nil(m, "<leader>lr not registered on LspAttach")
      assert.is_function(m.callback)
    end)

    -- Re-attach must go through the FileType autocmd `vim.lsp.enable()` installs,
    -- never through `:edit`. Reloading the buffer was the original mechanism and
    -- it threw E37 on any buffer with unsaved changes — with the clients already
    -- stopped, which left the buffer with no server at all. The e2e-lsp lane
    -- proves that end to end against a real server; this pins the wiring.
    it("stops the buffer's clients and re-attaches without reloading the buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      attach(buf)
      local m = buf_keymap_by_desc(buf, "Restart LSP on buffer")
      assert.is_not_nil(m, "<leader>lr not registered on LspAttach")

      local stopped, edited, fired, checked = 0, false, 0, 0
      local fake_client = {
        attached_buffers = { [buf] = true },
        is_stopped = function()
          return false
        end,
        stop = function()
          stopped = stopped + 1
        end,
      }
      local group = vim.api.nvim_create_augroup("lsp_fs_sync_restart_spec", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        buffer = buf,
        callback = function()
          fired = fired + 1
        end,
      })

      local orig_get_clients, orig_cmd, orig_notify = vim.lsp.get_clients, vim.cmd, vim.notify
      vim.lsp.get_clients = function(opts)
        assert.are.equal(buf, opts.bufnr)
        return { fake_client }
      end
      vim.cmd = function(c)
        if c == "edit" then
          edited = true
        else
          if type(c) == "string" and c:match("^checktime%s") then
            checked = checked + 1
          end
          orig_cmd(c)
        end
      end
      vim.notify = function() end

      local ok, err = pcall(m.callback)

      vim.lsp.get_clients, vim.cmd, vim.notify = orig_get_clients, orig_cmd, orig_notify
      vim.api.nvim_del_augroup_by_id(group)

      assert.is_true(ok, "restart keymap errored: " .. tostring(err))
      assert.are.equal(1, stopped)
      assert.are.equal(1, fired, "the buffer was not re-attached via FileType")
      assert.is_false(edited, "<leader>lr reloaded the buffer; that is the E37 bug")
      -- `:edit` stays gone, but the buffer still has to re-read from disk or the
      -- restarted server gets the same stale text back. `:checktime {buf}` is
      -- the form that does it without E37 and without needing a window.
      assert.is_true(checked >= 1, "<leader>lr did not re-stat the buffer before re-attaching")
    end)
  end)
end)
