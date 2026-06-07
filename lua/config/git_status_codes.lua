-- Git-status-code grammar for the smart file pickers: the XY porcelain
-- dominant-letter precedence rule, the letter->highlight and letter->category
-- maps, and the code->display formatter. Extracted from telescope_smart so the
-- dominant-letter rule lives in exactly one place (it was duplicated verbatim in
-- format_prefix and _git_changes) and the grammar is unit-testable on its own.
local M = {}

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

return M
