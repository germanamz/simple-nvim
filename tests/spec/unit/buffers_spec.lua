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

  describe("delete_all_saved", function()
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

    -- Deleted-as-in-closed: bdelete unlists, nvim_buf_delete wipes; accept both.
    local function closed(buf)
      return not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].buflisted
    end

    after_each(function()
      for _, buf in ipairs(made) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      made = {}
    end)

    -- Every test keeps a modified "keeper" buffer alive so the no-reals-left
    -- nvim-tree fallback (unavailable in this minimal harness) never triggers.

    it("closes every listed saved buffer", function()
      local saved1 = make(true, vim.fn.tempname() .. ".md", false)
      local saved2 = make(true, vim.fn.tempname() .. ".md", false)
      local keeper = make(true, vim.fn.tempname() .. ".md", true)

      buffers.delete_all_saved()

      assert.is_true(closed(saved1))
      assert.is_true(closed(saved2))
      assert.is_false(closed(keeper))
    end)

    it("keeps buffers with unsaved changes", function()
      local keeper_named = make(true, vim.fn.tempname() .. ".md", true)
      local keeper_unnamed = make(true, nil, true)

      buffers.delete_all_saved()

      assert.is_false(closed(keeper_named))
      assert.is_true(vim.bo[keeper_named].modified)
      assert.is_false(closed(keeper_unnamed))
      assert.is_true(vim.bo[keeper_unnamed].modified)
    end)

    it("does not touch unlisted buffers", function()
      local unlisted = make(false, vim.fn.tempname() .. ".md", false)
      make(true, vim.fn.tempname() .. ".md", true) -- keeper

      buffers.delete_all_saved()

      assert.is_true(vim.api.nvim_buf_is_valid(unlisted))
    end)

    it("lands the window on a surviving real buffer", function()
      local saved = make(true, vim.fn.tempname() .. ".md", false)
      local keeper = make(true, vim.fn.tempname() .. ".md", true)
      vim.api.nvim_set_current_buf(saved)

      buffers.delete_all_saved()

      assert.are.equal(keeper, vim.api.nvim_get_current_buf())
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
