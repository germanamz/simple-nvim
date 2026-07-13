local pl = require("util.picker_legend")

describe("util.picker_legend", function()
  describe("fit_line", function()
    it("centers narrower text and pads it to the full width", function()
      local text, ranges = pl.fit_line("abcd", { { "Hl", 0, 4 } }, 10)
      -- floor((10-4)/2) = 3 left pad, then right-filled to width 10.
      assert.are.equal("   abcd   ", text)
      assert.are.equal(10, vim.api.nvim_strwidth(text))
      assert.are.same({ { "Hl", 3, 7 } }, ranges)
    end)

    it("leaves text at or above the width unchanged", function()
      local text, ranges = pl.fit_line("abcdefghij", { { "Hl", 0, 4 } }, 10)
      assert.are.equal("abcdefghij", text)
      assert.are.same({ { "Hl", 0, 4 } }, ranges)
    end)

    it("centers by display width while shifting byte ranges (multibyte glyphs)", function()
      -- "全" is 3 bytes but 2 display cells: the pad math must use strwidth,
      -- the range shift byte offsets.
      local text, ranges = pl.fit_line("全b", { { "Hl", 0, 4 } }, 8)
      assert.are.equal("  全b   ", text)
      assert.are.equal(8, vim.api.nvim_strwidth(text))
      assert.are.same({ { "Hl", 2, 6 } }, ranges)
    end)

    it("gives the odd leftover cell to the right side", function()
      local text = pl.fit_line("abc", {}, 10)
      assert.are.equal("   abc    ", text)
    end)
  end)

  describe("render_segments", function()
    it("joins icon+label segments with the separator and default label hl", function()
      local text, ranges = pl.render_segments({
        { icon = "+", icon_hl = "Flag", label = "modified" },
        { icon = "%", icon_hl = "Flag", label = "current win" },
      }, { separator = "   ", default_hl = "Muted" })
      assert.are.equal("+ modified   % current win", text)
      -- icon ranges carry their icon_hl, labels the default.
      assert.are.same({ "Flag", 0, 1 }, ranges[1])
      assert.are.same({ "Muted", 2, 10 }, ranges[2])
      assert.are.same({ "Flag", 13, 14 }, ranges[3])
      assert.are.same({ "Muted", 15, 26 }, ranges[4])
    end)

    it("renders counts after the icon using count_hl", function()
      local text, ranges = pl.render_segments({
        { icon = "A", icon_hl = "Add", count = 2, label = "added" },
      }, { separator = "   ", default_hl = "Muted", count_hl = "Count" })
      assert.are.equal("A 2 added", text)
      assert.are.same({ "Add", 0, 1 }, ranges[1])
      assert.are.same({ "Count", 2, 3 }, ranges[2])
      assert.are.same({ "Muted", 4, 9 }, ranges[3])
    end)

    it("honors per-icon multi-range highlights (icon_hls)", function()
      local text, ranges = pl.render_segments({
        { icon = "bA", icon_hls = { { 0, 1, "Base" }, { 1, 2, "Add" } }, label = "added" },
      }, { separator = "   ", default_hl = "Muted" })
      assert.are.equal("bA added", text)
      assert.are.same({ "Base", 0, 1 }, ranges[1])
      assert.are.same({ "Add", 1, 2 }, ranges[2])
    end)

    it("falls back to default_hl for icons and counts without explicit groups", function()
      local text, ranges = pl.render_segments({
        { icon = "x", count = 2, label = "y" },
      }, { separator = "   ", default_hl = "Muted" })
      assert.are.equal("x 2 y", text)
      assert.are.same({ "Muted", 0, 1 }, ranges[1])
      assert.are.same({ "Muted", 2, 3 }, ranges[2])
      assert.are.same({ "Muted", 4, 5 }, ranges[3])
    end)

    it("renders a count-only segment without a leading space", function()
      local text, ranges = pl.render_segments({
        { count = 3, label = "z" },
      }, { separator = "   ", default_hl = "Muted" })
      assert.are.equal("3 z", text)
      assert.are.same({ "Muted", 0, 1 }, ranges[1])
    end)
  end)

  describe("mount", function()
    it("mounts a non-focusable, nowrap float", function()
      local Overlay = require("util.overlay")
      local overlay = Overlay.new()
      -- A float inherits the global 'wrap'; force the bad case so the test
      -- pins that mount() clips overlong rows instead of wrapping them (a
      -- wrapped row would consume the float's other row).
      local prev_wrap = vim.o.wrap
      vim.o.wrap = true
      local win = pl.mount(overlay, vim.api.nvim_get_current_win(), "test_legend", { "x" }, { {} })
      vim.o.wrap = prev_wrap

      assert.is_not_nil(win)
      assert.is_false(vim.api.nvim_win_get_config(win).focusable)
      assert.is_false(vim.wo[win].wrap)
      overlay:close()
    end)
  end)

  describe("attach", function()
    local bufs

    local function scratch()
      local buf = vim.api.nvim_create_buf(false, true)
      table.insert(bufs, buf)
      return buf
    end

    before_each(function()
      bufs = {}
    end)

    after_each(function()
      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end)

    it("runs the scheduled open, then closes exactly once on BufLeave", function()
      local buf, other = scratch(), scratch()
      vim.api.nvim_set_current_buf(buf)

      local c = { open = 0, close = 0 }
      pl.attach(buf, function()
        c.open = c.open + 1
      end, function()
        c.close = c.close + 1
      end)
      vim.wait(200, function()
        return c.open == 1
      end)
      assert.are.equal(1, c.open)
      assert.are.equal(0, c.close)

      vim.api.nvim_set_current_buf(other)
      assert.are.equal(1, c.close)

      -- once=true is consumed by the first BufLeave: a later leave must not
      -- re-close (the legend belongs to whatever re-opened it since).
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_set_current_buf(other)
      assert.are.equal(1, c.close)
    end)

    it("re-opens on VimResized only while the attached buffer is current", function()
      local buf, other = scratch(), scratch()
      vim.api.nvim_set_current_buf(buf)

      local c = { open = 0 }
      pl.attach(buf, function()
        c.open = c.open + 1
      end, function() end)
      vim.wait(200, function()
        return c.open == 1
      end)
      assert.are.equal(1, c.open)

      vim.cmd("doautocmd VimResized")
      vim.wait(200, function()
        return c.open == 2
      end)
      assert.are.equal(2, c.open)

      -- Buffer-local autocmds only fire while their buffer is current, which
      -- is what keeps a backgrounded prompt from re-mounting its legend.
      vim.api.nvim_set_current_buf(other)
      vim.cmd("doautocmd VimResized")
      vim.wait(100)
      assert.are.equal(2, c.open)
    end)
  end)
end)
