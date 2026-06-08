-- Block scope guides: vertical lines marking the foldable blocks the cursor is
-- nested inside. Persistent dim guides on every foldable block; the cursor's
-- ancestor chain (innermost + parents, siblings excluded) lights up brighter.
-- Rendered via a decoration provider with ephemeral overlay extmarks, so the
-- code never reflows and only visible lines cost anything. See
-- docs/superpowers/specs/2026-06-08-block-scope-guides-design.md.
local M = {}

local cache = {} -- [buf] = { tick = <changedtick>, blocks = {...} }

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

-- All foldable blocks in `buf` as { s, e, col }, via the language's folds query.
-- col is the display width of the block header's leading indentation.
function M.collect_foldable_blocks(buf)
  local blocks = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return blocks
  end
  local query = vim.treesitter.query.get(parser:lang(), "folds")
  if not query then
    return blocks
  end
  local tabstop = vim.bo[buf].tabstop
  for _, tree in ipairs(parser:parse()) do
    for id, node in query:iter_captures(tree:root(), buf, 0, -1) do
      if query.captures[id] == "fold" then
        local s, _, e = node:range()
        if e > s then
          local header = vim.api.nvim_buf_get_lines(buf, s, s + 1, false)[1] or ""
          blocks[#blocks + 1] = { s = s, e = e, col = M._indent_width(header, tabstop) }
        end
      end
    end
  end
  return blocks
end

-- collect_foldable_blocks cached per buffer changedtick.
function M.blocks_for(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick then
    return c.blocks
  end
  local blocks = M.collect_foldable_blocks(buf)
  cache[buf] = { tick = tick, blocks = blocks }
  return blocks
end

return M
