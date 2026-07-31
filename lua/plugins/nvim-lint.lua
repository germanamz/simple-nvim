-- ESLint diagnostics, on save.
--
-- Why not a language server: vscode-eslint is Node and starts one process per
-- project root. In a superproject with hundreds of submodules, touching files
-- across them accumulates a process per repo — the cost profile
-- docs/lsp-typescript-version.md and lua/config/lsp_reap.lua already exist to
-- fight. eslint_d is a single shared daemon that caches an ESLint instance per
-- project internally, so the whole workspace costs one process. The trade is that
-- diagnostics land on save rather than as you type, and ESLint's "fix all" code
-- action is unavailable — <leader>F does the equivalent, because eslint_d is also
-- the formatter for eslint-only projects (lua/config/formatters.lua).
--
-- biome and oxlint are NOT here: both are Rust language servers registered in
-- lua/plugins/lsp.lua, where they cost almost nothing per root.
return {
  "mfussenegger/nvim-lint",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    local lint = require("lint")

    -- nvim-lint's builtin resolves eslint_d from PATH only, which in this setup is
    -- always mason's global copy. conform's builtins prefer the project's own
    -- node_modules/.bin (conform.util.from_node_modules), and the linter must
    -- agree with the formatter about which ESLint is authoritative.
    lint.linters.eslint_d.cmd = function()
      local found = vim.fs.find("node_modules/.bin/eslint_d", {
        upward = true,
        path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
      })[1]
      if found and vim.fn.executable(found) == 1 then
        return found
      end
      return "eslint_d"
    end

    -- No linters_by_ft: which linter applies is a property of the PROJECT, not the
    -- filetype, so the decision is made per buffer at save time from
    -- config.js_toolchain. A biome repo never reaches try_lint at all.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("nvim_lint_js", { clear = true }),
      pattern = { "*.js", "*.jsx", "*.mjs", "*.cjs", "*.ts", "*.tsx", "*.mts", "*.cts" },
      callback = function(args)
        -- Same guard conform's format-on-save uses: a multi-MB generated bundle
        -- would stall the daemon and paint thousands of diagnostics.
        if require("util.largefile").is_large(args.buf) then
          return
        end
        if require("config.js_toolchain").resolve(args.buf).linter ~= "eslint" then
          return
        end
        require("lint").try_lint("eslint_d")
      end,
    })
  end,
}
