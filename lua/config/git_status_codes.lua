-- Git-status-code grammar for the smart file pickers: the XY porcelain
-- dominant-letter precedence rule, the letter->highlight and letter->category
-- maps, and the code->display formatter. Extracted from telescope_smart so the
-- dominant-letter rule lives in exactly one place (it was duplicated verbatim in
-- format_prefix and _git_changes) and the grammar is unit-testable on its own.
local M = {}

local palette = require("config.palette")

-- Define the shared label highlight groups (`default = true`, so a colorscheme
-- can override). Lives here rather than telescope_smart so non-telescope
-- consumers (nvim-tree) can define them without loading the picker module.
function M.define_highlights()
  vim.api.nvim_set_hl(0, "SmartFilesAdded", { fg = "#6cc070", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUntracked", { fg = "#c08850", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesModified", { fg = "#5a8ed4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesDeleted", { fg = "#9a9a9a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesRenamed", { fg = "#4cb0a0", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesBase", { fg = "#d896ff", bold = true, default = true })
  -- Merge-conflict (unmerged) codes — UU/UA/UD — carry a dominant U; red so a
  -- conflict stands out from ordinary staged/worktree changes.
  vim.api.nvim_set_hl(0, "SmartFilesConflict", { fg = "#d05a5a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUnstaged", { fg = palette.muted, default = true })
end

-- XY porcelain precedence: the staged letter X dominates unless it is empty or
-- untracked, in which case the worktree letter Y wins.
function M.dominant_letter(x, y)
  return (x ~= " " and x ~= "?") and x or y
end

-- Highlight group for a status letter, or nil for a non-status letter.
function M.hl_for_letter(c)
  if c == "A" then
    return "SmartFilesAdded"
  elseif c == "R" or c == "C" then
    return "SmartFilesRenamed"
  elseif c == "D" then
    return "SmartFilesDeleted"
  elseif c == "M" or c == "T" then
    return "SmartFilesModified"
  elseif c == "?" then
    return "SmartFilesUntracked"
  elseif c == "U" then
    -- Unmerged: dominant letter of merge-conflict codes (UU/UA/UD). Without
    -- this the conflict letter rendered uncolored. category("U") stays nil —
    -- conflicts aren't one of the worktree count buckets.
    return "SmartFilesConflict"
  end
end

-- Count bucket for a status letter (added/modified/deleted/renamed/untracked),
-- or nil for a non-status letter. Keys match both the worktree `counts` table
-- and the per-category `counts.base` table in telescope_smart._git_changes.
function M.category(c)
  if c == "?" then
    return "untracked"
  elseif c == "A" then
    return "added"
  elseif c == "R" or c == "C" then
    return "renamed"
  elseif c == "D" then
    return "deleted"
  elseif c == "M" or c == "T" then
    return "modified"
  end
end

-- Turn an XY porcelain code (or 'b<letter>' for base-only) into a 2-char text
-- prefix plus a list of {range, hl} tuples.
function M.code_to_display(code)
  if not code or code == "" then
    return "  ", {}
  end
  if code == "??" then
    return "?*", { { { 0, 2 }, "SmartFilesUntracked" } }
  end
  if code:sub(1, 1) == "b" then
    local letter = code:sub(2, 2)
    local lhl = M.hl_for_letter(letter)
    local hls = { { { 0, 1 }, "SmartFilesBase" } }
    if lhl then
      table.insert(hls, { { 1, 2 }, lhl })
    end
    return "b" .. letter, hls
  end
  local x = code:sub(1, 1)
  local y = code:sub(2, 2)
  local dominant = M.dominant_letter(x, y)
  if dominant == "" or dominant == " " then
    return "  ", {}
  end
  local marker = (y ~= " " and y ~= "?") and "*" or " "
  local dhl = M.hl_for_letter(dominant)
  local hls = {}
  if dhl then
    table.insert(hls, { { 0, 1 }, dhl })
  end
  if marker == "*" then
    table.insert(hls, { { 1, 2 }, "SmartFilesUnstaged" })
  end
  return dominant .. marker, hls
end

-- Single-highlight variant of code_to_display for renderers that can only
-- color a label with one group per string (nvim-tree decorator icons): the
-- trimmed label plus the group of its leading character — the dominant letter
-- for worktree codes, SmartFilesBase for base-only codes. Returns nil for a
-- clean/empty code.
function M.code_to_icon(code)
  local text, hls = M.code_to_display(code)
  text = text:gsub("%s+$", "")
  if text == "" then
    return nil
  end
  return text, hls[1] and hls[1][2] or nil
end

return M
