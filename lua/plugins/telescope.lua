-- Grep pickers search from the repo toplevel (cwd when outside a repo) so
-- results always cover the whole project, even if the cwd has drifted from
-- where nvim was launched.
local function grep_root()
  return require("util.git").root() or vim.fn.getcwd()
end

return {
  {
    "nvim-telescope/telescope.nvim",
    branch = "master",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function()
          return vim.fn.executable("make") == 1
        end,
      },
    },
    cmd = "Telescope",
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Find files" },
      {
        "<leader>fi",
        "<cmd>Telescope find_files no_ignore=true hidden=true<cr>",
        desc = "Find files (incl. gitignored)",
      },
      {
        "<leader>fg",
        function()
          require("telescope.builtin").live_grep({ cwd = grep_root() })
        end,
        desc = "Live grep (project root)",
      },
      { "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
      { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help tags" },
      { "<leader>fr", "<cmd>Telescope oldfiles cwd_only=true<cr>", desc = "Recent files (cwd)" },
      {
        "<leader>fs",
        function()
          require("telescope.builtin").grep_string({ cwd = grep_root() })
        end,
        desc = "Grep word under cursor (project root)",
      },
      { "<leader>fd", "<cmd>Telescope diagnostics<cr>", desc = "Diagnostics" },
      { "<leader>?", "<cmd>Telescope keymaps<cr>", desc = "Keymaps" },
      { "<leader>fc", "<cmd>Telescope commands<cr>", desc = "Commands" },
      {
        "<leader>f/",
        "<cmd>Telescope current_buffer_fuzzy_find<cr>",
        desc = "Fuzzy find in buffer",
      },
      {
        "<leader>gs",
        function()
          require("config.telescope_smart").smart_files_changed()
        end,
        desc = "Changed files (worktree + vs base)",
      },
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
        function()
          require("config.telescope_smart").smart_files()
        end,
        desc = "Files (changed first)",
      },
    },
    opts = function()
      local actions = require("telescope.actions")
      return {
        defaults = {
          -- Open pickers in normal mode so h/j/k/l navigate immediately;
          -- press i/a to start typing a query.
          initial_mode = "normal",
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
              -- Esc drops to normal mode (not close); Esc in normal closes.
              -- <C-c> still closes in one press from insert.
              ["<esc>"] = function()
                vim.cmd("stopinsert")
              end,
            },
          },
        },
        pickers = {
          find_files = { hidden = true },
          live_grep = {
            additional_args = function()
              return { "--hidden" }
            end,
          },
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
      require("config.telescope_smart").setup()
    end,
  },
}
