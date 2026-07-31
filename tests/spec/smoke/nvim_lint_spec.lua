-- Pins the nvim-lint wiring: eslint_d must run on save ONLY where
-- config.js_toolchain resolves the linter slot to eslint, so a biome or oxlint
-- repo never spawns an ESLint pass.
describe("nvim-lint wiring", function()
  it("loads the plugin", function()
    assert.is_true(pcall(require, "lint"))
  end)

  it("registers eslint_d with a local-first command", function()
    local lint = require("lint")
    assert.is_table(lint.linters.eslint_d)
    assert.is_function(lint.linters.eslint_d.cmd)
  end)

  it("creates the BufWritePost autocmd", function()
    local autocmds = vim.api.nvim_get_autocmds({
      group = "nvim_lint_js",
      event = "BufWritePost",
    })
    assert.is_true(#autocmds > 0, "expected a BufWritePost autocmd in nvim_lint_js")
  end)

  -- The three tests above never run the autocmd's callback, so they cannot
  -- catch the one thing this task exists to enforce: eslint_d must NOT fire
  -- outside an eslint-linted project. Fire the real callback with
  -- config.js_toolchain.resolve and lint.try_lint stubbed (same
  -- swap-and-restore shape as lsp_fs_sync_spec's vim.lsp.get_clients stub) so
  -- neither a real project fixture nor a real eslint_d process is needed.
  describe("gate: eslint_d runs only when js_toolchain resolves the eslint linter", function()
    local buf
    local orig_resolve
    local orig_try_lint
    local try_lint_calls

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "-nvim-lint-gate.ts")
      orig_resolve = require("config.js_toolchain").resolve
      orig_try_lint = require("lint").try_lint
      try_lint_calls = {}
      require("lint").try_lint = function(...)
        table.insert(try_lint_calls, { ... })
      end
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      require("config.js_toolchain").resolve = orig_resolve
      require("lint").try_lint = orig_try_lint
    end)

    it("does not lint when the resolved linter is not eslint", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "biome" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(0, #try_lint_calls)
    end)

    it("lints with eslint_d when the resolved linter is eslint", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal("eslint_d", try_lint_calls[1][1])
    end)
  end)
end)
