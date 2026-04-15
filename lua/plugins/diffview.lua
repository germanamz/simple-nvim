return {
  "sindrets/diffview.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  cmd = {
    "DiffviewOpen",
    "DiffviewClose",
    "DiffviewToggleFiles",
    "DiffviewFocusFiles",
    "DiffviewRefresh",
    "DiffviewFileHistory",
  },
  keys = {
    { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: open working tree vs index" },
    { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
    { "<leader>gh", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: repo file history" },
    { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: current file history" },
    { "<leader>gm", "<cmd>DiffviewOpen origin/main...HEAD<cr>", desc = "Diffview: branch vs origin/main" },
    { "<leader>gt", "<cmd>DiffviewToggleFiles<cr>", desc = "Diffview: toggle file panel" },
  },
  opts = function()
    local actions = require("diffview.actions")
    return {
      enhanced_diff_hl = true,
      view = {
        merge_tool = {
          layout = "diff3_mixed",
          disable_diagnostics = true,
        },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { position = "left", width = 35 },
      },
      keymaps = {
        view = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
          { "n", "<tab>", actions.select_next_entry, { desc = "Next file" } },
          { "n", "<s-tab>", actions.select_prev_entry, { desc = "Prev file" } },
        },
        file_panel = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
          { "n", "<cr>", actions.select_entry, { desc = "Open file" } },
          { "n", "j", actions.next_entry, { desc = "Next entry" } },
          { "n", "k", actions.prev_entry, { desc = "Prev entry" } },
        },
        file_history_panel = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
        },
      },
    }
  end,
}
