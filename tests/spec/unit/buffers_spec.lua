local buffers = require("config.buffers")

describe("config.buffers", function()
  describe("_is_real", function()
    local made = {}

    local function make(listed, name, modified)
      local buf = vim.api.nvim_create_buf(listed, false)
      if name then
        vim.api.nvim_buf_set_name(buf, name)
      end
      if modified then
        vim.bo[buf].modified = true
      end
      made[#made + 1] = buf
      return buf
    end

    after_each(function()
      for _, buf in ipairs(made) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      made = {}
    end)

    it("treats a listed, named buffer as real", function()
      assert.is_true(buffers._is_real(make(true, vim.fn.tempname() .. ".md", false)))
    end)

    it("treats a listed, unnamed, unmodified [No Name] buffer as not real", function()
      assert.is_false(buffers._is_real(make(true, nil, false)))
    end)

    it("treats an unlisted buffer as not real even when named", function()
      assert.is_false(buffers._is_real(make(false, vim.fn.tempname() .. ".md", false)))
    end)

    it("treats an unnamed but modified buffer as real (unsaved work)", function()
      assert.is_true(buffers._is_real(make(true, nil, true)))
    end)
  end)

  describe("_pick_target", function()
    it("prefers the alternate buffer when it is among the reals", function()
      assert.are.equal(7, buffers._pick_target({ 3, 7, 9 }, 7))
    end)

    it("falls back to the last real when there is no alternate (-1)", function()
      assert.are.equal(9, buffers._pick_target({ 3, 7, 9 }, -1))
    end)

    it("falls back to the last real when the alternate is not one of them", function()
      assert.are.equal(9, buffers._pick_target({ 3, 7, 9 }, 42))
    end)
  end)
end)
