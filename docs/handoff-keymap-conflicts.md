# Handoff: keymap overlaps surfaced while writing the cheatsheet

Only one item remains. The `<leader>e` double-meaning and the three-way `gd`
overlap were both resolved by removing `mini.files` and `diffview.nvim` — see
the commit that removed those plugin specs.

## `<leader>fk` vs `<leader>fK` vs `<leader>?` vs `<leader>K`

**Where:**

- `lua/plugins/telescope.lua:29` — `<leader>fk` = Telescope keymaps.
- `lua/plugins/telescope.lua:30` — `<leader>?` = Telescope keymaps (alias).
- `lua/plugins/which-key.lua:14` — `<leader>K` = which-key global popup.
- `init.lua:27` — `<leader>fK` = open the cheatsheet.

**Why this matters:** four near-identical keys do three different things.
A future-self looking at the keymap list will likely guess wrong at least
once.

**Things to consider:**

- Drop one of `<leader>fk` / `<leader>?`. They're literal aliases.
- Consider whether `<leader>K` (which-key) and `<leader>fK` (open doc)
  being case-distinct neighbors is delightful or treacherous. A safer
  alternative for the doc: `<leader>fH` ("find Help doc") or `<leader>hK`.

Recommendation: low priority — leaving as-is is fine. If you ever shrink
the keymap surface, drop `<leader>fk` since `<leader>?` is shorter and
already there for the same purpose.

## Out of scope for this handoff

The `<leader>h*` gitsigns prefix overlapping with which-key's group
conventions is fine — gitsigns is the only thing under `h`.
