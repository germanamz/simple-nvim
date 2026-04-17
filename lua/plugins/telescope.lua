return {
  {
    "nvim-telescope/telescope.nvim",
    branch = "master",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function() return vim.fn.executable("make") == 1 end,
      },
    },
    cmd = "Telescope",
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Find files" },
      { "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "Live grep" },
      { "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
      { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help tags" },
      { "<leader>fr", "<cmd>Telescope oldfiles<cr>", desc = "Recent files" },
      { "<leader>fs", "<cmd>Telescope grep_string<cr>", desc = "Grep word under cursor" },
      { "<leader>fd", "<cmd>Telescope diagnostics<cr>", desc = "Diagnostics" },
      { "<leader>fk", "<cmd>Telescope keymaps<cr>", desc = "Keymaps" },
      { "<leader>?", "<cmd>Telescope keymaps<cr>", desc = "Keymaps reference" },
      { "<leader>fc", "<cmd>Telescope commands<cr>", desc = "Commands" },
      { "<leader>f/", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "Fuzzy find in buffer" },
      { "<leader>gs", "<cmd>Telescope git_status<cr>", desc = "Git changed files" },
      {
        "<leader>gB",
        function()
          local rb = require("config.review_base")
          rb.pick(rb.git_root(), function(ref)
            if ref then
              require("config.telescope_smart").smart_files()
            end
          end)
        end,
        desc = "Review base: pick branch (auto-opens files)",
      },
      {
        "<leader>gX",
        function()
          local rb = require("config.review_base")
          local root = rb.git_root()
          if not root then
            vim.notify("Not a git repo", vim.log.levels.WARN)
            return
          end
          rb.clear(root)
          vim.notify("Review base cleared")
        end,
        desc = "Review base: clear",
      },
      {
        "<leader><space>",
        function() require("config.telescope_smart").smart_files() end,
        desc = "Files (changed first)",
      },
    },
    opts = function()
      local actions = require("telescope.actions")
      return {
        defaults = {
          prompt_prefix = "  ",
          selection_caret = "▶ ",
          entry_prefix = "  ",
          path_display = { "truncate" },
          sorting_strategy = "ascending",
          layout_config = {
            horizontal = { prompt_position = "top", preview_width = 0.55 },
            width = 0.87,
            height = 0.80,
          },
          file_ignore_patterns = { "%.git/", "node_modules/", "%.DS_Store" },
          mappings = {
            i = {
              ["<C-j>"] = actions.move_selection_next,
              ["<C-k>"] = actions.move_selection_previous,
              ["<C-n>"] = actions.cycle_history_next,
              ["<C-p>"] = actions.cycle_history_prev,
              ["<esc>"] = actions.close,
            },
          },
        },
        pickers = {
          find_files = { hidden = true },
          live_grep = { additional_args = function() return { "--hidden" } end },
        },
        extensions = {
          fzf = {
            fuzzy = true,
            override_generic_sorter = true,
            override_file_sorter = true,
            case_mode = "smart_case",
          },
        },
      }
    end,
    config = function(_, opts)
      local telescope = require("telescope")
      telescope.setup(opts)
      pcall(telescope.load_extension, "fzf")
    end,
  },
}
