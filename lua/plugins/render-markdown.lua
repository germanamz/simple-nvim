-- In-buffer markdown rendering: headings, code blocks, lists, tables.
-- file_types must include `mdx` so it triggers on .mdx buffers.
return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    ft = { "markdown", "mdx" },
    opts = {
      file_types = { "markdown", "mdx" },
    },
  },
}
