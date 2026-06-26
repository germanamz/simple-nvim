return {
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "modern",
      delay = 300,
      spec = {
        { "<leader>b", group = "buffer" },
        { "<leader>f", group = "find" },
        { "<leader>g", group = "git" },
        { "<leader>h", group = "hunks" },
        { "<leader>k", group = "keys" },
        { "<leader>l", group = "lsp" },
        { "<leader>m", group = "markdown" },
        { "<leader>q", group = "quit" },
        { "<leader>u", group = "toggle" },
        -- Neovim 0.11 ships the default `gr*` LSP keymaps without a `desc`, so
        -- which-key falls back to the raw Lua function. Relabel them here (this
        -- only changes the displayed text, not the mappings themselves).
        { "gr", group = "lsp" },
        { "gra", desc = "Code action" },
        { "grn", desc = "Rename" },
        { "grr", desc = "References" },
        { "gri", desc = "Implementation" },
        { "grt", desc = "Type definition" },
        { "gO", desc = "Document symbols" },
      },
    },
    keys = {
      {
        "<leader>K",
        function()
          require("which-key").show({ global = true })
        end,
        desc = "All keymaps (which-key)",
      },
    },
  },
}
