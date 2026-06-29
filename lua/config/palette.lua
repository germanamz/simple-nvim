-- Shared named colors, so a value reused across modules is retuned in one place
-- instead of as scattered literal hex. Deliberately tiny: only genuinely reused
-- values live here. Role-specific colors that happen to be similar stay local to
-- their own highlight group (each already uses default=true, so a colorscheme
-- can override regardless).
local M = {}

-- Muted/secondary text. Used by the git "unstaged" marker (git_status_codes) and
-- the legend labels in the smart picker and the review-base overlay. GitHub's
-- fg.muted token — legible (~4.5:1) on the high-contrast white background.
M.muted = "#6e7781"

-- GitHub-light diff tints for gitsigns' custom highlight groups
-- (plugins/gitsigns.lua paint()). Unlike the role-specific colors above, these
-- intentionally OVERRIDE the colorscheme (no default=true) so the bespoke diff
-- visualization (numbered markers, line backgrounds, inline word-diff) wins over
-- the theme's plainer GitSigns groups. Centralized here to keep the literal hex
-- in one place; the override logic stays in paint(). Light-only, so a single
-- value per role (no background branching).
M.git = {
  -- Nr = colored line-number "chips": a dark fg on a light tint reads on the
  -- white background (the old white-on-saturated chip would wash out).
  add_nr_fg = "#0f5323",
  add_nr_bg = "#abf2bc",
  change_nr_fg = "#6f4e00",
  change_nr_bg = "#f5d98a",
  delete_nr_fg = "#a0111f",
  delete_nr_bg = "#ffc9c2",
  -- Ln = full-line backgrounds (bg only, inherit buffer fg): GitHub's subtle
  -- add/change diff fills.
  add_ln = "#d2fbd9",
  change_ln = "#fdf2c0",
  -- Inline word-diff background for changed spans: GitHub's add-emphasis green,
  -- stronger than add_ln so the differing span stands out within the line.
  add_inline = "#abf2bc",
  -- Deletion marker (sp underdash on GitSignsDeleteLn / GitSignsDelPrev):
  -- GitHub's danger red.
  delete = "#cf222e",
}

return M
