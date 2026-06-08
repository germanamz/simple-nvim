-- Block scope guides: vertical lines marking the foldable blocks the cursor is
-- nested inside. Persistent dim guides on every foldable block; the cursor's
-- ancestor chain (innermost + parents, siblings excluded) lights up brighter.
-- Rendered via a decoration provider with ephemeral overlay extmarks, so the
-- code never reflows and only visible lines cost anything. See
-- docs/superpowers/specs/2026-06-08-block-scope-guides-design.md.
local M = {}

-- Display width of a line's leading whitespace, honoring tab stops.
function M._indent_width(line, tabstop)
  tabstop = tabstop or 8
  local w = 0
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == " " then
      w = w + 1
    elseif ch == "\t" then
      w = w + (tabstop - (w % tabstop))
    else
      return w
    end
  end
  return w
end

-- blocks: array of { s, e, col } (0-indexed rows; col = display column).
-- Returns { active = <index|nil>, set = { [index] = true } } for the blocks
-- whose extent contains cursor_row; active = innermost (smallest extent, then
-- deeper col on a tie).
function M.chain_at(blocks, cursor_row)
  local containing = {}
  for i, b in ipairs(blocks) do
    if cursor_row >= b.s and cursor_row <= b.e then
      containing[#containing + 1] = i
    end
  end
  table.sort(containing, function(ia, ib)
    local a, b = blocks[ia], blocks[ib]
    local da, db = a.e - a.s, b.e - b.s
    if da ~= db then
      return da < db
    end
    return a.col > b.col
  end)
  local set = {}
  for _, i in ipairs(containing) do
    set[i] = true
  end
  return { active = containing[1], set = set }
end

-- For screen `row` with leading-indent display width `row_indent` (pass
-- math.huge for blank lines so all covering guides draw), return the guides to
-- paint: array of { col, tier } sorted by col. tier is "active" for the
-- cursor's innermost block, "chain" for a parent in the chain, else "dim".
function M.guides_at(blocks, chain, row, row_indent)
  local out = {}
  for i, b in ipairs(blocks) do
    if row >= b.s and row <= b.e and row_indent > b.col then
      local tier = "dim"
      if chain then
        if chain.active == i then
          tier = "active"
        elseif chain.set[i] then
          tier = "chain"
        end
      end
      out[#out + 1] = { col = b.col, tier = tier }
    end
  end
  table.sort(out, function(a, b)
    return a.col < b.col
  end)
  return out
end

return M
