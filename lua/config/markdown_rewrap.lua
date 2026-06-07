-- Markdown <leader>w "rewrap from cursor to end of file". Extracted from
-- options.lua so the planner (which decides what is prose vs a fenced code block
-- vs a table row) is testable on its own.
--
-- LSP attach sets formatexpr to vim.lsp.formatexpr, which doesn't honor
-- textwidth, so rewrap() drops it for the duration of gq and restores it after.
-- It skips past YAML frontmatter so wrapping never breaks `key: value` lines,
-- skips table rows (lines starting with `|`, which gq can't reflow), and routes
-- fenced code blocks to a language-specific formatter instead of gq.
local M = {}

local function parse_fence(line)
  local indent, fc, lang = line:match("^(%s*)(```+)%s*([%w_.+-]*)")
  if fc then
    return indent, fc, lang
  end
  indent, fc, lang = line:match("^(%s*)(~~~+)%s*([%w_.+-]*)")
  if fc then
    return indent, fc, lang
  end
  return nil
end
M._parse_fence = parse_fence

-- Format one fenced code block in the current buffer via its language formatter
-- (config.formatters). Unknown tags / missing binaries / non-zero exits leave
-- the block untouched. Indentation is stripped before formatting and reapplied.
local function format_code_block(block)
  local cmd = require("config.formatters").resolve_fence_argv(block.lang)
  if not cmd or block.from > block.to then
    return
  end
  local content = vim.api.nvim_buf_get_lines(0, block.from - 1, block.to, false)
  local indent = block.indent or ""
  if indent ~= "" then
    for i, line in ipairs(content) do
      if line:sub(1, #indent) == indent then
        content[i] = line:sub(#indent + 1)
      end
    end
  end
  local stdin = table.concat(content, "\n") .. "\n"
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = stdin, text = true }):wait(5000)
  end)
  if not ok or not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
    return
  end
  local out = res.stdout
  if out:sub(-1) == "\n" then
    out = out:sub(1, -2)
  end
  local new_lines = vim.split(out, "\n", { plain = true })
  if indent ~= "" then
    for i, line in ipairs(new_lines) do
      if line ~= "" then
        new_lines[i] = indent .. line
      end
    end
  end
  vim.api.nvim_buf_set_lines(0, block.from - 1, block.to, false, new_lines)
end
M._format_code_block = format_code_block

-- Scan `lines` (a slice of the buffer beginning at buffer line `start_line`,
-- ending at `last_line`) and classify it into a sorted list of actions: prose
-- chunks ({kind="prose", from, to}) to reflow with gq, and fenced code blocks
-- ({kind="code", from, to, lang, indent}) to format. Table rows are excluded
-- from prose ranges. Pure — no buffer access.
function M.plan_actions(lines, start_line, last_line)
  local actions = {}
  local chunk_from = nil
  local code_open = nil -- { content_from, lang, indent, fence_char, fence_len }
  for i, line in ipairs(lines) do
    local lnum = start_line + i - 1
    if code_open then
      local _, fc = parse_fence(line)
      if fc and fc:sub(1, 1) == code_open.fence_char and #fc >= code_open.fence_len then
        table.insert(actions, {
          kind = "code",
          from = code_open.content_from,
          to = lnum - 1,
          lang = code_open.lang,
          indent = code_open.indent,
        })
        code_open = nil
      end
    else
      local indent, fc, lang = parse_fence(line)
      if fc then
        if chunk_from then
          table.insert(actions, { kind = "prose", from = chunk_from, to = lnum - 1 })
          chunk_from = nil
        end
        code_open = {
          content_from = lnum + 1,
          lang = lang,
          indent = indent,
          fence_char = fc:sub(1, 1),
          fence_len = #fc,
        }
      elseif line:match("^%s*|") then
        if chunk_from then
          table.insert(actions, { kind = "prose", from = chunk_from, to = lnum - 1 })
          chunk_from = nil
        end
      elseif not chunk_from then
        chunk_from = lnum
      end
    end
  end
  if chunk_from then
    table.insert(actions, { kind = "prose", from = chunk_from, to = last_line })
  end
  -- An unterminated fence at EOF: best-effort, format what's there.
  if code_open and code_open.content_from <= last_line then
    table.insert(actions, {
      kind = "code",
      from = code_open.content_from,
      to = last_line,
      lang = code_open.lang,
      indent = code_open.indent,
    })
  end

  table.sort(actions, function(a, b)
    return a.from < b.from
  end)
  return actions
end

-- Rewrap from the cursor to the end of the current buffer.
function M.rewrap()
  local saved_fe = vim.bo.formatexpr
  local pos = vim.api.nvim_win_get_cursor(0)
  vim.bo.formatexpr = ""

  local fm_end = require("config.markdown_paragraphs").frontmatter_end(0)
  local start_line = math.max(pos[1], fm_end + 1)
  local last_line = vim.api.nvim_buf_line_count(0)
  if start_line <= last_line then
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, last_line, false)
    local actions = M.plan_actions(lines, start_line, last_line)
    -- Apply in reverse so line-count shifts from an earlier action don't
    -- invalidate later action boundaries.
    for i = #actions, 1, -1 do
      local a = actions[i]
      if a.kind == "prose" then
        pcall(vim.api.nvim_win_set_cursor, 0, { a.from, 0 })
        vim.cmd(string.format("silent! keepjumps normal! V%dGgq", a.to))
      else
        format_code_block(a)
      end
    end
  end

  vim.bo.formatexpr = saved_fe
  pcall(vim.api.nvim_win_set_cursor, 0, pos)
end

return M
