-- Count LSP references to the symbol under the cursor within the current buffer
-- and expose the result as a statusline segment (`_G.lsp_refs_status`).
-- Also highlights the in-buffer occurrences via extmarks in a dedicated namespace.

local M = {}

local ns = vim.api.nvim_create_namespace("lsp_refs_status")

-- state[bufnr] = { row, col, count } — last resolved result for that buffer.
local state = {}

-- inflight[bufnr] = true while a references request is pending, so a steady
-- idle on one identifier doesn't re-issue the (whole-project) scan every tick.
local inflight = {}

-- Below this many in-buffer occurrences there's nothing useful to show: a lone
-- use isn't worth painting or a navigation affordance. One constant so the paint
-- gate and the statusline segment can't drift to different thresholds (which
-- showed "⇄1" with no highlight and the ]r/[r jumps as no-ops).
local MIN_HIGHLIGHTED_REFS = 2

-- Neovim's default colorscheme links LspReferenceText to Visual, so the painted
-- symbol occurrences look identical to a text selection — easy to mistake for a
-- stuck selection that won't clear on a mode change. Give the group its own look
-- (underline) so "other uses of this symbol" reads distinctly from a real
-- selection. `default = true` still lets a real colorscheme override it; we
-- re-apply on ColorScheme since loading one resets highlight groups.
local function ensure_highlight()
  vim.api.nvim_set_hl(0, "LspReferenceText", { underline = true, default = true })
end

local function clear_marks(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function has_refs_client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.server_capabilities and c.server_capabilities.referencesProvider then
      return c
    end
  end
  return nil
end

local function cursor_rc()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

-- Keep only reference locations in `buf_uri`, deduped by start position.
-- Returns the in-buffer ranges and their count.
local function dedup_refs(result, buf_uri)
  local seen, ranges, count = {}, {}, 0
  for _, loc in ipairs(result) do
    if loc.uri == buf_uri then
      local s = loc.range.start
      local key = s.line .. ":" .. s.character
      if not seen[key] then
        seen[key] = true
        count = count + 1
        ranges[#ranges + 1] = loc.range
      end
    end
  end
  return ranges, count
end
M._dedup_refs = dedup_refs

-- Highlight each reference range with an extmark in our namespace.
local function paint_refs(bufnr, ranges)
  for _, r in ipairs(ranges) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, r.start.line, r.start.character, {
      end_row = r["end"].line,
      end_col = r["end"].character,
      hl_group = "LspReferenceText",
      priority = 120,
    })
  end
end

local function request(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end

  local client = has_refs_client(bufnr)
  if not client then
    state[bufnr] = nil
    return
  end

  -- Skip the (whole-project) references request when <cword> is empty — i.e. the
  -- cursor isn't on a keyword character at all (whitespace/punctuation). Note a
  -- keyword or a word inside a comment still has a non-empty <cword>, so those
  -- do issue a request; per-position caching bounds it to one per distinct spot.
  if vim.fn.expand("<cword>") == "" then
    state[bufnr] = nil
    return
  end

  local row, col = cursor_rc()

  -- Dedup: skip when we already have a result for this exact position, or a
  -- request for this buffer is still in flight. Without this, idling on one
  -- identifier re-issues a whole-project references scan every `updatetime`
  -- (250ms) — costly against a large superproject server root.
  local prev = state[bufnr]
  if prev and prev.row == row and prev.col == col then
    return
  end
  if inflight[bufnr] then
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = true }

  local buf_uri = vim.uri_from_bufnr(bufnr)

  inflight[bufnr] = true
  local ok = pcall(
    vim.lsp.buf_request,
    bufnr,
    "textDocument/references",
    params,
    function(err, result)
      inflight[bufnr] = nil
      if err or not result then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      -- Drop stale responses: cursor moved off the position we queried.
      local cur_row, cur_col = cursor_rc()
      if cur_row ~= row or cur_col ~= col then
        return
      end
      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end

      local ranges, count = dedup_refs(result, buf_uri)

      clear_marks(bufnr)
      if count >= MIN_HIGHLIGHTED_REFS then
        paint_refs(bufnr, ranges)
      end

      state[bufnr] = { row = row, col = col, count = count }
      vim.cmd("redrawstatus")
    end
  )

  if not ok then
    inflight[bufnr] = nil
    state[bufnr] = nil
  end
end

-- True if (row, col) falls inside any extmark range in `ns` for this buffer.
local function cursor_on_mark(bufnr, row, col)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local sr, sc, det = m[2], m[3], m[4]
    local er, ec = det.end_row or sr, det.end_col or sc
    local after_start = row > sr or (row == sr and col >= sc)
    local before_end = row < er or (row == er and col < ec)
    if after_start and before_end then
      return true
    end
  end
  return false
end

local function invalidate_on_move()
  local bufnr = vim.api.nvim_get_current_buf()
  -- A moved cursor makes any pending request stale (its handler drops the
  -- result anyway), so release the in-flight guard for the next position.
  inflight[bufnr] = nil
  local s = state[bufnr]
  if not s then
    return
  end
  local row, col = cursor_rc()
  if s.row == row and s.col == col then
    return
  end
  -- Keep marks when jumping between references for the same symbol.
  if cursor_on_mark(bufnr, row, col) then
    return
  end
  state[bufnr] = nil
  clear_marks(bufnr)
  vim.cmd("redrawstatus")
end

-- Jump to the next/prev reference extmark in the current buffer. `dir` is 1
-- (forward) or -1 (backward). Wraps around the buffer ends.
local function jump(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  if #marks == 0 then
    return
  end

  table.sort(marks, function(a, b)
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[3] < b[3]
  end)

  local row, col = cursor_rc()
  local target
  if dir == 1 then
    for _, m in ipairs(marks) do
      if m[2] > row or (m[2] == row and m[3] > col) then
        target = m
        break
      end
    end
    target = target or marks[1]
  else
    for i = #marks, 1, -1 do
      local m = marks[i]
      if m[2] < row or (m[2] == row and m[3] < col) then
        target = m
        break
      end
    end
    target = target or marks[#marks]
  end

  vim.api.nvim_win_set_cursor(0, { target[2] + 1, target[3] })
end

function M.next()
  jump(1)
end
function M.prev()
  jump(-1)
end

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local s = state[bufnr]
  if not s or s.count < MIN_HIGHLIGHTED_REFS then
    return ""
  end
  local row, col = cursor_rc()
  if s.row ~= row or s.col ~= col then
    return ""
  end
  return string.format(" ⇄%d ", s.count)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("lsp_refs_status", { clear = true })

  ensure_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = ensure_highlight,
  })

  -- CursorHold only (not CursorHoldI): an idle pause while typing shouldn't
  -- fire a whole-project references scan.
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(args)
      request(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = invalidate_on_move,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    group = group,
    callback = function(args)
      state[args.buf] = nil
      inflight[args.buf] = nil
      clear_marks(args.buf)
    end,
  })

  _G.lsp_refs_status = M.status
end

return M
