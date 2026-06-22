-- The "markdown family" filetypes — the buffers that get paragraph numbering,
-- the glow preview, and wikilink `gd`. Single source for the set so adding a
-- member (e.g. mdc / quarto) is one edit here, not shotgun surgery across
-- options.lua / wikilinks.lua / markdown_preview.lua.
--
-- This is deliberately NOT the home for treesitter parser mapping or per-server
-- LSP `filetypes` lists: those are keyed differently (parser language; which
-- server attaches to which ft) and intentionally live with their own modules.
local M = {}

-- Usable directly as an autocmd `pattern`.
M.markdown = { "markdown", "mdx" }

local markdown_set = {}
for _, ft in ipairs(M.markdown) do
  markdown_set[ft] = true
end

function M.is_markdown(ft)
  return markdown_set[ft] == true
end

return M
