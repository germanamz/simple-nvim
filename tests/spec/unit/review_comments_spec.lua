-- Pins the in-memory queue behind <leader>ac. The interesting behavior is that
-- a comment's line range follows edits made above it: a review is not read-only,
-- and a snapshot line number would silently name the wrong code by the time the
-- batch is flushed. Extmarks are the anchor; the snapshot is only the fallback
-- for a buffer that has been unloaded.
local rc = require("config.review_comments")

describe("config.review_comments queue", function()
  local buf

  before_each(function()
    rc.clear()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sample.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "one",
      "two",
      "three",
      "four",
      "five",
    })
  end)

  -- The buffer carries a fixed name, so it has to go before the next example
  -- names one the same way — nvim_buf_set_name is E95 on a live duplicate.
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("queues a comment and reports its range", function()
    assert.is_true(rc.push(buf, 2, 3, "needs a guard"))
    local items = rc.resolve()
    assert.are.equal(1, #items)
    assert.are.equal("sample.lua", items[1].file)
    assert.are.equal(2, items[1].first)
    assert.are.equal(3, items[1].last)
    assert.are.equal("needs a guard", items[1].text)
  end)

  it("leaves last nil for a single-line comment", function()
    rc.push(buf, 2, nil, "one-liner")
    assert.is_nil(rc.resolve()[1].last)
  end)

  it("follows lines inserted above the comment", function()
    rc.push(buf, 3, 4, "moves down")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new", "new" })
    local item = rc.resolve()[1]
    assert.are.equal(5, item.first)
    assert.are.equal(6, item.last)
  end)

  it("refuses a buffer with no file", function()
    assert.is_false(rc.push(vim.api.nvim_create_buf(false, true), 1, nil, "nope"))
    assert.are.equal(0, rc.count())
  end)

  it("drops one comment and clears the rest", function()
    rc.push(buf, 1, nil, "a")
    rc.push(buf, 2, nil, "b")
    rc.drop(1)
    assert.are.equal(1, rc.count())
    assert.are.equal("b", rc.resolve()[1].text)
    rc.clear()
    assert.are.equal(0, rc.count())
  end)
end)
