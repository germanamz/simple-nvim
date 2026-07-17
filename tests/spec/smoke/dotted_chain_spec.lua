-- Drives the REAL mini.ai `o` textobject end-to-end, closing the loop on the
-- pure config.dotted_chain unit spec: it confirms the composed pattern selects
-- what that spec's mini.ai emulation claims, and that the plugin wiring
-- (callable custom_textobject reading vim.bo.filetype) actually resolves.
local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: dotted-chain textobject (mini.ai `o`)", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
    -- Set mini.ai up directly from the real plugin spec's opts rather than
    -- through require("lazy").load: a freshly-cloned plugin makes lazy schedule
    -- an async docs task that misbehaves under plenary's busted runner, and the
    -- lazy-load trigger is not what this spec exercises. Sourcing the plugin +
    -- passing the spec's own opts still drives the real mini.ai with the real
    -- custom_textobjects.o wiring (the callable into config.dotted_chain).
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/mini.ai")
    -- silent=true only for the test run: one case deliberately asserts the
    -- no-textobject path, and mini.ai would otherwise print its "No textobject
    -- found" feedback. The real custom_textobjects.o wiring is untouched.
    require("mini.ai").setup(
      vim.tbl_extend("force", require("plugins.mini-ai").opts, { silent = true })
    )
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  -- Select the `o` textobject (`ai_type` = "a" or "i") with the cursor on the
  -- first byte of `on`, in a scratch buffer of the given filetype. Returns the
  -- selected substring (single line).
  local function select(ai_type, ft, line, on)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.bo[buf].filetype = ft
    vim.api.nvim_set_current_buf(buf)
    local col = assert(line:find(on, 1, true), "substring not in line: " .. on)
    vim.api.nvim_win_set_cursor(0, { 1, col - 1 })

    local region = require("mini.ai").find_textobject(ai_type, "o")
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(region, "no `o` textobject found for: " .. line)
    -- Region cols are 1-based inclusive; single-line here.
    return line:sub(region.from.col, region.to.col)
  end

  it("selects a whole dotted chain from any segment", function()
    local line = 'someFunc("another arg", app.property)'
    assert.are.equal("app.property", select("i", "go", line, "app"))
    assert.are.equal("app.property", select("i", "go", line, "property"))
  end)

  it("returns the same span for `a` and `i`", function()
    local line = "x = app.property"
    assert.are.equal("app.property", select("a", "python", line, "property"))
    assert.are.equal("app.property", select("i", "python", line, "property"))
  end)

  it("keeps `::` and `:` chains together (rust, lua)", function()
    assert.are.equal(
      "std::vec::Vec::new",
      select("i", "rust", "let v = std::vec::Vec::new()", "vec")
    )
    assert.are.equal("obj:method", select("i", "lua", "obj:method(1)", "method"))
  end)

  it("keeps optional chaining `?.` together (ts)", function()
    assert.are.equal(
      "app?.property",
      select("i", "typescript", "const y = app?.property", "property")
    )
  end)

  it("does not swallow subtraction into the chain", function()
    assert.are.equal("i", select("i", "go", "arr[i-1]", "i"))
  end)

  -- These pin behaviour the pure unit spec structurally cannot: mini.ai's
  -- default cover_or_next forward-reach (cursor off any chain), the
  -- leading-separator strip validated against the real extractor, and genuine
  -- multi-line method chains. `at` places the cursor at an explicit (row, 1-based
  -- col) and returns the selected text tagged with its line, or nil.
  describe("cover_or_next / multi-line (real plugin only)", function()
    local function at(ai_type, ft, lines, row, col)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = ft
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      local region = require("mini.ai").find_textobject(ai_type, "o")
      vim.api.nvim_buf_delete(buf, { force = true })
      if not region then
        return nil
      end
      assert.are.equal(region.from.line, region.to.line, "unexpected multi-line region")
      return string.format(
        "L%d:%s",
        region.from.line,
        lines[region.from.line]:sub(region.from.col, region.to.col)
      )
    end

    it("reaches forward to the next chain when the cursor is off every chain", function()
      -- cursor on the space at col 3 in `f(  app.property)`.
      assert.are.equal("L1:app.property", at("i", "javascript", { "f(  app.property)" }, 1, 3))
    end)

    it("strips a leading separator through the real extractor", function()
      assert.are.equal("L1:filter", at("i", "javascript", { "  .filter(Boolean)" }, 1, 5))
      -- Double strip: leading `::` on a lua label.
      assert.are.equal("L1:continue", at("i", "lua", { "::continue::" }, 1, 5))
    end)

    it("selects one segment of a genuine multi-line method chain", function()
      local lines = { "const x = arr", "  .filter(Boolean)", "  .map(f)" }
      assert.are.equal("L2:filter", at("i", "javascript", lines, 2, 5))
    end)

    -- The one sharp edge worth pinning: a cursor ON a chain's TRAILING separator
    -- is not covered by that chain (the outer match ends on a word char), so
    -- cover_or_next reaches to the NEXT chain rather than the one under the
    -- cursor — and is a safe no-op when none follows. See the design doc's
    -- accepted imprecisions.
    it("resolves a trailing-separator cursor to the next chain, or no-op if none", function()
      -- `?` at 1-based col 7 of `app.fn?.()`; no following chain -> no textobject.
      assert.is_nil(at("i", "typescript", { "app.fn?.()" }, 1, 7))
      -- With a following chain, it reaches forward to it.
      assert.are.equal(
        "L2:other.thing",
        at("i", "typescript", { "app.fn?.()", "other.thing" }, 1, 7)
      )
    end)
  end)
end)
