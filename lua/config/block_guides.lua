-- Block scope guides: vertical lines marking the foldable blocks the cursor is
-- nested inside. Persistent dim guides on every foldable block; the cursor's
-- ancestor chain (innermost + parents, siblings excluded) lights up brighter.
-- Rendered via a decoration provider with ephemeral overlay extmarks, so the
-- code never reflows and only visible lines cost anything. See
-- docs/superpowers/specs/2026-06-08-block-scope-guides-design.md.
local M = {}

local cache = {} -- [buf] = { tick = <changedtick>, blocks = {...} }

local ns = vim.api.nvim_create_namespace("block_guides")
local GUIDE_CHAR = "│"
local HL = { active = "BlockGuideActive", chain = "BlockGuideChain", dim = "BlockGuide" }
local EXCLUDED_FT = { [""] = true, markdown = true, mdx = true, help = true, text = true }
local enabled = true
local draw = { active = false, blocks = nil, chain = nil } -- set per redraw in on_win

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

-- Guides to paint on `row`, reading the line for its indent. Blank/whitespace-
-- only lines use math.huge so every covering guide draws through the gap.
function M.guides_for_row(blocks, chain, buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local indent = line:match("^%s*$") and math.huge or M._indent_width(line, vim.bo[buf].tabstop)
  return M.guides_at(blocks, chain, row, indent)
end

function M.is_enabled()
  return enabled
end

local function eligible(buf)
  if not enabled then
    return false
  end
  if EXCLUDED_FT[vim.bo[buf].filetype] then
    return false
  end
  return vim.treesitter.highlighter.active[buf] ~= nil
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "BlockGuide", { link = "Whitespace", default = true })
  vim.api.nvim_set_hl(0, "BlockGuideChain", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "BlockGuideActive", { link = "Function", default = true })
end

-- Decoration provider: on_win runs once per window per redraw (compute the
-- chain from that window's cursor); on_line paints ephemeral overlay guides.
local function on_win(_, win, buf)
  draw.active = false
  if not eligible(buf) then
    return false
  end
  local blocks = M.blocks_for(buf)
  if #blocks == 0 then
    return false
  end
  draw.active = true
  draw.blocks = blocks
  draw.chain = M.chain_at(blocks, vim.api.nvim_win_get_cursor(win)[1] - 1)
  return true
end

local function on_line(_, _win, buf, row)
  if not draw.active then
    return
  end
  for _, g in ipairs(M.guides_for_row(draw.blocks, draw.chain, buf, row)) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      ephemeral = true,
      virt_text = { { GUIDE_CHAR, HL[g.tier] } },
      virt_text_win_col = g.col,
      hl_mode = "combine",
    })
  end
end

function M.toggle()
  enabled = not enabled
  pcall(vim.api.nvim__redraw, { valid = false, flush = true })
  vim.notify("Block guides " .. (enabled and "on" or "off"))
end

function M.setup()
  ensure_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = ensure_highlights })
  vim.api.nvim_set_decoration_provider(ns, { on_win = on_win, on_line = on_line })

  -- Drop the per-buffer cache when a buffer is wiped.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    callback = function(args)
      cache[args.buf] = nil
    end,
  })

  -- Repaint the moved window on cursor move so the chain recolors across the
  -- whole viewport (a partial redraw would leave stale ephemeral guides).
  -- Coalesced to once per event-loop tick.
  local redraw_scheduled = false
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    callback = function()
      if not enabled or redraw_scheduled then
        return
      end
      redraw_scheduled = true
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        redraw_scheduled = false
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim__redraw, { win = win, valid = false })
        end
      end)
    end,
  })

  vim.keymap.set("n", "<leader>ub", M.toggle, { desc = "Toggle block guides" })
end

return M
