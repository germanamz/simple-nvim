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

  describe("JS/TS entries", function()
    local toolchain = require("config.js_toolchain")
    local root

    before_each(function()
      toolchain._clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/src", "p")
      -- Seals the detection walk at `root` (a .git directory is an
      -- unconditional boundary, checked after markers). Without it the
      -- "nothing is configured" case climbs past the fixture into the real
      -- filesystem, where a stray ancestor .prettierrc flips the result and
      -- the assertion becomes host-dependent.
      vim.fn.mkdir(root .. "/.git", "p")
    end)

    after_each(function()
      vim.fn.delete(root, "rf")
      toolchain._clear()
    end)

    local function write(relpath, contents)
      local path = root .. "/" .. relpath
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local f = assert(io.open(path, "w"))
      f:write(contents)
      f:close()
    end

    local function chain_for(ft)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
      local chain = M.by_ft[ft](bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      return chain
    end

    it("exposes the four JS/TS filetypes as functions", function()
      for _, ft in ipairs({ "javascript", "javascriptreact", "typescript", "typescriptreact" }) do
        assert.is_function(M.by_ft[ft], ft .. " should be slot-driven")
      end
    end)

    it("returns the prettier chain when the project configures prettier", function()
      write(".prettierrc", "{}\n")
      local chain = chain_for("typescript")
      assert.same({ "prettierd", "prettier" }, { chain[1], chain[2] })
    end)

    it("returns eslint_d when the project configures only eslint", function()
      write("eslint.config.mjs", "export default [];\n")
      assert.same({ "eslint_d" }, { chain_for("typescript")[1] })
    end)

    it("returns biome when the project configures biome", function()
      write("biome.json", "{}\n")
      assert.same({ "biome" }, { chain_for("typescriptreact")[1] })
    end)

    it("returns an empty chain when nothing is configured", function()
      assert.are.equal(0, #chain_for("typescript"))
    end)

    -- An empty chain must not fall through to ts_ls, which would reformat with
    -- tsserver's own defaults — a style nobody in the project chose.
    it("never lets the LSP format a JS/TS buffer", function()
      assert.are.equal("never", chain_for("typescript").lsp_format)
    end)

    -- Same guarantee on the non-empty path: if the resolved formatter turns
    -- out to be unavailable, conform filters it out of the chain, and without
    -- lsp_format = "never" here too the LSP fallback would still reach ts_ls.
    it("never lets the LSP format even when a formatter resolves", function()
      write(".prettierrc", "{}\n")
      assert.are.equal("never", chain_for("typescript").lsp_format)
    end)

    it("stops after the first available formatter", function()
      write(".prettierrc", "{}\n")
      assert.is_true(chain_for("typescript").stop_after_first)
    end)

    it("does not mutate the shared chain literal between calls", function()
      write("biome.json", "{}\n")
      local first = chain_for("typescript")
      first[#first + 1] = "sentinel"
      toolchain._clear()
      assert.are.equal(1, #chain_for("typescript"))
    end)

    -- slot_to_conform.prettier aliases the SAME table object as the shared
    -- `prettier` local that markdown/json/css/etc. use below — js_formatters'
    -- vim.deepcopy is what keeps mutating the returned chain from mutating that
    -- shared table too. The trigger (resolving the prettier slot) and the
    -- assertion (inspecting the shared table) must live in ONE test: the outer
    -- before_each reloads config.formatters fresh before every `it()`, so a
    -- poisoned literal from one test is invisible to any other — do not split
    -- this back into two tests.
    it("never poisons the shared prettier literal that markdown etc. share", function()
      write(".prettierrc", "{}\n")
      chain_for("typescript") -- resolves the prettier slot; would mutate
      -- slot_to_conform.prettier (== the shared `prettier` local) in place if
      -- js_formatters' deepcopy were ever dropped
      assert.is_nil(M.by_ft.markdown.lsp_format)
      assert.are.equal(2, #M.by_ft.markdown)
    end)
  end)

  describe("non-JS web entries", function()
    it("keeps prettier unconditional for markdown and json", function()
      for _, ft in ipairs({ "markdown", "json", "yaml", "css" }) do
        assert.same({ "prettierd", "prettier" }, { M.by_ft[ft][1], M.by_ft[ft][2] })
      end
    end)

    it("stops after the first available formatter", function()
      assert.is_true(M.by_ft.markdown.stop_after_first)
    end)
  end)
end)
