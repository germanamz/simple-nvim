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

-- The `@path#L39-41` spelling is not cosmetic: it is exactly what Claude's own
-- at_mentioned handler emits into the prompt box, so a pasted or typed payload
-- resolves as a real file mention rather than being read as prose. Single `L`,
-- hyphen range, one number when the range is one line.
describe("config.review_comments.format", function()
  it("numbers each comment and uses the at-mention spelling", function()
    local text = rc.format({
      { file = "lua/config/lsp.lua", first = 39, last = 41, text = "use util.git.buf_root" },
      { file = "init.lua", first = 5, text = "stale comment" },
    })
    assert.are.equal(
      table.concat({
        "Review comments (2):",
        "",
        "1. @lua/config/lsp.lua#L39-41",
        "   use util.git.buf_root",
        "",
        "2. @init.lua#L5",
        "   stale comment",
      }, "\n"),
      text
    )
  end)

  it("indents every line of a multi-line comment", function()
    local text = rc.format({ { file = "a.lua", first = 1, text = "first\nsecond" } })
    assert.is_truthy(text:find("\n   first\n   second", 1, true))
  end)

  it("collapses a range that resolved to a single line", function()
    local text = rc.format({ { file = "a.lua", first = 7, last = 7, text = "x" } })
    assert.is_truthy(text:find("@a.lua#L7", 1, true))
    assert.is_nil(text:find("#L7-7", 1, true))
  end)

  it("has no payload for an empty queue", function()
    rc.clear()
    assert.is_nil(rc.payload())
  end)
end)

describe("config.review_comments.add", function()
  local buf

  before_each(function()
    rc.clear()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sample.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  end)

  -- Same fixed name as the block above, so this buffer has to go before the
  -- next example names one the same way — nvim_buf_set_name is E95 on a live
  -- duplicate.
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  --- Run `fn` with vim.ui.input answering `answer`.
  local function with_input(answer, fn)
    local real = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(answer)
    end
    local ok, err = pcall(fn)
    vim.ui.input = real
    if not ok then
      error(err)
    end
  end

  it("queues the cursor line with the typed text", function()
    with_input("needs a guard", rc.add)
    local item = rc.resolve()[1]
    assert.are.equal(2, item.first)
    assert.is_nil(item.last)
    assert.are.equal("needs a guard", item.text)
  end)

  it("queues nothing when the prompt is cancelled", function()
    with_input(nil, rc.add)
    assert.are.equal(0, rc.count())
  end)

  it("queues nothing for an empty comment", function()
    with_input("   ", rc.add)
    assert.are.equal(0, rc.count())
  end)
end)

describe("config.review_comments.flush", function()
  local sinks = require("config.review_sinks")
  local buf

  before_each(function()
    rc.clear()
  end)

  -- Same fixed name as the block above, so this buffer has to go before the
  -- next example names one the same way — nvim_buf_set_name is E95 on a live
  -- duplicate.
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("sends the payload through the chosen sink and empties the queue", function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sample.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one" })
    rc.push(buf, 1, nil, "look here")

    local sent
    local real = sinks.send
    sinks.send = function(_name, text, _opts, on_done)
      sent = text
      on_done(true, nil)
    end
    rc.flush({ submit = false })
    sinks.send = real

    assert.is_truthy(sent:find("@sample.lua#L1", 1, true))
    assert.are.equal(0, rc.count())
  end)

  it("keeps the queue when the sink fails", function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sample.lua")
    rc.push(buf, 1, nil, "look here")

    local real = sinks.send
    sinks.send = function(_name, _text, _opts, on_done)
      on_done(false, "boom")
    end
    rc.flush({})
    sinks.send = real

    assert.are.equal(1, rc.count())
  end)
end)
