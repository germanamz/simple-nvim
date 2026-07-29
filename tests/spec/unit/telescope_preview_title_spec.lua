-- Pins the preview-title trimming grammar: an over-long path loses LEADING
-- directories (`…/billing/handlers/name.ts`), never its tail, so the file name
-- you navigate by always survives. plenary's border truncates from the right,
-- which is exactly the behaviour this module exists to pre-empt.
local preview_title = require("config.telescope_preview_title")

local DEEP = "packages/some-service/src/modules/billing/handlers/create-invoice-handler.ts"

describe("config.telescope_preview_title", function()
  describe("trim", function()
    it("leaves a path that already fits untouched", function()
      assert.are.equal(DEEP, preview_title.trim(DEEP, 200))
      assert.are.equal("README.md", preview_title.trim("README.md", 9))
    end)

    it("drops whole leading directories until the path fits", function()
      -- "…/src/modules/billing/handlers/create-invoice-handler.ts" is 56 cells;
      -- keeping one more parent ("some-service/") would be 69 and overflow 60.
      assert.are.equal(
        "…/src/modules/billing/handlers/create-invoice-handler.ts",
        preview_title.trim(DEEP, 60)
      )
    end)

    it("keeps the file name whole even when only it fits", function()
      local out = preview_title.trim(DEEP, 30)
      assert.are.equal("…/create-invoice-handler.ts", out)
      assert.is_truthy(vim.api.nvim_strwidth(out) <= 30)
    end)

    it("keeps the tail when even the bare file name overflows", function()
      local out = preview_title.trim("a/very-long-file-name-that-does-not-fit.ts", 12)
      assert.is_truthy(vim.api.nvim_strwidth(out) <= 12, "over-wide result: " .. out)
      assert.are.equal("…", out:sub(1, #"…"))
      assert.is_truthy(out:find("fit.ts", 1, true), "lost the extension: " .. out)
    end)

    it("trims an absolute path without eating the leading slash mid-segment", function()
      local out = preview_title.trim("/Users/dev/work/repo/lua/config/options.lua", 24)
      assert.are.equal("…/lua/config/options.lua", out)
    end)

    it("passes through when there is no usable width", function()
      assert.are.equal(DEEP, preview_title.trim(DEEP, nil))
      assert.are.equal(DEEP, preview_title.trim(DEEP, 0))
      assert.are.equal(DEEP, preview_title.trim(DEEP, -5))
    end)

    it("passes through non-strings", function()
      assert.is_nil(preview_title.trim(nil, 10))
      assert.are.equal("", preview_title.trim("", 10))
    end)
  end)

  describe("wrap", function()
    -- _width needs a live preview window, so stub the seam and drive the
    -- wrapper the way telescope does: `previewer:_dyn_title_fn(entry)`.
    local real_width

    before_each(function()
      real_width = preview_title._width
    end)

    after_each(function()
      preview_title._width = real_width
    end)

    it("trims what the wrapped dynamic title returns", function()
      preview_title._width = function()
        return 60
      end
      local p = {
        _dyn_title_fn = function()
          return DEEP
        end,
      }
      assert.are.equal(p, preview_title.wrap(p), "wrap should patch in place")
      assert.are.equal(
        "…/src/modules/billing/handlers/create-invoice-handler.ts",
        p:_dyn_title_fn({})
      )
    end)

    it("forwards self and entry to the original title function", function()
      preview_title._width = function()
        return nil -- no preview window: leave the title alone
      end
      local seen
      local p = {
        _dyn_title_fn = function(self, entry)
          seen = { self = self, entry = entry }
          return DEEP
        end,
      }
      preview_title.wrap(p)
      local entry = { value = "x" }
      assert.are.equal(DEEP, p:_dyn_title_fn(entry))
      assert.are.equal(p, seen.self)
      assert.are.equal(entry, seen.entry)
    end)

    it("leaves a previewer without a dynamic title untouched", function()
      local p = {
        _title_fn = function()
          return "File Preview"
        end,
      }
      assert.are.equal(p, preview_title.wrap(p))
      assert.is_nil(p._dyn_title_fn)
      assert.are.equal("plain", preview_title.wrap("plain"))
    end)
  end)
end)
