-- Paragraph and section numbering for markdown/mdx, rendered into the
-- statuscolumn next to the line number. Implements the editorial-review anchor
-- grammar: headings H2..H6 each contribute a dotted-path component (§N,
-- §N.M, §N.M.K, ...), and any heading at any of those levels resets the ¶
-- counter for its own scope. H1 is ignored (title lives in frontmatter).
-- Scratchpad blockquotes (`Mental Note`, `TODO`, `Note to self`, `Draft note`
-- as the first token) and HTML comments are skipped; code fences, regular
-- blockquotes, lists, tables, and MDX components all count as one ¶.

local M = {}

-- bufnr -> {
--   blocks   = { [lnum] = { path = {ints}, paragraph = N } },
--   headings = { [lnum] = { path = {ints} } },
--   markers  = { [lnum] = "%#Comment#§1.2¶3   %*" },  -- padded statuscolumn text
--   empty    = "        ",                            -- pad for non-block lines
-- }
local cache = {}

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_code_fence(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end

-- Returns 1..6 if the line is an ATX heading at that level, else nil.
local function heading_level(line)
  local hashes = line:match("^(#+)%s") or line:match("^(#+)$")
  if not hashes then
    return nil
  end
  local n = #hashes
  if n >= 1 and n <= 6 then
    return n
  end
  return nil
end

local function is_setext_underline(line)
  return line:match("^%s*=+%s*$") ~= nil or line:match("^%s*%-+%s*$") ~= nil
end

local function is_html_comment_start(line)
  return line:match("^%s*<!%-%-") ~= nil
end

local function has_html_comment_end(line)
  return line:match("%-%->") ~= nil
end

local function is_scratchpad_first_line(line)
  local content = line:match("^%s*>%s*(.*)$")
  if not content then
    return false
  end
  return content:match("^Mental Note") ~= nil
    or content:match("^TODO") ~= nil
    or content:match("^Note to self") ~= nil
    or content:match("^Draft note") ~= nil
end

local function is_mdx_block_start(line)
  return line:match("^%s*</?%a") ~= nil
end

local function mdx_balance(line)
  local bal = 0
  for _ in line:gmatch("<%a") do
    bal = bal + 1
  end
  for _ in line:gmatch("</") do
    bal = bal - 1
  end
  for _ in line:gmatch("/>") do
    bal = bal - 1
  end
  return bal
end

local function find_frontmatter_end(lines)
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

function M.frontmatter_end(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  return find_frontmatter_end(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

-- Joins a path of integers into a key for the counters dict. Empty entries
-- (used for level-skipping like H2 → H4) become empty path components, so
-- {2, 0, 1} keys as "2..1" and "§2..1" is addressable but unusual.
local function path_key(path, depth)
  if depth == 0 then
    return ""
  end
  local parts = {}
  for i = 1, depth do
    parts[i] = tostring(path[i] or 0)
  end
  return table.concat(parts, ".")
end

local function format_path(path)
  if #path == 0 then
    return ""
  end
  local parts = {}
  for i, n in ipairs(path) do
    parts[i] = n == 0 and "" or tostring(n)
  end
  return table.concat(parts, ".")
end

local function copy_path(path)
  local out = {}
  for i, v in ipairs(path) do
    out[i] = v
  end
  return out
end

-- Update the running heading `path` and `counters` for an ATX heading at level
-- `hl` (H2 -> depth 1, H3 -> depth 2, ...). Truncates deeper levels, fills any
-- skipped intermediate levels with 0, and bumps the sibling counter under the
-- current parent. Mutates path and counters in place.
local function advance_heading(path, counters, hl)
  local depth = hl - 1
  for j = #path, depth, -1 do
    path[j] = nil
  end
  for j = #path + 1, depth - 1 do
    path[j] = 0
  end
  counters[depth] = counters[depth] or {}
  local parent_key = path_key(path, depth - 1)
  counters[depth][parent_key] = (counters[depth][parent_key] or 0) + 1
  path[depth] = counters[depth][parent_key]
end
M._advance_heading = advance_heading

-- Build the padded statuscolumn marker for each numbered line. Headings render
-- as "§<path>", blocks as "§<path>¶<n>" (or just "¶<n>" before any heading).
-- Returns the per-line markers table and the blank pad for non-numbered lines,
-- both right-padded to a common width.
local function render_markers(blocks, headings)
  local raw = {}
  local max_w = 5
  for lnum, h in pairs(headings) do
    local s = "§" .. format_path(h.path)
    raw[lnum] = s
    max_w = math.max(max_w, vim.api.nvim_strwidth(s))
  end
  for lnum, blk in pairs(blocks) do
    local p = format_path(blk.path)
    local s = p == "" and ("¶" .. blk.paragraph) or ("§" .. p .. "¶" .. blk.paragraph)
    raw[lnum] = s
    max_w = math.max(max_w, vim.api.nvim_strwidth(s))
  end

  local total = max_w + 1
  local markers = {}
  for lnum, s in pairs(raw) do
    local pad = string.rep(" ", total - vim.api.nvim_strwidth(s))
    markers[lnum] = "%#Comment#" .. s .. pad .. "%*"
  end
  return markers, string.rep(" ", total)
end
M._render_markers = render_markers

local function compute(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local headings = {}
  local fm_end = find_frontmatter_end(lines)

  local path = {}
  local counters = {}
  local paragraph = 0
  local in_block = false
  local in_code = false
  local in_html_comment = false
  local in_mdx = false
  local mdx_depth = 0
  local prev_was_text = false
  local last_paragraph_line = nil

  for i, line in ipairs(lines) do
    if i <= fm_end then
      in_block = false
      prev_was_text = false
    elseif in_html_comment then
      if has_html_comment_end(line) then
        in_html_comment = false
      end
      prev_was_text = false
    elseif in_code then
      if is_code_fence(line) then
        in_code = false
        in_block = false
      end
      prev_was_text = false
    elseif in_mdx then
      mdx_depth = mdx_depth + mdx_balance(line)
      if mdx_depth <= 0 then
        in_mdx = false
        mdx_depth = 0
        in_block = false
      end
      prev_was_text = false
    elseif is_blank(line) then
      in_block = false
      prev_was_text = false
    elseif is_html_comment_start(line) then
      if not has_html_comment_end(line) then
        in_html_comment = true
      end
      in_block = false
      prev_was_text = false
    else
      local hl = heading_level(line)
      if hl == 1 then
        in_block = false
        prev_was_text = false
      elseif hl then
        advance_heading(path, counters, hl)
        paragraph = 0
        headings[i] = { path = copy_path(path) }
        in_block = false
        prev_was_text = false
      elseif is_setext_underline(line) and prev_was_text then
        if last_paragraph_line and blocks[last_paragraph_line] then
          blocks[last_paragraph_line] = nil
          paragraph = paragraph - 1
          last_paragraph_line = nil
        end
        in_block = false
        prev_was_text = false
      else
        if not in_block then
          if is_scratchpad_first_line(line) then
            in_block = true
            prev_was_text = false
          elseif is_code_fence(line) then
            in_code = true
            paragraph = paragraph + 1
            blocks[i] = { path = copy_path(path), paragraph = paragraph }
            last_paragraph_line = i
            in_block = true
            prev_was_text = false
          elseif is_mdx_block_start(line) then
            local bal = mdx_balance(line)
            paragraph = paragraph + 1
            blocks[i] = { path = copy_path(path), paragraph = paragraph }
            last_paragraph_line = i
            in_block = true
            if bal > 0 then
              in_mdx = true
              mdx_depth = bal
            end
            prev_was_text = false
          else
            paragraph = paragraph + 1
            blocks[i] = { path = copy_path(path), paragraph = paragraph }
            last_paragraph_line = i
            in_block = true
            prev_was_text = true
          end
        end
      end
    end
  end

  local markers, empty = render_markers(blocks, headings)
  cache[bufnr] = {
    blocks = blocks,
    headings = headings,
    markers = markers,
    empty = empty,
  }
end

function M.marker()
  local winid = vim.g.statusline_winid
  local bufnr
  if type(winid) == "number" and winid ~= 0 then
    local ok, b = pcall(vim.api.nvim_win_get_buf, winid)
    bufnr = ok and b or vim.api.nvim_get_current_buf()
  else
    bufnr = vim.api.nvim_get_current_buf()
  end
  local data = cache[bufnr]
  if not data then
    return "      "
  end
  return data.markers[vim.v.lnum] or data.empty
end

_G._markdown_paragraph_marker = M.marker

local STATUSCOLUMN = "%s%C%{%v:lua._markdown_paragraph_marker()%}%l "

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  compute(bufnr)

  local group = vim.api.nvim_create_augroup("markdown_paragraphs_buf_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      compute(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      cache[bufnr] = nil
    end,
  })

  M.apply_window()
end

function M.apply_window()
  vim.opt_local.statuscolumn = STATUSCOLUMN
  vim.w.markdown_writing_active = true
end

function M.detach_window()
  if not vim.w.markdown_writing_active then
    return
  end
  vim.opt_local.statuscolumn = ""
  vim.w.markdown_writing_active = nil
end

function M.get_starts(bufnr)
  return cache[bufnr]
end

return M
