-- Treesitter-driven HTML/JSX tag editing:
--   • typing the ">" that closes a start tag inserts the matching "</tag>"
--   • renaming one half of a tag pair renames the other on InsertLeave
-- Tag awareness comes from the buffer's treesitter tree, so every filetype
-- below needs a running parser (wired in lua/plugins/treesitter.lua).
--
-- html and js/ts(react) are supported by the plugin out of the box. Go html
-- templates are detected as `gohtmltmpl` (init.lua), parsed by the html parser
-- (treesitter.lua), and aliased to html here so they get the same behaviour.
return {
  "windwp/nvim-ts-autotag",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  ft = {
    "html",
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
    "gohtmltmpl",
  },
  opts = {
    opts = {
      enable_close = true,
      enable_rename = true,
      enable_close_on_slash = false,
    },
    aliases = {
      gohtmltmpl = "html",
    },
  },
}
