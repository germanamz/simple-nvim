-- Factory for the whole-row highlight decorators (git-ignored grey, dot-folder
-- blue, symlink teal): the "how to correctly build an nvim-tree colour
-- decorator" contract lives here once instead of being repeated per sibling.
-- spec = {
--   group             = highlight group returned for matching nodes,
--   define_highlights = fn that (re)defines that group (called once at build
--                       and again on ColorScheme, which resets hl groups),
--   predicate         = fn(node) -> boolean. Called per node per render (hot
--                       path), so it must be cheap. IMPORTANT: custom
--                       decorators receive sanitized api-node CLONES without
--                       the Node metatable — read FIELDS only (node.type,
--                       node.absolute_path), never node methods (an earlier
--                       node:is_dotfile() crashed on exactly this).
-- }
-- Returns a memoized decorator() builder, deferred behind a function because
-- nvim-tree.api is only requirable after the plugin has loaded.
return function(spec)
  local Decorator
  return function()
    if Decorator then
      return Decorator
    end

    Decorator = require("nvim-tree.api").Decorator:extend()

    spec.define_highlights()
    -- Named per-decorator augroup (keyed by the unique spec.group): clear=true
    -- makes a rebuild after a package.loaded reset replace the autocmd instead
    -- of stacking a duplicate, while siblings keep their own registrations.
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("nvim_tree_hl_" .. spec.group, { clear = true }),
      callback = spec.define_highlights,
    })

    function Decorator:new()
      self.enabled = true
      self.highlight_range = "all" -- colour both the devicon and the name
      self.icon_placement = "none"
    end

    function Decorator:highlight_group(node)
      if spec.predicate(node) then
        return spec.group
      end
    end

    return Decorator
  end
end
