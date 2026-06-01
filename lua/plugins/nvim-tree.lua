-- File-tree explorer with reveal-to-current-file. Launching nvim on a
-- directory (`nvim .`) opens nvim-tree instead of netrw; netrw is still
-- reachable on demand via init.lua's <leader>E (:Explore), which hijack_netrw
-- leaves untouched.
return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = { "NvimTreeToggle", "NvimTreeFindFile", "NvimTreeFindFileToggle" },
  keys = {
    {
      "<leader>e",
      "<cmd>NvimTreeFindFileToggle<cr>",
      desc = "File tree (reveal current file)",
    },
  },
  -- Stay lazy for `nvim file.txt`, but when nvim is launched on a directory
  -- force the plugin to load during startup. setup() must run before the
  -- directory buffer is read so manage_netrw can strip netrw's FileExplorer
  -- autocmds and the hijack BufEnter handler is in place to win the race.
  init = function()
    if vim.fn.argc() >= 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
      require("lazy").load({ plugins = { "nvim-tree.lua" } })
    end
  end,
  opts = {
    -- Take over directory buffers (so `nvim .` shows the tree) while leaving
    -- netrw's :Explore command alone for the <leader>E fallback.
    disable_netrw = false,
    hijack_netrw = true,
    -- Expand the tree to highlight whatever buffer is focused.
    update_focused_file = { enable = true },
    view = { width = 35 },
    -- Treat the tree as an on-demand picker: close it once a file is opened so
    -- it's only visible when you're actively browsing, not all the time.
    actions = { open_file = { quit_on_open = true } },
    filters = {
      dotfiles = false, -- show dotfiles (toggle with H)
      git_ignored = true, -- hide gitignored, e.g. node_modules (toggle with I)
    },
  },
  config = function(_, opts)
    require("nvim-tree").setup(opts)
    -- Subscribe to nvim-tree's rename/move/delete events and forward them to
    -- the LSP (workspace/willRenameFiles). Deferred to here — not the plugin's
    -- own config — so it only runs once nvim-tree is loaded, keeping nvim-tree
    -- lazy. The matching capabilities are advertised at startup in lsp.lua.
    require("lsp-file-operations").setup()
    -- Pin a one-line hint to the top of the tree window. nvim-tree sets the
    -- buffer's filetype in a scratch window before moving it to the side
    -- window, so a FileType hook targets the wrong window — use TreeOpen,
    -- which fires once the real window exists.
    local api = require("nvim-tree.api")
    api.events.subscribe(api.events.Event.TreeOpen, function()
      local win = require("nvim-tree.view").get_winnr()
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_option_value("winbar", "%#Comment#  g? — all mappings%*", { win = win })
      end
    end)
    -- Close the tree the moment any Telescope picker opens. Combined with
    -- quit_on_open (files opened from the tree), these are the only two events
    -- that dismiss the tree — it otherwise stays put until toggled.
    vim.api.nvim_create_autocmd("User", {
      pattern = "TelescopeFindPre",
      callback = function()
        if api.tree.is_visible() then
          api.tree.close()
        end
      end,
    })
  end,
}
