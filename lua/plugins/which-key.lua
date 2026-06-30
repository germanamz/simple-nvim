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
        -- A sibling mini.surround spec hangs its add/delete/replace verbs off a
        -- `gs` prefix; label the group so the chord menu reads "surround".
        { "gs", group = "surround" },
        -- Neovim 0.12's default `gr*` LSP keymaps already carry descs (e.g.
        -- "vim.lsp.buf.rename()"), but those read like raw API calls. Relabel
        -- them here to give friendlier labels than Neovim's default
        -- vim.lsp.buf.* descs (this only changes the displayed text, not the
        -- mappings themselves).
        { "gr", group = "lsp" },
        { "gra", desc = "Code action" },
        { "grn", desc = "Rename" },
        { "grr", desc = "References" },
        { "gri", desc = "Implementation" },
        { "grt", desc = "Type definition" },
        -- 0.12 adds a default `grx` under the `gr` group (run code lens).
        { "grx", desc = "Run codelens" },
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
