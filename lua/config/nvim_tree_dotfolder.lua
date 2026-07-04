-- nvim-tree decorator that colours dot-prefixed DIRECTORIES (.git, .github,
-- .cache, ...) BLUE — the folder sibling of the git-ignored (grey) and symlink
-- (teal) decorators. Directories only: dot-FILES (.gitignore, .luacheckrc) stay
-- at full colour. Built through the shared colour-decorator factory
-- (config.nvim_tree_hl_decorator).
--
-- Uses NvimTreeHiddenFolderHL — nvim-tree's own group for hidden (dotfile)
-- folders. It's otherwise inert here because renderer.highlight_hidden is "none"
-- (the builtin Hidden decorator only paints when that is set), so this custom
-- decorator is the sole writer of the group and there's no double-paint.
local M = {}

local hl = require("util.hl")

-- BLUE (distinct from grey ignored / teal symlinks). alpha 0.85 keeps the hue
-- vivid — dot-folders are identified, not de-emphasised. #0969da is GitHub's
-- accent blue, matching the active theme.
local function define_highlights()
  hl.define_dim("NvimTreeHiddenFolderHL", { color = "#0969da", alpha = 0.85 })
end

-- Pure: is `node` a dot-prefixed directory? Reads FIELDS only (node.type,
-- node.absolute_path), never node methods — see the factory's clone caveat.
-- The optional trailing slash keeps the basename match correct for directory
-- paths; a symlinked directory reports type "link" (DirectoryLinkNode), so
-- only real dirs match.
function M._is_dotfolder(node)
  if node.type ~= "directory" then
    return false
  end
  local base = node.absolute_path and node.absolute_path:match("([^/]+)/?$")
  return base ~= nil and base:sub(1, 1) == "."
end

M.decorator = require("config.nvim_tree_hl_decorator")({
  group = "NvimTreeHiddenFolderHL",
  define_highlights = define_highlights,
  predicate = M._is_dotfolder,
})

return M
