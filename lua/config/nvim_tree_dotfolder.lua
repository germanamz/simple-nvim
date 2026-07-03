-- nvim-tree decorator that colours dot-prefixed DIRECTORIES (.git, .github,
-- .cache, ...) BLUE — the folder sibling of the git-ignored (grey) and symlink
-- (teal) decorators. Directories only: dot-FILES (.gitignore, .luacheckrc) stay
-- at full colour.
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
-- node.absolute_path), never node methods — a custom decorator is handed a
-- sanitized api-node clone without the Node metatable, so node:is_dotfile()
-- would be nil (that crashed an earlier version). The optional trailing slash
-- keeps the basename match correct for directory paths; a symlinked directory
-- reports type "link" (DirectoryLinkNode), so only real dirs match.
function M._is_dotfolder(node)
  if node.type ~= "directory" then
    return false
  end
  local base = node.absolute_path and node.absolute_path:match("([^/]+)/?$")
  return base ~= nil and base:sub(1, 1) == "."
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
    self.highlight_range = "all" -- dim both the folder icon and the name
    self.icon_placement = "none"
  end

  function Decorator:highlight_group(node)
    if M._is_dotfolder(node) then
      return "NvimTreeHiddenFolderHL"
    end
  end

  return Decorator
end

return M
