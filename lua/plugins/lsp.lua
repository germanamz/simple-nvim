-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
-- Servers are registered and enabled in a later step; this file currently only
-- bootstraps Mason so `:Mason` opens the installer UI.
return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
}
