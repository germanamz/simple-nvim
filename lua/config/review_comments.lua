-- Review comments queued in Neovim and handed to the coding agent running in
-- the next cmux pane, each carrying the `@path#L39-41` the comment is about.
--
-- The queue is memory-only and dies with the session: a comment is a thing you
-- are about to say, not a document. Nothing here writes to disk.
--
-- Ranges are anchored on extmarks rather than stored as plain numbers. A review
-- is not read-only -- you fix things as you go -- so a comment queued before an
-- edit above it would otherwise name the wrong lines by flush time. The plain
-- numbers are kept as the fallback for a buffer that has since been unloaded,
-- where there is no mark left to read.
local file_reference = require("config.file_reference")

local M = {}

local ns = vim.api.nvim_create_namespace("review_comments")

---@class ReviewComment
---@field file string root-relative path, resolved once at push time
---@field bufnr integer
---@field mark integer|nil extmark id, nil when the buffer would not take one
---@field first integer 1-indexed snapshot, the fallback
---@field last integer|nil
---@field text string

---@type ReviewComment[]
local queue = {}

--- Queue a comment on `buf` covering lines `first`..`last` (1-indexed, `last`
--- nil for a single line). False when the buffer has no file behind it, since
--- there would be nothing to point the agent at.
---@param buf integer
---@param first integer
---@param last integer|nil
---@param text string
---@return boolean
function M.push(buf, first, last, text)
  local file = file_reference.relpath(buf)
  if not file then
    return false
  end
  -- end_row is exclusive-ish here: mark the whole last line so an insert INSIDE
  -- the range widens it rather than being clipped.
  local ok, mark = pcall(vim.api.nvim_buf_set_extmark, buf, ns, first - 1, 0, {
    end_row = (last or first) - 1,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  queue[#queue + 1] = {
    file = file,
    bufnr = buf,
    mark = ok and mark or nil,
    first = first,
    last = last,
    text = text,
  }
  return true
end

--- Current line numbers for `c` -- from its extmark when the buffer is still
--- loaded, else the snapshot taken at push time.
---@param c ReviewComment
---@return integer first, integer|nil last
local function range(c)
  if not (c.mark and vim.api.nvim_buf_is_loaded(c.bufnr)) then
    return c.first, c.last
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, c.bufnr, ns, c.mark, { details = true })
  if not (ok and pos and pos[1]) then
    return c.first, c.last
  end
  local first = pos[1] + 1
  -- A single-line comment stays single-line: only report an end when one was
  -- asked for, so the formatter keeps emitting `#L5` rather than `#L5-5`.
  local last = c.last and pos[3] and pos[3].end_row and (pos[3].end_row + 1) or nil
  return first, last
end

--- The queue as plain records with current line numbers, ready to format.
---@return table[]
function M.resolve()
  local out = {}
  for i, c in ipairs(queue) do
    local first, last = range(c)
    out[i] = { file = c.file, first = first, last = last, text = c.text }
  end
  return out
end

---@return integer
function M.count()
  return #queue
end

---@param index integer
function M.drop(index)
  table.remove(queue, index)
end

function M.clear()
  for _, c in ipairs(queue) do
    if c.mark and vim.api.nvim_buf_is_loaded(c.bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, c.bufnr, ns, c.mark)
    end
  end
  queue = {}
end

--- Test seam: the raw queue, for specs that need to inspect marks.
---@return ReviewComment[]
function M._queue()
  return queue
end

return M
