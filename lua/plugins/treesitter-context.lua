return {
  "nvim-treesitter/nvim-treesitter-context",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    max_lines = 4,
    multiline_threshold = 1,
    trim_scope = "outer",
    mode = "cursor",
    separator = "─",
  },
  keys = {
    {
      "<leader>ut",
      function()
        require("treesitter-context").toggle()
      end,
      desc = "Toggle treesitter context",
    },
    {
      "[f",
      function()
        require("treesitter-context").go_to_context(vim.v.count1)
      end,
      desc = "Jump to enclosing context (function) header",
    },
  },
}
