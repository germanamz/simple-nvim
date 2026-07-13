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
        -- no_ignore lifts .gitignore so dist/, build/, *.log etc. surface, but
        -- the global file_ignore_patterns (node_modules/.git/.DS_Store) still
        -- apply — those are deliberate noise excludes, not gitignore.
        desc = "Find files (incl. gitignored, except node_modules/.git)",
      },
      {
        "<leader>fg",
        function()
          require("telescope.builtin").live_grep({ cwd = grep_root() })
        end,
        desc = "Live grep (project root)",
      },
      {
        "<leader>fb",
        function()
          -- Buffers picker with a flags legend (what the +/%/#/a/h indicator
          -- column means) floated under the results window.
          require("config.buffers_legend").open()
        end,
        desc = "Buffers",
      },
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
      { "<leader>fR", "<cmd>Telescope resume<cr>", desc = "Resume last picker" },
      {
        "<leader>fS",
        function()
          require("telescope.builtin").lsp_dynamic_workspace_symbols()
        end,
        desc = "Workspace symbols (LSP)",
      },
      {
        "<leader>fo",
        function()
          require("telescope.builtin").lsp_document_symbols()
        end,
        desc = "Document symbols (LSP)",
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
          -- buf_root, not root(): set the base for the submodule the focused
          -- buffer lives in, so it matches where gitsigns/diffview later read it.
          rb.pick(require("util.git").buf_root(0), function(ref)
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
          -- Clear the base for the focused buffer's submodule (start dir), not
          -- the cwd repo's — mirrors <leader>gB's buf_root scoping.
          require("config.review_base").clear_active(require("util.path").buf_start_dir(0))
        end,
        desc = "Review base: clear",
      },
      { "<leader>gc", "<cmd>Telescope git_commits<cr>", desc = "Git commits" },
      { "<leader>gC", "<cmd>Telescope git_bcommits<cr>", desc = "Git commits (current file)" },
      { "<leader>gt", "<cmd>Telescope git_status<cr>", desc = "Git status (telescope)" },
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
      -- Opening a file from a picker dismisses nvim-tree first, so the file
      -- lands in a full window instead of the 35-col sidebar (and the tree acts
      -- as an on-demand browser, matching quit_on_open for files opened from the
      -- tree itself). The tree stays put while the picker is up; cancelling
      -- leaves it untouched. Telescope captured its target window before the tree
      -- closed, so that stale handle is ignored and the file fills the window the
      -- close leaves behind.
      local function opening(action)
        return function(prompt_bufnr)
          -- This wrapper is installed on the default select mappings, so it also
          -- fires for non-file pickers (help_tags, commands, keymaps). Only drop
          -- the tree when the selection is an actual file/path — otherwise picking
          -- a help tag or command would needlessly close the sidebar.
          local entry = require("telescope.actions.state").get_selected_entry()
          if entry and (entry.path or entry.filename) then
            local ok, nvt = pcall(require, "nvim-tree.api")
            if ok and nvt.tree.is_visible() then
              nvt.tree.close()
            end
          end
          return action(prompt_bufnr)
        end
      end
      return {
        defaults = {
          -- Open pickers in normal mode so h/j/k/l navigate immediately;
          -- press i/a to start typing a query.
          initial_mode = "normal",
          prompt_prefix = "  ",
          selection_caret = "▶ ",
          entry_prefix = "  ",
          -- Filename first (dir dimmed after it) so files are easy to scan in
          -- deep trees; truncate would bury the name behind a long path prefix.
          path_display = { "filename_first" },
          -- Show the previewed entry's filename in the preview window title.
          dynamic_preview_title = true,
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
              ["<CR>"] = opening(actions.select_default),
              ["<C-x>"] = opening(actions.select_horizontal),
              ["<C-v>"] = opening(actions.select_vertical),
              ["<C-t>"] = opening(actions.select_tab),
            },
            n = {
              ["<CR>"] = opening(actions.select_default),
              ["<C-x>"] = opening(actions.select_horizontal),
              ["<C-v>"] = opening(actions.select_vertical),
              ["<C-t>"] = opening(actions.select_tab),
            },
          },
        },
        pickers = {
          -- `--glob !.git` prunes the WALK so the picker never descends into a
          -- repo's (or, in a superproject, every submodule's) .git object store
          -- — tens of thousands of pack/loose-object paths. file_ignore_patterns
          -- only filters the *display* after the walk, so excluding .git here is
          -- what actually saves the traversal. find_command is a function so it
          -- returns a FRESH table each open: telescope mutates the command in
          -- place to append --hidden / --no-ignore from opts (keeping <leader>fi's
          -- gitignored-file listing), and a shared table would accumulate them.
          find_files = {
            hidden = true,
            -- Body lives in util.fs (shared with telescope_smart's list_all).
            -- Still a function so it returns a FRESH table each open per the note
            -- above. color_never is this picker's dialect of the shared command —
            -- telescope appends --hidden itself (find_files.hidden, just above).
            find_command = function()
              return require("util.fs").list_files_cmd({ color_never = true })
            end,
          },
          live_grep = {
            additional_args = function()
              return { "--hidden", "--glob", "!.git" }
            end,
          },
          -- Match live_grep: search hidden files (.env, .github/workflows) so the
          -- two grep verbs don't return different match sets for the same query.
          grep_string = {
            additional_args = function()
              return { "--hidden", "--glob", "!.git" }
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
