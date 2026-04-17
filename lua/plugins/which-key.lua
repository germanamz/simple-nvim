return {
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "modern",
      delay = 300,
      spec = {
        { "<leader>f", group = "find" },
        { "<leader>g", group = "git" },
      },
    },
    keys = {
      {
        "<leader>K",
        function() require("which-key").show({ global = true }) end,
        desc = "All keymaps (which-key)",
      },
    },
  },
}
