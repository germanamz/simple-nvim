-- Paragraph numbering for markdown/mdx, rendered into the statuscolumn next
-- to the line number. A paragraph is a run of non-blank lines outside fenced
-- code blocks, separated by blank lines.

local M = {}

-- bufnr -> { [line_num] = paragraph_num } for paragraph-start lines.
-- Module-local table avoids a vim.b round-trip that would coerce integer keys
-- into strings.
local cache = {}

local ns_ruler = vim.api.nvim_create_namespace("markdown_column_ruler")
local RULER_COL = 80

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_code_fence(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end

local function is_atx_heading(line)
  -- # H1, ## H2, etc. (CommonMark allows # followed by space, or # alone)
  return line:match("^%s*#+%s") ~= nil or line:match("^%s*#+$") ~= nil
end

local function is_setext_underline(line)
  return line:match("^%s*=+%s*$") ~= nil or line:match("^%s*%-+%s*$") ~= nil
end

local function is_list_item(line)
  -- bullet (-, *, +) or ordered (1. / 1))
  return line:match("^%s*[%-%*%+]%s") ~= nil or line:match("^%s*%d+[%.%)]%s") ~= nil
end

local function is_block_quote(line)
  return line:match("^%s*>") ~= nil
end

local function is_table_row(line)
  return line:match("^%s*|") ~= nil
end

local function is_hr(line)
  -- 3+ of - / * / _, possibly separated by whitespace, nothing else on the line
  local stripped = line:gsub("%s", "")
  return stripped:match("^%-%-%-+$") ~= nil
    or stripped:match("^%*%*%*+$") ~= nil
    or stripped:match("^___+$") ~= nil
end

-- YAML frontmatter: file starts with '---' on line 1 and a closing '---'
-- somewhere below. Returns the 1-indexed line number of the closing '---',
-- or 0 if there is no frontmatter.
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

-- Aligns with what ¶N points to in writing tools / Pandoc AST: body prose
-- only. Headings (ATX + Setext), lists, block quotes, tables, horizontal
-- rules, and fenced code are all skipped.
local function compute(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local starts = {}
  local fm_end = find_frontmatter_end(lines)
  local in_code = false
  local in_para = false
  local count = 0
  local last_para_start = nil
  local prev_was_text = false

  for i, line in ipairs(lines) do
    if i <= fm_end then
      in_para = false
      prev_was_text = false
    elseif is_code_fence(line) then
      in_code = not in_code
      in_para = false
      prev_was_text = false
    elseif in_code then
      prev_was_text = false
    elseif is_blank(line) then
      in_para = false
      prev_was_text = false
    elseif is_setext_underline(line) and prev_was_text then
      -- prior text line(s) were actually a Setext heading — undo the start
      if last_para_start then
        starts[last_para_start] = nil
        count = count - 1
      end
      in_para = false
      last_para_start = nil
      prev_was_text = false
    elseif
      is_atx_heading(line)
      or is_list_item(line)
      or is_block_quote(line)
      or is_table_row(line)
      or is_hr(line)
    then
      in_para = false
      prev_was_text = false
    else
      if not in_para then
        count = count + 1
        starts[i] = count
        last_para_start = i
        in_para = true
      end
      prev_was_text = true
    end
  end

  cache[bufnr] = starts
end

-- Per-line `│` overlay anchored at window column RULER_COL-1. Works because
-- textwidth=80 hard-wraps content, so no soft-wrap continuation rows.
local function render_ruler(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ruler, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  for i = 0, n - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, ns_ruler, i, 0, {
      virt_text = { { "│", "NonText" } },
      virt_text_win_col = RULER_COL - 1,
      hl_mode = "combine",
    })
  end
end

-- Called per-line during statuscolumn evaluation. Must be fast: table lookup
-- only. Uses g:statusline_winid so we read the buffer being drawn, not the
-- focused buffer (matters when the same buffer is shown in multiple windows).
function M.marker()
  local winid = vim.g.statusline_winid
  local bufnr
  if type(winid) == "number" and winid ~= 0 then
    local ok, b = pcall(vim.api.nvim_win_get_buf, winid)
    bufnr = ok and b or vim.api.nvim_get_current_buf()
  else
    bufnr = vim.api.nvim_get_current_buf()
  end
  local starts = cache[bufnr]
  if not starts then
    return "    "
  end
  local n = starts[vim.v.lnum]
  if not n then
    return "    "
  end
  return string.format("%%#Comment#¶%-3d%%*", n)
end

-- Expose as a global so statuscolumn can call v:lua._markdown_paragraph_marker()
-- without going through v:lua.require'...', which depends on vim expression
-- parser handling Lua-style string-arg call syntax.
_G._markdown_paragraph_marker = M.marker

local STATUSCOLUMN = "%s%C%{%v:lua._markdown_paragraph_marker()%}%l "

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  compute(bufnr)
  render_ruler(bufnr)

  local group = vim.api.nvim_create_augroup("markdown_paragraphs_buf_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      compute(bufnr)
      render_ruler(bufnr)
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

-- Reset window-local statuscolumn when a window switches to a non-markdown
-- buffer. No-op if attach was never called on this window.
function M.detach_window()
  if not vim.w.markdown_writing_active then
    return
  end
  vim.opt_local.statuscolumn = ""
  vim.w.markdown_writing_active = nil
end

-- Test inspection: returns the {line_num -> paragraph_num} table for a buffer.
function M.get_starts(bufnr)
  return cache[bufnr]
end

return M
