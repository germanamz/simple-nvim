-- nvim-tree decorator that visually marks git-ignored nodes when they are shown
-- (toggle with I — see lua/plugins/nvim-tree.lua). Ignore status comes from the
-- SAME fork-free predicate that hides them (config.ignore_filter.is_ignored), so
-- the marking and the hiding can never disagree: a node is dimmed iff pressing I
-- would hide it. Dims the WHOLE row — devicon and name — in NvimTreeGitIgnored,
-- a theme-derived dim grey (see util.hl.define_dim). Independent of the git
-- decorator, which contributes only status icons (highlight_range = "none"), so
-- the two never collide. Built through the shared colour-decorator factory
-- (config.nvim_tree_hl_decorator), like its dot-folder and symlink siblings.
local M = {}

local ignore_filter = require("config.ignore_filter")
local hl = require("util.hl")

-- Muted GREY from Comment: 0.55 weight, over halfway to the background, so it
-- recedes ("de-emphasised noise"). Distinct from the blue dot-folders and teal
-- symlinks; this decorator is ordered LAST of the three (see nvim-tree.lua) so
-- grey wins overlaps — an ignored dot-folder like .next/.venv reads grey.
local function define_highlights()
  hl.define_dim("NvimTreeGitIgnored", { source = "Comment", alpha = 0.55 })
end

-- is_ignored is O(1) table lookups (static set + memoized oracle); a
-- first-seen node fails open (returns false) and reloads once when the async
-- check-ignore lands, so newly-known ignores dim on the next pass — the same
-- flash-then-settle the filter already exhibits.
M.decorator = require("config.nvim_tree_hl_decorator")({
  group = "NvimTreeGitIgnored",
  define_highlights = define_highlights,
  predicate = function(node)
    return ignore_filter.is_ignored(node.absolute_path)
  end,
})

return M
