describe("config.formatters", function()
  local M

  before_each(function()
    package.loaded["config.formatters"] = nil
    M = require("config.formatters")
  end)

  describe("by_ft", function()
    it("maps every filetype to a non-empty list of formatter names", function()
      for ft, list in pairs(M.by_ft) do
        assert.is_true(#list >= 1, "empty formatter list for " .. ft)
        for _, name in ipairs(list) do
          assert.is_string(name)
        end
      end
    end)
  end)
end)
