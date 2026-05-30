-- Bridges file operations (rename/move/delete) from nvim-tree to the LSP via
-- workspace/willRenameFiles. Servers like ts_ls then rewrite import paths in
-- referencing files and drop the old path from their in-memory project.
--
-- Without this, an in-editor rename never reaches the server: it keeps the
-- stale path, and a case-only rename on macOS's case-insensitive filesystem
-- leaves two paths differing only in case → the "Already included file name
-- ... only in casing" error. <leader>lr (lsp.lua) is the manual escape hatch.
--
-- Responsibilities are split so nvim-tree stays lazy:
--   • default_capabilities() is a static table merged into every server in
--     lsp.lua at startup, advertising willRenameFiles from client init.
--   • setup() subscribes to nvim-tree's rename/move events, so it's called
--     from nvim-tree's config — never forcing nvim-tree to load at startup.
return {
  "antosha417/nvim-lsp-file-operations",
  dependencies = { "nvim-lua/plenary.nvim" },
  lazy = true,
}
