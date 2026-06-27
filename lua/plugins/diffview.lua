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
        local rb = require("config.review_base")
        local root = require("util.git").root()
        local base = root and rb.get(root)
        if base then
          -- Three-dot base...HEAD diffs against the merge-base, matching the
          -- smart picker's "changed on my branch since base" semantics.
          vim.cmd("DiffviewOpen " .. base .. "...HEAD")
        else
          vim.cmd("DiffviewOpen")
        end
      end,
      desc = "Diff view (vs review base)",
    },
  },
}
