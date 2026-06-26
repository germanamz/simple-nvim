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
    -- Don't attach on very large files: mode="cursor" reparses a range and runs
    -- the context query on every CursorMoved (throttled ~150ms), which stutters
    -- on big generated / deeply-nested files (deep JSON, generated structs).
    -- should_attach stores this per-buffer, so only large buffers skip; normal
    -- files are unaffected and <leader>ut still toggles the plugin globally.
    -- Uses the same predicate as the treesitter highlight guard so a single-line
    -- multi-MB asset (which passes a line-only check) doesn't spin up a parser
    -- the main highlighter intentionally skipped.
    on_attach = function(buf)
      return not require("util.largefile").is_large(buf)
    end,
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
