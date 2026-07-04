-- nvim-tree decorator that colours SYMLINKS teal — the third of the sibling
-- decorators (grey git-ignored in config.nvim_tree_ignore, blue dot-folders in
-- config.nvim_tree_dotfolder). Covers both file and directory symlinks: nvim-
-- tree gives FileLinkNode and DirectoryLinkNode the same node.type == "link"
-- (see the plugin's node/*-link.lua), so a single field test catches both.
-- Built through the shared colour-decorator factory
-- (config.nvim_tree_hl_decorator).
--
-- Uses its OWN group NvimTreeSymlinkMark rather than the builtin NvimTreeSymlink
-- so the whole-row (highlight_range = "all") teal is fully under our control and
-- never fights the theme's own symlink-name colour — the decorator paints on top
-- of it.
local M = {}

local hl = require("util.hl")

-- TEAL (distinct from grey ignored / blue dot-folders). alpha 0.85 keeps the hue
-- vivid so symlinks are identifiable at a glance.
local function define_highlights()
  hl.define_dim("NvimTreeSymlinkMark", { color = "#1a7f7c", alpha = 0.85 })
end

-- Pure: is `node` a symlink? Both FileLinkNode and DirectoryLinkNode report
-- node.type == "link", so this one field test catches file and directory links
-- alike. Field-only, no node methods — see the factory's clone caveat.
function M._is_symlink(node)
  return node.type == "link"
end

M.decorator = require("config.nvim_tree_hl_decorator")({
  group = "NvimTreeSymlinkMark",
  define_highlights = define_highlights,
  predicate = M._is_symlink,
})

return M
