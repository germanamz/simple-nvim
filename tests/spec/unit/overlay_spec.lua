-- Pins the minimal floating-window handle extracted from the byte-identical
-- legend teardown in review_base and telescope_smart.
local Overlay = require("util.overlay")

describe("util.overlay", function()
  local function scratch(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    return buf
  end
  local function float_config()
    return {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 1,
      style = "minimal",
      focusable = false,
      noautocmd = true,
    }
  end

  it("starts with no window or buffer", function()
    local o = Overlay.new()
    assert.is_nil(o.win)
    assert.is_nil(o.buf)
  end)

  it("closing a fresh overlay is a no-op", function()
    local o = Overlay.new()
    assert.has_no.errors(function()
      o:close()
    end)
  end)

  it("mounts a window over a buffer and tears both down on close", function()
    local o = Overlay.new()
    local buf = scratch("hi")
    local win = o:mount(buf, float_config())
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.are.equal(buf, o.buf)
    o:close()
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_nil(o.win)
    assert.is_nil(o.buf)
  end)

  it("replaces a previous mount, closing the old window", function()
    local o = Overlay.new()
    local win1 = o:mount(scratch("a"), float_config())
    local win2 = o:mount(scratch("b"), float_config())
    assert.is_false(vim.api.nvim_win_is_valid(win1))
    assert.is_true(vim.api.nvim_win_is_valid(win2))
    o:close()
  end)
end)
