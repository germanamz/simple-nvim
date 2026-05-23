# Handoff: keymap overlaps surfaced while writing the cheatsheet

All items in this doc have been resolved.

- The `<leader>e` double-meaning was resolved by removing `mini.files`
  and dropping the LSP override.
- The three-way `gd` overlap was resolved by removing `diffview.nvim`
  (which installed the netrw `gd` hijack); only the LSP `gd` and its
  ts_ls source-definition variant remain.
- The `<leader>fk` / `<leader>?` / `<leader>K` / `<leader>fK` cluster
  was resolved by dropping `<leader>fk` (alias of `<leader>?`) and
  moving the cheatsheet from `<leader>fK` to `<leader>k?` so it no
  longer sits case-distinct next to `<leader>K` (which-key).

This file can be deleted when convenient.
