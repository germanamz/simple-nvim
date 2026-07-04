-- Markdown helpers shared by the paragraph-numbering gutter
-- (config.markdown_paragraphs) and the glow preview (config.markdown_preview),
-- so the frontmatter-format assumption (a leading `---` ... `---` block) lives
-- in one place instead of being re-derived identically in each module.
local M = {}

-- Line number of the closing `---` of a leading YAML frontmatter block, or 0
-- when the buffer doesn't open with `---`. `lines` is a 1-indexed array of
-- strings (e.g. from nvim_buf_get_lines). The return doubles as "number of
-- frontmatter lines" since the block starts at line 1.
function M.frontmatter_end(lines)
  if lines[1] ~= "---" then
    return 0
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      return i
    end
  end
  return 0
end

-- True when the line opens or closes a fenced code block (``` or ~~~,
-- optionally indented). Shared by the paragraph gutter, the glow preview's
-- link transform, and the wikilink scanner so the fence grammar can't drift.
function M.is_fence(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end

return M
