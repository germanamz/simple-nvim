-- Claude Code IDE integration WITHOUT an embedded nvim terminal. claudecode.nvim
-- runs a WebSocket server inside nvim and writes a lock file to
-- ~/.claude/ide/<port>.lock; Claude — running in any SEPARATE terminal — finds
-- it via `/ide` and connects over that socket. That socket, not the terminal, is
-- what carries the live buffer/selection context, @-mentions and the native
-- diff-accept flow, so we keep all of it while running Claude in our own terminal
-- instead of a `:terminal` split. `provider = "none"` disables the built-in
-- terminal entirely.
--
-- Loaded on VeryLazy (not lazily on the keymap) so auto_start brings the server
-- up at startup and the lock file exists BEFORE you launch Claude elsewhere. Once
-- `claude` is running in the other terminal, run `/ide` there once to link them.
return {
  "coder/claudecode.nvim",
  event = "VeryLazy",
  opts = {
    auto_start = true,
    terminal = { provider = "none" },
  },
  keys = {
    { "<leader>as", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude connection status" },
  },
}
