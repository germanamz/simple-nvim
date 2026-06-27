-- Session save/restore (folke/persistence.nvim). The plugin auto-SAVES the
-- session for the cwd on exit, but restore is deliberately left EXPLICIT — a
-- keymap, never a VimEnter auto-restore. That keeps startup lazy and lands us
-- on the file tree (see lua/plugins/nvim-tree.lua) instead of silently
-- reopening a pile of buffers; you restore only when you ask for it.
return {
  {
    "folke/persistence.nvim",
    -- BufReadPre is the first event that means "a real file is in play", so the
    -- plugin (and its save-on-exit autocmds) only loads once there's a session
    -- worth recording — not on an empty / tree-only launch.
    event = "BufReadPre",
    -- Empty opts → setup() with library defaults (session dir under stdpath).
    opts = {},
    keys = {
      {
        "<leader>ql",
        function()
          require("persistence").load()
        end,
        desc = "Restore session (cwd)",
      },
      {
        "<leader>qL",
        function()
          require("persistence").load({ last = true })
        end,
        desc = "Restore last session",
      },
    },
  },
}
