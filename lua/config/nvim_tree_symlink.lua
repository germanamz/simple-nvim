-- nvim-tree decorator that colours SYMLINKS teal — the third of the sibling
-- decorators (grey git-ignored in config.nvim_tree_ignore, blue dot-folders in
-- config.nvim_tree_dotfolder). Covers both file and directory symlinks: nvim-
-- tree gives FileLinkNode and DirectoryLinkNode the same node.type == "link"
-- (see the plugin's node/*-link.lua), so a single field test catches both.
--
-- Uses its OWN group NvimTreeSymlinkMark rather than the builtin NvimTreeSymlink
-- so the whole-row (highlight_range = "all") teal is fully under our control and
-- never fights the theme's own symlink-name colour — the decorator paints on top
-- of it. Reads FIELDS only (node.type): custom decorators are handed sanitized
-- api-node clones without the Node metatable, so node methods would be nil (this
-- is exactly what crashed the dot-folder decorator's earlier node:is_dotfile()).
local M = {}

local hl = require("util.hl")

-- TEAL (distinct from grey ignored / blue dot-folders). alpha 0.85 keeps the hue
-- vivid so symlinks are identifiable at a glance.
local function define_highlights()
  hl.define_dim("NvimTreeSymlinkMark", { color = "#1a7f7c", alpha = 0.85 })
end

-- Pure: is `node` a symlink? Both FileLinkNode and DirectoryLinkNode report
-- node.type == "link" (see the plugin's node/*-link.lua), so this one field test
-- catches file and directory links alike. Field-only, no node methods (the api-
-- node clone lacks the Node metatable).
function M._is_symlink(node)
  return node.type == "link"
end

local Decorator

-- Deferred behind a function because nvim-tree.api is only requirable once the
-- plugin has loaded — same reason config.nvim_tree_git.decorator() is lazy.
function M.decorator()
  if Decorator then
    return Decorator
  end

  Decorator = require("nvim-tree.api").Decorator:extend()

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

  function Decorator:new()
    self.enabled = true
    self.highlight_range = "all" -- colour both the icon and the name
    self.icon_placement = "none"
  end

  function Decorator:highlight_group(node)
    if M._is_symlink(node) then
      return "NvimTreeSymlinkMark"
    end
  end

  return Decorator
end

return M
