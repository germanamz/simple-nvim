local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: completion (blink.cmp)", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  -- The LSP stack (and blink with it, as a dependency of mason-lspconfig) is
  -- deferred to BufReadPre/BufNewFile; a bare headless boot must not load it.
  -- Loading mason-lspconfig stands in for opening the first real file.
  local function load_lsp_stack()
    require("lazy").load({ plugins = { "mason-lspconfig.nvim" } })
  end

  it("blink.cmp is deferred at startup and loads with the LSP stack", function()
    local plugins = require("lazy.core.config").plugins
    local blink = plugins["blink.cmp"]
    assert.is_not_nil(blink, "blink.cmp spec not registered")
    load_lsp_stack()
    assert.is_not_nil(blink._.loaded, "blink.cmp not loaded with the LSP stack")
    assert.is_false(require("lazy.core.plugin").has_errors(blink), "blink.cmp reported load errors")
  end)

  describe("merged config", function()
    local cfg

    before_each(function()
      load_lsp_stack()
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
      -- Tab is AI-first: a leading function entry accepts the minuet inline
      -- suggestion when one is painted (see lua/plugins/minuet.lua), then jumps
      -- to the next snippet tabstop when a session is active (the enter
      -- preset's snippet_forward, which a whole-chain override would otherwise
      -- drop), then falls through to the blink menu "accept" and finally a
      -- literal Tab.
      local tab = cfg.keymap["<Tab>"]
      assert.are.equal("function", type(tab[1]))
      assert.are.same({ "snippet_forward", "accept", "fallback" }, { tab[2], tab[3], tab[4] })
    end)
  end)

  describe("LSP capabilities", function()
    before_each(load_lsp_stack)

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
