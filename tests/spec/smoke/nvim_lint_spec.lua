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
end)
