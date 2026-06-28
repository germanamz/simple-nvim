-- Whole-changeset review, complementing the per-file gitsigns loop: gitsigns
-- paints hunks (and new-vs-base) one buffer at a time as you edit, while
-- <leader>gv opens the full changed-file list + side-by-side diff in a single
-- view. Driven by the bespoke review-base ref (config.review_base) so "what
-- changed since base" stays consistent across the smart picker, gitsigns and
-- this diff. Falls back to plain DiffviewOpen (working tree vs index) when no
-- base is set or we're outside a repo.
return {
  "sindrets/diffview.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  keys = {
    {
      "<leader>gv",
      function()
        -- Resolve the range from the focused buffer's start dir so a submodule
        -- buffer reviews its OWN repo against its OWN base (config.review_base
        -- owns the three-dot base...HEAD formatting and the per-repo lookup).
        local path = require("util.path")
        local range = require("config.review_base").diff_range(path.buf_start_dir(0))
        if range then
          vim.cmd("DiffviewOpen " .. range)
        else
          vim.cmd("DiffviewOpen")
        end
      end,
      desc = "Diff view (vs review base)",
    },
  },
}
