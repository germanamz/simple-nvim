local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: completion (blink.cmp)", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  it("blink.cmp is loaded with no errors", function()
    local plugins = require("lazy.core.config").plugins
    local blink = plugins["blink.cmp"]
    assert.is_not_nil(blink, "blink.cmp spec not registered")
    -- Loaded eagerly because it is a dependency of mason-lspconfig (lazy=false);
    -- capabilities must be known before servers attach on FileType.
    assert.is_not_nil(blink._.loaded, "blink.cmp not loaded at startup")
    assert.is_false(require("lazy.core.plugin").has_errors(blink), "blink.cmp reported load errors")
  end)

  describe("merged config", function()
    local cfg

    before_each(function()
      cfg = require("blink.cmp.config")
    end)

    it("uses lsp, path and buffer sources (no snippets)", function()
      assert.are.same({ "lsp", "path", "buffer" }, cfg.sources.default)
    end)

    it("auto-shows documentation", function()
      assert.is_true(cfg.completion.documentation.auto_show)
    end)

    it("enables signature help", function()
      assert.is_true(cfg.signature.enabled)
    end)

    it("accepts with Enter (preset) and Tab", function()
      assert.are.equal("enter", cfg.keymap.preset)
      assert.are.same({ "accept", "fallback" }, cfg.keymap["<Tab>"])
    end)
  end)

  describe("LSP capabilities", function()
    -- blink advertises snippetSupport=true (Neovim's default is false), so it
    -- doubles as proof that blink's capabilities were merged into each server.
    local function snippet_support(server)
      local c = vim.lsp.config[server]
      return c
        and c.capabilities
        and c.capabilities.textDocument
        and c.capabilities.textDocument.completion
        and c.capabilities.textDocument.completion.completionItem
        and c.capabilities.textDocument.completion.completionItem.snippetSupport
    end

    for _, server in ipairs({ "lua_ls", "ts_ls", "pyright", "gopls" }) do
      it("advertises blink completion capabilities to " .. server, function()
        assert.is_true(
          snippet_support(server) == true,
          "blink capabilities not merged into " .. server
        )
      end)
    end
  end)
end)
