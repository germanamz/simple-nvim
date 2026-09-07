local nvim_env = require("tests.helpers.nvim_env")
local peek = require("config.long_line_peek")

-- config.long_line_peek unfolds a too-wide line in place: a borderless float
-- over the cursor line showing the same buffer with 'wrap' on, plus a
-- `virt_lines` spacer of (height - 1) blank rows so the code below is pushed
-- down by exactly what the float covers.
--
-- What this lane can and cannot see. The window/extmark APIs are authoritative
-- here, so geometry, the spacer and the untouched parent view are all pinned
-- below. The rendered screen is NOT: headless composites a `relative = "win"`
-- float at the screen origin rather than at its configured row/col, so
-- screenstring() "shows" the peek covering the top of the window while
-- nvim_win_get_config reports the correct position. The visual result was
-- verified separately in a real PTY -- do not add screenstring assertions here,
-- they pin the artifact rather than the feature.
describe("e2e: long_line_peek", function()
  local root, prev_cwd, buf, prev_lines

  -- Wide enough to clip in any plausible headless window, and long enough to
  -- need several wrapped rows once the peek opens.
  local LONG = "local result = " .. string.rep("segment_", 30) .. "END"
  local SHORT = "local x = 1"

  local function floats()
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        out[#out + 1] = win
      end
    end
    return out
  end

  local function spacer_marks()
    local ns = vim.api.nvim_get_namespaces()["long_line_peek"]
    if not ns then
      return {}
    end
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    prev_lines = vim.o.lines
    -- Headless windows are ~43 rows; the peek's geometry is bounded by the rows
    -- below the cursor, so pin a predictable height instead of inheriting one.
    vim.o.lines = 24
    -- A listed, non-scratch buffer: buftype must be "" for the feature to
    -- consider it a real file. Created through the API rather than :edit so the
    -- isolated env's stale lsp.log path is never touched.
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "first",
      "second",
      LONG,
      "fourth",
      "fifth",
      SHORT,
    })
    vim.api.nvim_win_set_buf(0, buf)
  end)

  after_each(function()
    peek._close()
    vim.o.lines = prev_lines
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("registers its autocmds and highlight at startup", function()
    -- init.lua calls setup(); the real config is loaded in this lane.
    assert.is_true(peek._did_setup)
    local autocmds = vim.api.nvim_get_autocmds({ group = "long_line_peek" })
    assert.is_true(#autocmds > 0)
    local events = {}
    for _, a in ipairs(autocmds) do
      events[a.event] = true
    end
    assert.is_true(events.CursorMoved, "CursorMoved must rearm the dwell timer")
    assert.is_true(events.WinScrolled, "a horizontal scroll changes what is clipped")
    assert.is_true(events.ColorScheme, "the peek background is derived, not linked")
    assert.is_not_nil(vim.api.nvim_get_hl(0, { name = "LongLinePeek" }).bg)
  end)

  it("opens a float taller than one row over a clipped line", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()

    local open = floats()
    assert.are.equal(1, #open, "exactly one peek float")
    local cfg = vim.api.nvim_win_get_config(open[1])
    assert.are.equal("win", cfg.relative)
    assert.is_true(cfg.height >= 2, "a one-row peek would reveal nothing")

    -- The float shows the real buffer, which is where the free treesitter /
    -- semantic-token / diagnostic highlighting comes from.
    assert.are.equal(buf, vim.api.nvim_win_get_buf(open[1]))
    assert.is_true(vim.wo[open[1]].wrap, "a float inherits 'nowrap' and must override it")
    assert.is_false(cfg.focusable, "the peek must never steal the cursor")
  end)

  it("aligns the float with the parent's text column and the cursor's row", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    local expected_row = vim.fn.winline() - 1
    peek._open()

    local cfg = vim.api.nvim_win_get_config(floats()[1])
    assert.are.equal(wi.textoff, cfg.col, "float text must sit in the parent's text column")
    assert.are.equal(expected_row, cfg.row, "row 0 is the first text row")
    assert.are.equal(wi.width - wi.textoff, cfg.width)
  end)

  it("pushes the following code down by exactly what the float covers", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()

    local cfg = vim.api.nvim_win_get_config(floats()[1])
    local marks = spacer_marks()
    assert.are.equal(1, #marks, "one spacer extmark")
    assert.are.equal(2, marks[1][2], "anchored on the peeked line (0-indexed)")
    assert.are.equal(
      cfg.height - 1,
      #marks[1][4].virt_lines,
      "the float's first row sits on a real buffer row, so the spacer is one shorter"
    )
  end)

  it("leaves the parent's view byte-identical", function()
    -- Deliberately NOT column 0: there every field a relocation bug would
    -- corrupt (col, curswant) is already at its zero value, so the comparison
    -- passes even if the peek resets the cursor. Column 40 is still inside the
    -- first screenful, so leftcol stays 0 and the peek is allowed to fire.
    vim.api.nvim_win_set_cursor(0, { 3, 40 })
    vim.cmd("redraw")
    local before = vim.fn.winsaveview()
    assert.are.equal(40, before.col, "test setup: the cursor must be off column 0")
    assert.are.equal(0, before.leftcol, "test setup: the window must not be scrolled")

    peek._open()
    assert.are.equal(1, #floats(), "test setup: the peek must actually be open")
    assert.is_true(vim.deep_equal(before, vim.fn.winsaveview()), "view changed while peeking")
    peek._close()
    assert.is_true(vim.deep_equal(before, vim.fn.winsaveview()), "view changed on teardown")
  end)

  it("sizes the float to hold the whole line, not merely more than one row", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    local textw = wi.width - wi.textoff
    local line_width = vim.fn.virtcol({ 3, "$" }) - 1
    peek._open()

    local fl = floats()[1]
    -- A floor of >= 2 would pass while the peek showed a quarter of the line.
    assert.are.equal(math.ceil(line_width / textw), vim.api.nvim_win_get_config(fl).height)
    assert.are.equal(3, vim.fn.getwininfo(fl)[1].topline, "the float must be parked on the line")
  end)

  it("ignores a line that already fits the window", function()
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    peek._open()
    assert.are.equal(0, #floats())
    assert.are.equal(0, #spacer_marks())
  end)

  it("closes the float and clears the spacer, keeping the buffer alive", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()
    assert.are.equal(1, #floats())

    peek._close()
    assert.are.equal(0, #floats())
    assert.are.equal(0, #spacer_marks())
    -- The float mounts the user's real buffer; tearing it down must never take
    -- the buffer with it (which is why util.overlay is not reused here).
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal(LONG, vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
  end)

  it("is idempotent: a second open while one is up changes nothing", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()
    local first = floats()[1]
    peek._open()
    assert.are.equal(1, #floats())
    assert.are.equal(first, floats()[1])
    assert.are.equal(1, #spacer_marks())
  end)

  it("folds the peek away when the dwell timer is rearmed", function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()
    assert.are.equal(1, #floats())

    -- What every CursorMoved / WinScrolled / mode change routes through.
    peek._rearm()
    assert.are.equal(0, #floats(), "moving must fold the peek immediately")
    assert.are.equal(0, #spacer_marks())
  end)

  describe("guards", function()
    it("ignores a window that is already soft-wrapping", function()
      -- A wrapped window clips nothing, and winline() there is the cursor's
      -- continuation row, so the float would anchor mid-line and paint the line
      -- a second time.
      vim.wo[0].wrap = true
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      peek._open()
      assert.are.equal(0, #floats())
      assert.are.equal(0, #spacer_marks())
      vim.wo[0].wrap = false
    end)

    it("ignores a line inside a closed fold", function()
      -- virt_lines on a folded line are silently not drawn, so the spacer would
      -- never appear and the float would cover real code below.
      vim.wo[0].foldmethod = "manual"
      vim.cmd("3,4fold")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      assert.are_not.equal(-1, vim.fn.foldclosed(3), "test setup: line 3 must be folded")

      peek._open()
      assert.are.equal(0, #floats())
      assert.are.equal(0, #spacer_marks())
      vim.cmd("normal! zE")
    end)

    it("ignores a horizontally scrolled window", function()
      -- The float renders from column 0 while the parent draws the cursor at
      -- (virtcol - leftcol), so the cursor block would sit on an unrelated
      -- character and a truncated peek could hide the segment being read.
      vim.api.nvim_win_set_cursor(0, { 3, #LONG - 1 })
      vim.cmd("redraw")
      assert.is_true(vim.fn.winsaveview().leftcol > 0, "test setup: window must be scrolled")

      peek._open()
      assert.are.equal(0, #floats())
      assert.are.equal(0, #spacer_marks())
    end)
  end)

  -- Everything above drives the impure shell directly. These two pin the path
  -- an actual session takes: current_ctx() reading live editor state, and the
  -- uv timer firing on its own.
  describe("the dwell path", function()
    -- With no UI attached, state() spuriously reports "o" (operator pending) and
    -- "S" even at idle, so the real eligible() refuses in this lane. A real
    -- session reports "" -- verified in a PTY, where the peek does open on its
    -- own after the dwell. These tests therefore stub eligible() to isolate the
    -- wiring, and pin the field spellings separately.
    local function with_eligible(fn)
      local prev_delay, prev_eligible = peek.DELAY_MS, peek.eligible
      local seen
      peek.DELAY_MS = 20
      peek.eligible = function(ctx)
        seen = ctx
        return true
      end
      local ok, err = pcall(fn, function()
        return seen
      end)
      peek.DELAY_MS, peek.eligible = prev_delay, prev_eligible
      if not ok then
        error(err)
      end
    end

    it("builds its context from live editor state, with the right field spellings", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local ctx = peek._ctx()
      -- mode(1), not mode(): the short form collapses operator-pending "no" to
      -- "n", which would let the peek pop mid-`d`/`c`.
      assert.are.equal("n", ctx.mode)
      -- state("mo"), not state(): the unfiltered call also reports "S" ("not
      -- triggering SafeState") and "s", neither of which should block a peek.
      -- Asserting the letter set catches that regression even in this lane,
      -- where "o" is a headless artifact.
      assert.is_nil(ctx.state:match("[^mo]"), 'state must be filtered to "mo", got: ' .. ctx.state)
      assert.are.equal("", ctx.buftype)
      assert.are.equal("", ctx.relative)
      assert.is_false(ctx.large)
      assert.is_boolean(ctx.pumvisible)
    end)

    it("opens by itself once the dwell elapses, with no keypress", function()
      with_eligible(function(seen)
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        peek._rearm()

        assert.is_true(
          vim.wait(2000, function()
            return #floats() > 0
          end, 10),
          "the dwell timer never opened a peek"
        )
        assert.are.equal(1, #spacer_marks())
        -- The timer must go through current_ctx(), not open() directly.
        assert.is_table(seen(), "eligible() was never handed a live context")
        assert.are.equal("n", seen().mode)
      end)
    end)

    it("does not fire the timer on a line that already fits", function()
      with_eligible(function()
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        peek._rearm()

        assert.is_false(
          vim.wait(300, function()
            return #floats() > 0
          end, 10),
          "a short line must never open a peek"
        )
      end)
    end)

    it("does not reopen after a rearm until a fresh dwell elapses", function()
      -- Once a peek has opened, the rearm that folds it must leave nothing
      -- behind that can reopen it -- neither a timer body vim.schedule_wrap has
      -- already queued (timer:stop() cannot recall one; the generation token
      -- retires it) nor a duplicate timer. Lengthening the dwell before the
      -- second rearm is what makes this deterministic: any peek appearing inside
      -- the wait window must have come from the retired dwell, not a new one.
      with_eligible(function()
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        peek._rearm()
        assert.is_true(
          vim.wait(2000, function()
            return #floats() > 0
          end, 10),
          "setup: the first dwell never opened a peek"
        )

        peek.DELAY_MS = 60000
        peek._rearm()
        assert.are.equal(0, #floats(), "the rearm must fold the open peek")
        assert.is_false(
          vim.wait(300, function()
            return #floats() > 0
          end, 10),
          "a retired dwell reopened the peek"
        )
      end)
    end)
  end)

  it("recovers when the float is closed from outside", function()
    -- <C-w>o, :fclose! and any "close all floating windows" mapping take the
    -- float without firing anything in the rearm list. Left alone that strands
    -- the spacer's blank rows and wedges `active` so no peek can ever open
    -- again. The SafeState validator is what heals it.
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()
    assert.are.equal(1, #spacer_marks())

    vim.api.nvim_win_close(floats()[1], true)
    assert.are.equal(1, #spacer_marks(), "precondition: the spacer outlives the float")

    vim.api.nvim_exec_autocmds("SafeState", {})
    assert.are.equal(0, #spacer_marks(), "orphaned spacer rows must be cleared")

    -- And the feature is not wedged: a fresh peek still opens.
    peek._open()
    assert.are.equal(1, #floats())
  end)

  it("folds the peek when a fold closes above it without moving the cursor", function()
    vim.wo[0].foldmethod = "manual"
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()
    assert.are.equal(1, #floats())

    -- zc on lines above shifts the cursor line's screen row while firing none of
    -- the rearm events.
    vim.cmd("1,2fold")
    vim.api.nvim_exec_autocmds("SafeState", {})

    assert.are.equal(0, #floats(), "a peek drawn against a stale screen must fold")
    assert.are.equal(0, #spacer_marks())
    vim.cmd("normal! zE")
  end)

  it("keeps the spacer out of other windows showing the same buffer", function()
    -- The spacer is a buffer extmark, so unscoped it renders in every window on
    -- that buffer -- the split below would get blank rows with no float over
    -- them. Verified visually in a PTY; pinned here through the scoping API.
    vim.cmd("split")
    vim.cmd("wincmd k")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    peek._open()

    assert.are.equal(1, #floats())
    assert.are.equal(1, #spacer_marks(), "the peeking window still gets its spacer")

    local ns = vim.api.nvim_get_namespaces()["long_line_peek"]
    assert.are.same({ win }, vim.api.nvim__ns_get(ns).wins, "spacer must be scoped to one window")
  end)

  it("leaves no window behind when the cursor is too near the bottom to reveal more", function()
    -- The peek is bounded by its own window, not the screen, so the case to hit
    -- is "cursor on this window's last text row" -- there the float caps at
    -- height 1 and shows exactly the screenful the clipped line already showed.
    -- The bail happens after nvim_open_win, so this also pins that the aborted
    -- float is closed rather than leaked.
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(win, 2)
    vim.wo[win].scrolloff = 0
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    -- Put the long line on the window's bottom row.
    vim.fn.winrestview({ topline = 3 - (vim.api.nvim_win_get_height(win) - 1) })
    assert.are.equal(
      vim.api.nvim_win_get_height(win),
      vim.fn.winline(),
      "test setup: cursor must sit on the window's last text row"
    )
    local before = #vim.api.nvim_list_wins()

    peek._open()

    assert.are.equal(0, #floats(), "no peek when it would reveal nothing")
    assert.are.equal(before, #vim.api.nvim_list_wins(), "aborted float leaked a window")
    assert.are.equal(0, #spacer_marks())
  end)
end)
