-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
-- mason-lspconfig provides the `ensure_installed` bridge so every server in
-- the list is auto-installed on first start. Servers are registered/enabled
-- in a later step.
local servers = {
  "ts_ls",
  "pyright",
  "gopls",
  "rust_analyzer",
  "lua_ls",
  "bashls",
  "jsonls",
  "yamlls",
  "taplo",
  "html",
  "cssls",
  "marksman",
}

return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = servers,
        automatic_installation = false,
      })
    end,
  },
}
