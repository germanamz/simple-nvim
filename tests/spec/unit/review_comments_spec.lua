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

  -- The boundary the example above cannot see: an insert at exactly the
  -- comment's first line -- the everyday `O` above the line you just commented
  -- on. That insert sits at the start mark's own position, so only right
  -- gravity pushes the mark down; left gravity leaves the comment naming the
  -- line that was just inserted.
  it("moves down when a line is inserted directly above it", function()
    rc.push(buf, 3, 4, "boundary insert")
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "inserted" })
    local item = rc.resolve()[1]
    assert.are.equal(4, item.first)
    assert.are.equal(5, item.last)
  end)

  it("widens around a line inserted inside its range", function()
    rc.push(buf, 2, 3, "widens")
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "inserted" })
    local item = rc.resolve()[1]
    assert.are.equal(2, item.first)
    assert.are.equal(4, item.last)
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

-- The visual half of <leader>ac. Headless nvim will not type into a prompt, so
-- what this lane can prove is narrow: that the selection is read correctly, and
-- that the editor is out of visual mode by the time the prompt opens. It cannot
-- see the bug that motivated the last assertion -- the builtin vim.ui.input is
-- vim.fn.input(), which reads the typeahead buffer, so an <Esc> merely queued
-- by span() was drained by the prompt and cancelled it. A stubbed vim.ui.input
-- never touches typeahead, so only a real terminal shows the cancellation. That
-- was reproduced, and the fix confirmed, under a pty (one keypress per write).
describe("config.review_comments.add over a visual selection", function()
  local buf

  before_each(function()
    rc.clear()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/visual.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    -- Back to normal mode first: an example that failed mid-selection would
    -- otherwise hand the next one a visual mode it never asked for.
    pcall(vim.cmd, "normal! \27")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  --- Run `fn` with a linewise selection anchored on `from` and ending on `to`.
  --- The "x" flag matters: it executes the keys instead of queueing them, which
  --- is the only way a headless nvim reaches visual mode at all.
  local function with_visual(from, to, fn)
    vim.api.nvim_win_set_cursor(0, { from, 0 })
    local motion = to >= from and string.rep("j", to - from) or string.rep("k", from - to)
    vim.api.nvim_feedkeys("V" .. motion, "x", false)
    fn()
  end

  --- Run `fn` with vim.ui.input answering `answer`, recording the mode it was
  --- called in.
  local function with_input(answer, fn)
    local real, mode_at_prompt = vim.ui.input, nil
    vim.ui.input = function(_, cb)
      mode_at_prompt = vim.fn.mode()
      cb(answer)
    end
    local ok, err = pcall(fn)
    vim.ui.input = real
    if not ok then
      error(err)
    end
    return mode_at_prompt
  end

  it("queues the selection's span", function()
    with_input("needs a guard", function()
      with_visual(2, 3, rc.add)
    end)
    local item = rc.resolve()[1]
    assert.are.equal(2, item.first)
    assert.are.equal(3, item.last)
    assert.are.equal("needs a guard", item.text)
  end)

  it("orders a selection made bottom-up", function()
    with_input("upwards", function()
      with_visual(4, 2, rc.add)
    end)
    local item = rc.resolve()[1]
    assert.are.equal(2, item.first)
    assert.are.equal(4, item.last)
  end)

  it("collapses a one-line selection back to a single line", function()
    with_input("just this line", function()
      with_visual(3, 3, rc.add)
    end)
    local item = rc.resolve()[1]
    assert.are.equal(3, item.first)
    assert.is_nil(item.last)
  end)

  it("has left visual mode before the prompt opens", function()
    local mode_at_prompt = with_input("needs a guard", function()
      with_visual(2, 3, rc.add)
    end)
    assert.are.equal("n", mode_at_prompt)
  end)
end)

describe("config.review_comments.flush", function()
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

  --- Queue one comment on a fresh named buffer.
  local function queued(name)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/" .. name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one" })
    rc.push(buf, 1, nil, "look here")
  end

  --- Run `fn` with the `+` register saved and restored. The suite must not
  --- clobber the clipboard of whoever is running it.
  local function with_clipboard(fn)
    local saved = vim.fn.getreg("+")
    local ok, err = pcall(fn)
    vim.fn.setreg("+", saved)
    if not ok then
      error(err)
    end
    return ok
  end

  it("copies the payload to the clipboard and empties the queue", function()
    queued("sample.lua")
    local copied
    with_clipboard(function()
      rc.flush()
      copied = vim.fn.getreg("+")
    end)

    assert.is_truthy(copied:find("@sample.lua#L1", 1, true))
    assert.is_truthy(copied:find("look here", 1, true))
    assert.are.equal(0, rc.count())
  end)

  -- An empty flush must leave the clipboard alone: <leader>as pressed with
  -- nothing queued would otherwise silently destroy whatever you had yanked.
  it("leaves the clipboard untouched when nothing is queued", function()
    with_clipboard(function()
      vim.fn.setreg("+", "precious")
      rc.flush()
      assert.are.equal("precious", vim.fn.getreg("+"))
    end)
  end)
end)

describe("config.review_comments.discard", function()
  it("empties the queue and releases the extmarks", function()
    rc.clear()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/discardable.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    rc.push(buf, 1, nil, "a")
    rc.push(buf, 2, nil, "b")
    assert.are.equal(2, rc.count())

    rc.discard()

    assert.are.equal(0, rc.count())
    assert.is_nil(rc.payload())
    -- clear() deletes every mark it set, so the namespace is empty again.
    local ns = vim.api.nvim_get_namespaces()["review_comments"]
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

-- Jump has to survive the file having moved on: the agent edits while comments
-- sit in the queue, and an unloaded buffer resolves to the push-time snapshot,
-- which can name a line the file no longer has.
describe("config.review_comments.list", function()
  local bufs

  before_each(function()
    rc.clear()
    bufs = {}
  end)

  after_each(function()
    for _, b in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end)

  --- A named buffer of `n` lines, cleaned up by after_each.
  local function named(name, n)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/" .. name)
    local lines = {}
    for i = 1, n do
      lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    bufs[#bufs + 1] = buf
    return buf
  end

  --- Run `fn` with vim.ui.select taking the first comment, then `action`.
  local function with_select(action, fn)
    local real, n = vim.ui.select, 0
    vim.ui.select = function(items, _opts, cb)
      n = n + 1
      if n == 1 then
        cb(items[1], 1)
      else
        cb(action)
      end
    end
    local ok, err = pcall(fn)
    vim.ui.select = real
    if not ok then
      error(err)
    end
  end

  --- Run `fn` collecting vim.notify messages.
  local function with_notify(fn)
    local real, seen = vim.notify, {}
    vim.notify = function(msg)
      seen[#seen + 1] = msg
    end
    local ok, err = pcall(fn)
    vim.notify = real
    if not ok then
      error(err)
    end
    return seen
  end

  it("jumps to the commented line", function()
    local buf = named("jump.txt", 5)
    rc.push(buf, 4, nil, "tail")
    with_select("Jump", rc.list)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  -- The unloaded buffer has no extmark left, so the snapshot line 4 is all we
  -- have — and the reloaded buffer is shorter than that. Unclamped this raises
  -- "Invalid cursor line" out of a vim.ui.select callback.
  it("clamps the jump when the file no longer has that line", function()
    local buf = named("shrunk.txt", 5)
    rc.push(buf, 4, nil, "tail")
    vim.api.nvim_buf_delete(buf, { unload = true, force = true })
    with_select("Jump", rc.list)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("says so instead of doing nothing when the buffer is gone", function()
    local buf = named("wiped.txt", 5)
    rc.push(buf, 2, nil, "gone")
    vim.api.nvim_buf_delete(buf, { force = true })
    local seen = with_notify(function()
      with_select("Jump", rc.list)
    end)
    assert.is_truthy(table.concat(seen, "\n"):find("wiped.txt", 1, true))
  end)

  it("drops the chosen comment", function()
    local buf = named("drop.txt", 3)
    rc.push(buf, 1, nil, "a")
    with_notify(function()
      with_select("Drop", rc.list)
    end)
    assert.are.equal(0, rc.count())
  end)
end)
