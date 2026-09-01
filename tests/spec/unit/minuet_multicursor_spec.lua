-- config.minuet_multicursor makes an accepted AI suggestion reach every cursor.
--
-- minuet's `action.accept` inserts with `nvim_buf_set_text` (virtualtext.lua:393).
-- multicursor replays an insert at the other cursors by feeding `.` — the redo
-- record — and an API edit never enters it, so the suggestion lands at the main
-- cursor only. The module re-expresses that same insertion as `nvim_paste`,
-- which is the one insertion primitive that writes the redo record.
--
-- Unit init loads no plugins, so minuet and multicursor are stubbed through
-- package.loaded. Headless CANNOT enter insert mode through typeahead, but an
-- insert-mode Lua keymap driven by `nvim_feedkeys(keys, "mx")` DOES run its
-- callback with `mode() == "i"` — which is what makes the insert-mode-only
-- behaviour of `vim.paste` testable here at all. `insert_call` below is that
-- trick; every spec that cares about mode goes through it.
local mm = require("config.minuet_multicursor")

local function keys(s)
  return vim.api.nvim_replace_termcodes(s, true, true, true)
end

-- Run `fn` with the editor genuinely in `mode` ("i" or "R"), at row/col of the
-- current buffer, and leave insert afterwards.
local function insert_call(enter, row, col, fn)
  vim.api.nvim_win_set_cursor(0, { row, col })
  vim.keymap.set("i", "<F13>", fn)
  vim.api.nvim_feedkeys(keys(enter .. "<F13><Esc>"), "mx", false)
  vim.keymap.del("i", "<F13>")
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe("config.minuet_multicursor", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  ret", "  ret" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    package.loaded["multicursor-nvim"] = nil
    package.loaded["minuet.virtualtext"] = nil
  end)

  after_each(function()
    package.loaded["multicursor-nvim"] = nil
    package.loaded["minuet.virtualtext"] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  -- Pretend to be multicursor. `numEnabledCursors` is multicursor's own public
  -- counter (init.lua:39) and is always >= 1 — 1 means "just the main cursor".
  local function stub_cursors(n)
    package.loaded["multicursor-nvim"] = {
      numEnabledCursors = function()
        return n
      end,
    }
  end

  -- Pretend to be minuet: insert `text` at the cursor exactly the way
  -- virtualtext.lua:392-401 does — deferred, by API, then move the cursor to
  -- the end of what was written.
  local function stub_minuet(text)
    local action = {}
    action.accept = function(n_lines)
      local suggestions = vim.split(text, "\n")
      if n_lines then
        suggestions = vim.list_slice(suggestions, 1, math.min(n_lines, #suggestions))
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      local line, col = cursor[1] - 1, cursor[2]
      vim.schedule(function()
        vim.api.nvim_buf_set_text(0, line, col, line, col, suggestions)
        local new_col = #suggestions[#suggestions]
        if #suggestions == 1 then
          new_col = new_col + col
        end
        vim.api.nvim_win_set_cursor(0, { line + #suggestions, new_col })
      end)
    end
    action.accept_line = function()
      action.accept(1)
    end
    package.loaded["minuet.virtualtext"] = { action = action, ns_id = 1 }
    return action
  end

  -- Drive one accept end to end. Both minuet's deferred edit and the module's
  -- rewrite are drained from INSIDE the mapping, because that is the only way
  -- they run with `mode() == "i"` — `nvim_feedkeys(..., "x")` has already left
  -- insert by the time it returns, and the rewrite refuses any other mode.
  -- This mirrors the real editor, where the user has not yet pressed `<Esc>`.
  local function accept_in_insert(action, n_lines, row, col)
    vim.keymap.set("i", "<F13>", function()
      action.accept(n_lines)
      vim.wait(200, function()
        return false
      end, 10)
    end)
    vim.api.nvim_win_set_cursor(0, { row or 1, col or 4 })
    vim.api.nvim_feedkeys(keys("a<F13><Esc>"), "mx", false)
    vim.keymap.del("i", "<F13>")
  end

  ---------------------------------------------------------------------------
  -- The bug itself, pinned as a property of the two primitives. If either of
  -- these flips, the whole design is void.
  ---------------------------------------------------------------------------
  describe("the primitives this fix rests on", function()
    it("nvim_buf_set_text in insert mode leaves the redo record empty", function()
      insert_call("a", 1, 4, function()
        local c = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_buf_set_text(0, c[1] - 1, c[2], c[1] - 1, c[2], { "urn a - b" })
      end)
      assert.are.same({ "  return a - b", "  ret" }, lines())

      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      pcall(vim.cmd, "normal! .")
      -- Unchanged: dot-repeat had nothing to replay. This is the reported bug.
      assert.are.same({ "  return a - b", "  ret" }, lines())
    end)

    it("nvim_paste in insert mode DOES write the redo record", function()
      insert_call("a", 1, 4, function()
        vim.api.nvim_paste("urn a - b", false, -1)
      end)
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      vim.cmd("normal! .")
      assert.are.same({ "  return a - b", "  return a - b" }, lines())
    end)

    -- Byte-equivalence is what licenses swapping one primitive for the other,
    -- and it holds ONLY in insert mode — see the mode specs below.
    it("nvim_paste and nvim_buf_set_text agree in insert mode, for every shape", function()
      for _, text in ipairs({ "ZZ", "P1\nP2", "\nfoo", "foo\n", "", "foo(bar", 'a"$x' }) do
        local function run(fn)
          vim.api.nvim_buf_set_lines(0, 0, -1, false, { "HELLOWORLD" })
          insert_call("a", 1, 5, fn)
          return lines(), vim.api.nvim_win_get_cursor(0)
        end
        local pasted = run(function()
          vim.api.nvim_paste(text, false, -1)
        end)
        local set = run(function()
          local c = vim.api.nvim_win_get_cursor(0)
          vim.api.nvim_buf_set_text(0, c[1] - 1, c[2], c[1] - 1, c[2], vim.split(text, "\n"))
        end)
        assert.are.same(set, pasted, "diverged for " .. vim.inspect(text))
      end
    end)

    -- The reason the module refuses anything but plain insert mode: vim.paste
    -- dispatches on mode, and its other two branches do not insert, they
    -- overwrite (Replace) or land one column right (normal).
    it("nvim_paste and nvim_buf_set_text DISAGREE in replace mode", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "HELLOWORLD" })
      insert_call("R", 1, 5, function()
        vim.api.nvim_paste("ZZZ", false, -1)
      end)
      assert.are.same({ "HELLOZZZLD" }, lines())

      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "HELLOWORLD" })
      insert_call("R", 1, 5, function()
        local c = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_buf_set_text(0, c[1] - 1, c[2], c[1] - 1, c[2], { "ZZZ" })
      end)
      assert.are.same({ "HELLOZZZWORLD" }, lines())
    end)
  end)

  ---------------------------------------------------------------------------
  -- measure(): read back exactly what minuet inserted, from the buffer delta.
  ---------------------------------------------------------------------------
  describe("measure", function()
    local shapes = {
      { "urn a - b", { "  returna - b" } },
      { "urn {\n    a - b,\n  }", nil },
      { "\nnext", nil },
      { "trailing\n", nil },
      { "", nil },
      { "ünïcødé", nil },
    }

    for _, shape in ipairs(shapes) do
      local text = shape[1]
      it("recovers " .. vim.inspect(text), function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "  ret", "  ret" })
        vim.api.nvim_win_set_cursor(0, { 1, 4 })
        local pre = mm.snapshot()
        vim.api.nvim_buf_set_text(0, 0, 4, 0, 4, vim.split(text, "\n"))
        assert.are.equal(text, mm.measure(pre))
      end)
    end

    it("refuses when the buffer did not move", function()
      local pre = mm.snapshot()
      assert.is_nil(mm.measure(pre))
    end)

    it("refuses when the buffer moved more than once", function()
      local pre = mm.snapshot()
      vim.api.nvim_buf_set_text(0, 0, 4, 0, 4, { "urn" })
      vim.api.nvim_buf_set_text(0, 0, 7, 0, 7, { " x" })
      assert.is_nil(mm.measure(pre))
    end)

    it("refuses when the text after the cursor no longer matches", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "  ret tail", "  ret" })
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      local pre = mm.snapshot()
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "  returned OTHER" })
      assert.is_nil(mm.measure(pre))
    end)

    it("refuses when another buffer became current", function()
      local pre = mm.snapshot()
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(other)
      assert.is_nil(mm.measure(pre))
      vim.api.nvim_buf_delete(other, { force = true })
    end)
  end)

  ---------------------------------------------------------------------------
  -- install(): the same posture as config.minuet_guard.
  ---------------------------------------------------------------------------
  describe("install", function()
    it("returns false when minuet's accept is not there to wrap", function()
      package.loaded["minuet.virtualtext"] = { action = {} }
      assert.is_false(mm.install())
    end)

    it("wraps accept and reports success", function()
      local action = stub_minuet("x")
      local original = action.accept
      assert.is_true(mm.install())
      assert.are_not.equal(original, package.loaded["minuet.virtualtext"].action.accept)
    end)

    -- Re-running the plugin's config() (`:Lazy reload minuet-ai.nvim`) must not
    -- stack a second wrapper, and must NOT report failure — lua/plugins/minuet.lua
    -- warns on false, and "already installed" is a success, not a fault.
    it("is idempotent and still reports success on a second call", function()
      stub_minuet("x")
      assert.is_true(mm.install())
      local wrapped = package.loaded["minuet.virtualtext"].action.accept
      assert.is_true(mm.install())
      assert.are.equal(wrapped, package.loaded["minuet.virtualtext"].action.accept)
    end)
  end)

  ---------------------------------------------------------------------------
  -- The whole point: with cursors alive, an accept becomes dot-repeatable.
  ---------------------------------------------------------------------------
  describe("the wrapped accept", function()
    it("leaves the single-cursor path byte-identical to upstream", function()
      stub_cursors(1)
      local action = stub_minuet("urn a - b")
      mm.install()
      accept_in_insert(action)
      assert.are.same({ "  return a - b", "  ret" }, lines())
      -- Untouched upstream behaviour means the redo record is still empty, so
      -- this stays the plain API insert it always was.
      assert.are.equal("", mm.last_rewrite_text or "")
    end)

    it("makes the accept dot-repeatable when cursors are alive", function()
      stub_cursors(3)
      local action = stub_minuet("urn a - b")
      mm.install()
      accept_in_insert(action)
      assert.are.same({ "  return a - b", "  ret" }, lines())

      -- multicursor replays at the other cursors with `.`; that is the exact
      -- call this has to survive (input-manager.lua:188).
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      vim.cmd("normal! .")
      assert.are.same({ "  return a - b", "  return a - b" }, lines())
    end)

    it("carries a multi-line suggestion, indentation intact", function()
      stub_cursors(2)
      local action = stub_minuet("urn {\n    a - b,\n  }")
      mm.install()
      accept_in_insert(action)
      assert.are.same({ "  return {", "    a - b,", "  }", "  ret" }, lines())

      vim.api.nvim_win_set_cursor(0, { 4, 4 })
      vim.cmd("normal! .")
      assert.are.same({
        "  return {",
        "    a - b,",
        "  }",
        "  return {",
        "    a - b,",
        "  }",
      }, lines())
    end)

    it("carries unbalanced and $-bearing text verbatim", function()
      stub_cursors(2)
      local action = stub_minuet('urn foo(bar, "$x')
      mm.install()
      accept_in_insert(action)
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      vim.cmd("normal! .")
      assert.are.same({ '  return foo(bar, "$x', '  return foo(bar, "$x' }, lines())
    end)

    it("routes accept_line (<C-l>) through the same wrapper", function()
      stub_cursors(2)
      local action = stub_minuet("urn {\n    a - b,\n  }")
      mm.install()
      vim.keymap.set("i", "<F13>", function()
        action.accept_line()
        vim.wait(200, function()
          return false
        end, 10)
      end)
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      vim.api.nvim_feedkeys(keys("a<F13><Esc>"), "mx", false)
      vim.keymap.del("i", "<F13>")
      assert.are.same({ "  return {", "  ret" }, lines())
      vim.api.nvim_win_set_cursor(0, { 2, 4 })
      vim.cmd("normal! .")
      assert.are.same({ "  return {", "  return {" }, lines())
    end)
  end)
end)
