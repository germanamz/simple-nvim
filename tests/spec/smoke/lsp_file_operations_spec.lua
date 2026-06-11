local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: lsp file operations", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  it("nvim-lsp-file-operations spec is registered", function()
    local plugins = require("lazy.core.config").plugins
    local spec = plugins["nvim-lsp-file-operations"]
    assert.is_not_nil(spec, "nvim-lsp-file-operations spec not registered")
    assert.is_false(
      require("lazy.core.plugin").has_errors(spec),
      "nvim-lsp-file-operations reported load errors"
    )
  end)

  describe("LSP capabilities", function()
    -- The LSP stack is deferred to BufReadPre/BufNewFile; loading
    -- mason-lspconfig stands in for opening the first real file.
    before_each(function()
      require("lazy").load({ plugins = { "mason-lspconfig.nvim" } })
    end)

    -- willRename is what makes ts_ls react to an nvim-tree rename (rewrite
    -- imports, drop the stale path) instead of leaving the project in the
    -- "Already included file name ... only in casing" state. Advertised from a
    -- static table when the stack loads, so it doesn't require nvim-tree.
    local function will_rename(server)
      local c = vim.lsp.config[server]
      return c
        and c.capabilities
        and c.capabilities.workspace
        and c.capabilities.workspace.fileOperations
        and c.capabilities.workspace.fileOperations.willRename
    end

    for _, server in ipairs({ "lua_ls", "ts_ls", "pyright", "gopls" }) do
      it("advertises file-operation capabilities to " .. server, function()
        assert.is_true(
          will_rename(server) == true,
          "file-operations capabilities not merged into " .. server
        )
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

    it("stops the buffer's clients and reloads on invoke", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      attach(buf)
      local m = buf_keymap_by_desc(buf, "Restart LSP on buffer")
      assert.is_not_nil(m, "<leader>lr not registered on LspAttach")

      local stopped, edited = 0, false
      local fake_client = {
        stop = function()
          stopped = stopped + 1
        end,
      }
      local orig_get_clients, orig_cmd = vim.lsp.get_clients, vim.cmd
      vim.lsp.get_clients = function(opts)
        assert.are.equal(buf, opts.bufnr)
        return { fake_client }
      end
      vim.cmd = function(c)
        if c == "edit" then
          edited = true
        else
          orig_cmd(c)
        end
      end

      local ok, err = pcall(m.callback)

      vim.lsp.get_clients, vim.cmd = orig_get_clients, orig_cmd

      assert.is_true(ok, "restart keymap errored: " .. tostring(err))
      assert.are.equal(1, stopped)
      assert.is_true(edited, "buffer was not reloaded with :edit")
    end)
  end)
end)
