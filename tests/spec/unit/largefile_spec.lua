-- Pins util.largefile.is_large, the single threshold shared by the treesitter
-- highlight guard, treesitter-context, gitsigns new-vs-base painting, and
-- format-on-save. Behavior must stay identical across all four consumers.
local largefile = require("util.largefile")

local function buf_with_lines(n, fill)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n do
    lines[i] = fill or ("line " .. i)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("util.largefile.is_large", function()
  it("is false for a small buffer", function()
    local buf = buf_with_lines(10)
    assert.is_false(largefile.is_large(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is true past the line bound", function()
    local buf = buf_with_lines(largefile.MAX_LINES + 1)
    assert.is_true(largefile.is_large(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is false exactly at the line bound", function()
    local buf = buf_with_lines(largefile.MAX_LINES)
    assert.is_false(largefile.is_large(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is true for a few-line buffer that exceeds the byte bound", function()
    -- A single huge line: line count stays tiny, bytes blow past the cap —
    -- the minified-asset case the line check alone would miss.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", largefile.MAX_BYTES + 1) })
    assert.is_true(largefile.is_large(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is false for an invalid buffer handle", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(largefile.is_large(buf))
  end)
end)
