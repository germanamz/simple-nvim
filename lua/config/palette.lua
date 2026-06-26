-- Shared named colors, so a value reused across modules is retuned in one place
-- instead of as scattered literal hex. Deliberately tiny: only genuinely reused
-- values live here. Role-specific colors that happen to be similar stay local to
-- their own highlight group (each already uses default=true, so a colorscheme
-- can override regardless).
local M = {}

-- Muted/secondary text. Used by the git "unstaged" marker (git_status_codes) and
-- the legend labels in the smart picker and the review-base overlay.
M.muted = "#888888"

return M
