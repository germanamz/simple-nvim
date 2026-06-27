-- Shared named colors, so a value reused across modules is retuned in one place
-- instead of as scattered literal hex. Deliberately tiny: only genuinely reused
-- values live here. Role-specific colors that happen to be similar stay local to
-- their own highlight group (each already uses default=true, so a colorscheme
-- can override regardless).
local M = {}

-- Muted/secondary text. Used by the git "unstaged" marker (git_status_codes) and
-- the legend labels in the smart picker and the review-base overlay.
M.muted = "#888888"

-- Saturated git diff tints for gitsigns' custom highlight groups
-- (plugins/gitsigns.lua paint()). Unlike the role-specific colors above, these
-- intentionally OVERRIDE the colorscheme (no default=true) — the *_dark/*_light
-- pair is chosen from the active background at paint time, so a theme must not
-- win. Centralized here only to keep the literal hex in one place; the
-- selection/override logic stays in paint().
M.git = {
  -- Nr = colored line numbers (carry their own white fg, so one saturated value
  -- per role reads on both backgrounds).
  add_nr = "#4ea862",
  change_nr = "#7a5d1a",
  delete_nr = "#c85050",
  -- Ln = line backgrounds (bg only, inherit buffer fg); pick *_dark on a dark
  -- background, *_light on a light one.
  add_ln_dark = "#1e3a28",
  add_ln_light = "#b8e0c4",
  change_ln_dark = "#3a3320",
  change_ln_light = "#ead090",
  -- Inline word-diff background for changed spans.
  add_inline_dark = "#2f6f47",
  add_inline_light = "#8fd4a3",
  -- Deletion marker (sp underdash on GitSignsDeleteLn / GitSignsDelPrev).
  delete = "#c85050",
}

return M
