local peek = require("config.long_line_peek")

describe("config.long_line_peek", function()
  describe("text_width", function()
    it("subtracts the gutter from the window width", function()
      -- numberwidth 4 + signcolumn 2 = textoff 6, the measured value for this
      -- config in an 80-column window.
      assert.are.equal(74, peek.text_width({ width = 80, textoff = 6 }))
    end)

    it("is the full width when there is no gutter", function()
      assert.are.equal(80, peek.text_width({ width = 80, textoff = 0 }))
    end)

    it("never goes negative on a window narrower than its own gutter", function()
      assert.are.equal(0, peek.text_width({ width = 4, textoff = 6 }))
    end)
  end)

  describe("is_clipped", function()
    it("is false when the line fits the viewport exactly", function()
      assert.is_false(peek.is_clipped(74, 74))
    end)

    it("is true when the line is one cell too wide", function()
      assert.is_true(peek.is_clipped(75, 74))
    end)

    it("is false for a short line", function()
      assert.is_false(peek.is_clipped(10, 74))
    end)

    -- The trigger asks "can this line ever be fully visible", not "is some of
    -- it off-screen right now" -- so it does not depend on leftcol. A line
    -- wider than the viewport is clipped at every horizontal scroll position.
    it("is false for a zero-width viewport rather than firing constantly", function()
      assert.is_false(peek.is_clipped(75, 0))
    end)
  end)

  describe("geometry", function()
    it("gives the float the line's full wrapped height when there is room", function()
      local g = peek.geometry({ wrapped_height = 7, rows_available = 20 })
      assert.are.same({ height = 7, spacer = 6, truncated = false }, g)
    end)

    -- The spacer is one row shorter than the float: the float's first row sits
    -- on the cursor line's own screen row, which is a real buffer row and needs
    -- no filler. Getting this off by one makes the code below the line jump.
    it("uses one fewer spacer row than the float's height", function()
      local g = peek.geometry({ wrapped_height = 3, rows_available = 20 })
      assert.are.equal(2, g.spacer)
    end)

    it("needs no spacer for a line that wraps to a single row", function()
      local g = peek.geometry({ wrapped_height = 1, rows_available = 20 })
      assert.are.same({ height = 1, spacer = 0, truncated = false }, g)
    end)

    it("caps the float at the rows left below the cursor and says so", function()
      local g = peek.geometry({ wrapped_height = 9, rows_available = 4 })
      assert.are.same({ height = 4, spacer = 3, truncated = true }, g)
    end)

    it("fits exactly into the available rows without reporting truncation", function()
      local g = peek.geometry({ wrapped_height = 4, rows_available = 4 })
      assert.are.same({ height = 4, spacer = 3, truncated = false }, g)
    end)

    -- nvim_win_set_config rejects height 0 with "expected positive Integer",
    -- which would surface as an E5108 on an ordinary keypress. The cursor on
    -- the last usable screen row leaves exactly one row.
    it("never returns a height below one", function()
      local g = peek.geometry({ wrapped_height = 7, rows_available = 0 })
      assert.are.equal(1, g.height)
      assert.are.equal(0, g.spacer)
      assert.is_true(g.truncated)
    end)
  end)

  describe("reveals_more", function()
    it("accepts a peek that adds rows", function()
      assert.is_true(peek.reveals_more({ height = 2 }))
      assert.is_true(peek.reveals_more({ height = 9 }))
    end)

    -- A one-row float renders exactly the screenful the clipped line already
    -- rendered: a flicker with no payload.
    it("rejects a peek squeezed down to a single row", function()
      assert.is_false(peek.reveals_more({ height = 1 }))
    end)

    it("rejects the geometry produced with no rows left below the cursor", function()
      assert.is_false(peek.reveals_more(peek.geometry({ wrapped_height = 8, rows_available = 0 })))
    end)
  end)

  describe("eligible", function()
    local function ctx(over)
      local base = {
        mode = "n",
        state = "",
        pumvisible = false,
        buftype = "",
        relative = "",
        large = false,
      }
      return vim.tbl_extend("force", base, over or {})
    end

    it("accepts an idle normal-mode file buffer", function()
      assert.is_true(peek.eligible(ctx()))
    end)

    it("refuses insert mode", function()
      assert.is_false(peek.eligible(ctx({ mode = "i" })))
    end)

    it("refuses visual mode", function()
      assert.is_false(peek.eligible(ctx({ mode = "v" })))
    end)

    -- mode(1) returns the full mode string, so operator-pending is "no" and
    -- must not pass a plain prefix test.
    it("refuses operator-pending mode", function()
      assert.is_false(peek.eligible(ctx({ mode = "no" })))
    end)

    -- "no keybinding started": state("mo") reports a half-typed mapping or a
    -- pending operator. Popping a float mid-sequence would be startling.
    it("refuses while a mapping is half-typed", function()
      assert.is_false(peek.eligible(ctx({ state = "m" })))
    end)

    it("refuses while an operator is pending", function()
      assert.is_false(peek.eligible(ctx({ state = "o" })))
    end)

    it("refuses while the completion menu is open", function()
      assert.is_false(peek.eligible(ctx({ pumvisible = true })))
    end)

    -- buftype alone excludes the tree (nofile), telescope (prompt), help,
    -- quickfix and terminals, so no filetype denylist is needed.
    it("refuses a non-file buffer", function()
      assert.is_false(peek.eligible(ctx({ buftype = "nofile" })))
      assert.is_false(peek.eligible(ctx({ buftype = "prompt" })))
      assert.is_false(peek.eligible(ctx({ buftype = "help" })))
    end)

    it("refuses inside a floating window", function()
      assert.is_false(peek.eligible(ctx({ relative = "win" })))
    end)

    it("refuses a buffer over the shared large-file bound", function()
      assert.is_false(peek.eligible(ctx({ large = true })))
    end)
  end)

  describe("spacer_lines", function()
    it("builds one empty virtual row per spacer row", function()
      local lines = peek.spacer_lines(3)
      assert.are.equal(3, #lines)
      for _, row in ipairs(lines) do
        assert.are.same({ { "", "NonText" } }, row)
      end
    end)

    it("returns nothing for a line that needs no spacer", function()
      assert.are.same({}, peek.spacer_lines(0))
    end)
  end)
end)
