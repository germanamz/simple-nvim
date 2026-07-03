-- Small highlight helpers shared by the nvim-tree decorators (config
-- .nvim_tree_ignore / .nvim_tree_dotfolder / .nvim_tree_symlink). Keeps the
-- "theme-aware muted colour" recipe in one place so the decorators stay in sync.
local M = {}

-- Pure: blend two 24-bit RGB colours; alpha is the weight of `fg` (0..1), so a
-- lower alpha sits closer to `bg` and reads more muted.
function M.blend(fg, bg, alpha)
  local function split(c)
    return math.floor(c / 0x10000) % 0x100, math.floor(c / 0x100) % 0x100, c % 0x100
  end
  local fr, fg2, fb = split(fg)
  local br, bg2, bb = split(bg)
  local function mix(a, b)
    return math.floor(a * alpha + b * (1 - alpha) + 0.5)
  end
  return string.format("#%02x%02x%02x", mix(fr, br), mix(fg2, bg2), mix(fb, bb))
end

-- Define `group` as a muted colour: a base hue blended `alpha` of the way kept,
-- the rest toward Normal's background — so it reads softer than full-strength
-- text and adapts to the (light) theme's background. The base is opts.color (a
-- "#rrggbb" string) when given, else the foreground of opts.source (default
-- "Comment"). A lower alpha = more washed toward the background (use it to make
-- a group recede); a higher alpha keeps the hue vivid (use it to identify).
-- Falls back to linking opts.fallback (default NonText, the dimmest builtin UI
-- group) when colours aren't resolvable (notermguicolors / cterm-only themes).
-- NOT auto-reapplied on ColorScheme — callers own that, since each already
-- registers a ColorScheme autocmd.
function M.define_dim(group, opts)
  opts = opts or {}
  local base = opts.color and tonumber((opts.color:gsub("#", "")), 16)
  if not base then
    base = vim.api.nvim_get_hl(0, { name = opts.source or "Comment", link = false }).fg
  end
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if base and normal.bg then
    vim.api.nvim_set_hl(0, group, { fg = M.blend(base, normal.bg, opts.alpha or 0.55) })
  else
    vim.api.nvim_set_hl(0, group, { link = opts.fallback or "NonText" })
  end
end

return M
