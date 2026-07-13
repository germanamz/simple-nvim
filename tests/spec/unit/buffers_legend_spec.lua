local legend = require("config.buffers_legend")

describe("config.buffers_legend", function()
  describe("_build_lines", function()
    local WIDTH = 90

    it("renders the two flag rows", function()
      local lines = legend._build_lines(WIDTH)
      assert.are.equal(2, #lines)
      local joined = table.concat(lines, "\n")
      for _, pair in ipairs({
        "+ modified",
        "% current",
        "# alternate",
        "a active",
        "h hidden",
        "= read-only",
      }) do
        assert.is_truthy(
          joined:find(pair, 1, true),
          "expected legend to contain '" .. pair .. "', got:\n" .. joined
        )
      end
    end)

    it("centers each row to the requested width", function()
      local lines = legend._build_lines(WIDTH)
      for _, line in ipairs(lines) do
        assert.are.equal(WIDTH, vim.api.nvim_strwidth(line))
      end
    end)

    it("keeps every highlight range within its line", function()
      local lines, ranges_by_line = legend._build_lines(WIDTH)
      assert.are.equal(#lines, #ranges_by_line)
      for lnum, ranges in ipairs(ranges_by_line) do
        assert.is_truthy(#ranges > 0, "line " .. lnum .. " has no highlights")
        for _, r in ipairs(ranges) do
          assert.are.equal("string", type(r[1]))
          assert.is_truthy(r[2] >= 0 and r[3] <= #lines[lnum] and r[2] < r[3])
        end
      end
    end)

    it("highlights all 6 flag characters with the flag group", function()
      local _, ranges_by_line = legend._build_lines(WIDTH)
      local flags = 0
      for _, ranges in ipairs(ranges_by_line) do
        for _, r in ipairs(ranges) do
          if r[1] == "BuffersLegendFlag" then
            flags = flags + 1
          end
        end
      end
      assert.are.equal(6, flags)
    end)

    -- The narrowest layout the legend must survive intact: telescope's
    -- horizontal layout at 120 columns (preview still visible) leaves the
    -- results window ~43 cells wide. Overlong rows are clipped, not wrapped
    -- (see the mount() nowrap test), but the content should simply fit.
    it("fits both rows in a 43-cell results window", function()
      local lines = legend._build_lines(43)
      for _, line in ipairs(lines) do
        assert.is_truthy(
          vim.api.nvim_strwidth(line) <= 43,
          "row wider than 43 cells: " .. vim.inspect(line)
        )
      end
    end)
  end)
end)
