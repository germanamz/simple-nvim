-- Markdown format assumptions -- the leading `---` ... `---` frontmatter block
-- and the fence grammar -- stated once, so the modules that scan a markdown
-- buffer cannot quietly disagree about where prose starts and where code ends.
--
-- One consumer today: config.markdown_paragraphs, the section/paragraph gutter.
-- The second was the preview, back when it rendered the buffer through `glow`
-- and had to strip frontmatter and rewrite links before handing the text over.
-- It now passes the file itself to a cmux markdown panel and parses nothing at
-- all (see docs/superpowers/markdown-preview.md), which leaves this module one
-- consumer short of the extraction rule in docs/superpowers/refactoring.md --
-- fair game to fold back into the gutter if nothing else claims it.
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
-- optionally indented). Sits beside frontmatter_end because both answer the same
-- question -- which lines are not prose -- and the gutter must not number a
-- fenced block's contents as paragraphs.
function M.is_fence(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end

return M
