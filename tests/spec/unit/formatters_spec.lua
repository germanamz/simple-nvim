describe("config.formatters", function()
  local M

  before_each(function()
    package.loaded["config.formatters"] = nil
    M = require("config.formatters")
  end)

  describe("by_ft", function()
    it("maps every filetype to a non-empty formatter list or a function", function()
      for ft, entry in pairs(M.by_ft) do
        if type(entry) == "function" then
          assert.is_true(true)
        else
          assert.is_true(#entry >= 1, "empty formatter list for " .. ft)
          for _, name in ipairs(entry) do
            assert.is_string(name)
          end
        end
      end
    end)
  end)

  describe("python entry", function()
    local function buf_in(dir)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, dir .. "/module.py")
      return bufnr
    end

    local function with_project(pyproject_contents, fn)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      if pyproject_contents then
        local f = assert(io.open(dir .. "/pyproject.toml", "w"))
        f:write(pyproject_contents)
        f:close()
      end
      local bufnr = buf_in(dir)
      local ok, err = pcall(fn, bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.fn.delete(dir, "rf")
      assert(ok, err)
    end

    it("is a function", function()
      assert.is_function(M.by_ft.python)
    end)

    it("returns black when pyproject.toml has [tool.black]", function()
      with_project("[tool.black]\nline-length = 110\n", function(bufnr)
        assert.same({ "black" }, M.by_ft.python(bufnr))
      end)
    end)

    it("returns ruff_format when pyproject.toml has no [tool.black]", function()
      with_project("[tool.ruff]\nline-length = 100\n", function(bufnr)
        assert.same({ "ruff_format" }, M.by_ft.python(bufnr))
      end)
    end)

    it("returns ruff_format when there is no pyproject.toml", function()
      with_project(nil, function(bufnr)
        assert.same({ "ruff_format" }, M.by_ft.python(bufnr))
      end)
    end)
  end)
end)
