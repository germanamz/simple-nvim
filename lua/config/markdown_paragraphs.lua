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

local find_frontmatter_end = require("util.markdown").frontmatter_end

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

-- §heading anchors get their own brighter highlight so the section structure
-- stands out from the dim per-block ¶ counts (which stay linked to Comment).
-- Linked to Function with default=true so a colorscheme can override it, and
-- re-applied on ColorScheme like block_guides since a :colorscheme clears custom
-- links. Module-level (this file is required once, lazily, on the first markdown
-- buffer), so the apply + autocmd register exactly once.
local function ensure_section_highlight()
  vim.api.nvim_set_hl(0, "MarkdownSectionAnchor", { link = "Function", default = true })
end
ensure_section_highlight()
-- Named group with clear=true so re-requiring this module (a test, :Lazy reload)
-- replaces the handler instead of stacking a second copy.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("markdown_section_anchor", { clear = true }),
  callback = ensure_section_highlight,
})

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
    -- Heading lines get the brighter anchor group; block ¶ counts stay dim.
    local hl = headings[lnum] and "MarkdownSectionAnchor" or "Comment"
    markers[lnum] = "%#" .. hl .. "#" .. s .. pad .. "%*"
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
        -- A setext underline retroactively turns the previous text line into a
        -- heading, so undo the ¶ we counted for that title line. last_paragraph_
        -- line == i - 1 here: prev_was_text is set only in the plain-text branch,
        -- which also recorded the title as that line's block.
        if last_paragraph_line and blocks[last_paragraph_line] then
          blocks[last_paragraph_line] = nil
          paragraph = paragraph - 1
          last_paragraph_line = nil
        end
        -- "Title" + "---" is a setext H2: number it like an ATX H2 (advance §,
        -- reset ¶) and tag the title line (i - 1) as the heading. "Title" + "==="
        -- is H1, which we ignore (the title lives in frontmatter) -- delete-only,
        -- matching the ATX H1 path above.
        if line:match("^%s*%-+%s*$") then
          advance_heading(path, counters, 2)
          paragraph = 0
          headings[i - 1] = { path = copy_path(path) }
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
            -- Only PascalCase tags (MDX components: <Aside>, <Image>) open the
            -- multi-line swallow that keeps consuming lines until tag balance
            -- returns to zero. A lowercase HTML tag with no close on its line —
            -- a void element like <img src="x">, <br>, <hr> — would otherwise
            -- leave balance at +1 and silently strip ¶ markers from every
            -- following block. Lowercase tags fall through as a one-line ¶.
            if bal > 0 and line:match("^%s*<%u") then
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

-- bufnr -> uv_timer that debounces compute on rapid edits.
local timers = {}

-- Stop and close a buffer's debounce timer (idempotent), releasing the libuv
-- handle so it isn't leaked when the buffer goes away.
local function stop_timer(bufnr)
  local t = timers[bufnr]
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
    timers[bufnr] = nil
  end
end
M._stop_timer = stop_timer

-- Coalesce rapid TextChanged/TextChangedI into one compute ~80ms after the last
-- edit. compute walks the whole buffer and render_markers measures each marker's
-- width in a second pass, so running it per keystroke is wasted work on a long
-- document (the long-form writing this feature targets).
local function schedule_compute(bufnr)
  local t = timers[bufnr]
  if not t then
    t = vim.uv.new_timer()
    timers[bufnr] = t
  end
  t:stop()
  t:start(
    80,
    0,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        stop_timer(bufnr)
        return
      end
      compute(bufnr)
      -- compute only refreshed the cache; nudge the statuscolumn so the new
      -- markers show without waiting for the next incidental redraw.
      pcall(vim.api.nvim__redraw, { buf = bufnr, statuscolumn = true })
    end)
  )
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Initial pass is synchronous so the gutter is correct the moment the buffer
  -- opens; subsequent edits are debounced.
  compute(bufnr)

  local group = vim.api.nvim_create_augroup("markdown_paragraphs_buf_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      schedule_compute(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      stop_timer(bufnr)
      cache[bufnr] = nil
    end,
  })

  M.apply_window()
end

function M.apply_window()
  -- LSP hover/diagnostic popups (K) render their markdown into a floating
  -- window whose buffer gets filetype=markdown, which would otherwise drag the
  -- §/¶ gutter into the popup. Keep the gutter in real markdown buffers only.
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return
  end
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
